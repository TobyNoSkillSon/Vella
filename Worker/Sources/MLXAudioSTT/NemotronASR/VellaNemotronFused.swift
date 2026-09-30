import Foundation
import MLX
import MLXNN

/// Fused conformer layer for the cache-aware streaming chunk (M ≈ 4 frames).
/// The chunk encoder is launch-bound (~50 small kernels per layer); this runs the
/// same maths in ~16 dispatches per layer:
///   residual add + LayerNorm in one kernel (the next sublayer's norm, or normOut and
///   the next layer's first norm), Q/K/V as one projection, the relative-position
///   attention over [K/V cache ++ chunk] with the cache update in one kernel, and
///   GLU + causal depthwise conv + LayerNorm + SiLU + conv-cache update in one kernel;
///   the 1×1 convs run as matmuls.
/// Not bit-identical to stock (summation order), so it is gated by the self-test
/// tolerance and the quick-set WER gate. Weights stay kernel inputs, never constants.
final class VellaNemotronFusedEncoder {
    private struct Projection {
        let weight: MLXArray
        let scales: MLXArray?
        let biases: MLXArray?
        let groupSize: Int
        let bits: Int
        let mode: QuantizationMode

        init?(_ layers: [Linear], denseBF16: Bool = false) {
            guard layers.allSatisfy({ $0.bias == nil }) else { return nil }
            let quantized = layers.compactMap { $0 as? QuantizedLinear }
            if quantized.count == layers.count {
                let q0 = quantized[0]
                guard quantized.allSatisfy({ $0.groupSize == q0.groupSize && $0.bits == q0.bits && $0.mode == q0.mode && ($0.biases == nil) == (q0.biases == nil) }) else { return nil }
                weight = MLX.concatenated(quantized.map(\.weight), axis: 0)
                scales = MLX.concatenated(quantized.map(\.scales), axis: 0)
                biases = q0.biases == nil ? nil : MLX.concatenated(quantized.compactMap(\.biases), axis: 0)
                groupSize = q0.groupSize; bits = q0.bits; mode = q0.mode
                var fused = ["weight": weight, "scales": scales!]
                if let biases { fused["biases"] = biases }
                Self.share(layers, fused)
            } else if quantized.isEmpty, layers.allSatisfy({ $0.weight.dtype == layers[0].weight.dtype }) {
                let dense = MLX.concatenated(layers.map(\.weight), axis: 0)
                // Lever b: the BF16 checkpoint's Float32 copy back in BF16 (lossless only); MLX promotes it per call.
                weight = denseBF16 ? (VellaNemotronFusedEncoder.losslessBF16(dense) ?? dense) : dense
                scales = nil; biases = nil; groupSize = 0; bits = 0; mode = .affine
                Self.share(layers, ["weight": weight])
            } else {
                return nil
            }
        }

        /// Point the stock layers at row slices of the fused copy (views, same values), so the
        /// fused Q/K/V does not keep a second copy of those weights.
        private static func share(_ layers: [Linear], _ fused: [String: MLXArray]) {
            var row = 0
            for layer in layers {
                let rows = layer.weight.shape[0]
                let slices = fused.mapValues { $0[row ..< row + rows] }
                MLX.eval(Array(slices.values))
                _ = layer.update(parameters: ModuleParameters.unflattened(slices))
                row += rows
            }
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            if let scales {
                return MLX.quantizedMM(x, weight, scales: scales, biases: biases, groupSize: groupSize, bits: bits, mode: mode)
            }
            return MLX.matmul(x, weight.T)
        }
    }

    /// A bias-free dense BF16 Linear run by the small-M kernel (`VellaNemotronFusedMetal.linear`): M <= 8 rows of
    /// Float32 activations, Float32 accumulation, optional SiLU epilogue, one dispatch. Any other input runs the stock
    /// module (`fallback`), which reads the same BF16 weight (MLX promotes it per call: stock's exact values).
    struct SmallLinear {
        let weight: MLXArray
        let n: Int, k: Int
        let shape: (r: Int, s: Int)
        let fallback: (MLXArray) -> MLXArray

        init?(weight: MLXArray, fallback: @escaping (MLXArray) -> MLXArray) {
            let n = weight.shape[0], k = weight.shape[1]
            let shape = VellaNemotronFusedMetal.linearShape(n: n, k: k)
            guard weight.dtype == .bfloat16, weight.ndim == 2, shape.r >= 1, shape.s >= 1,
                  shape.r * VellaNemotronFusedMetal.maxRows <= shape.s * 32, k % (shape.s * 256) == 0, n % shape.r == 0 else { return nil }
            self.weight = weight; self.n = n; self.k = k; self.shape = shape; self.fallback = fallback
        }

        /// A dense Linear whose Float32 copy is exactly BF16 (the BF16 checkpoint): converted back and shared with the
        /// stock module; nil for quantized or non-BF16 weights.
        init?(_ linear: Linear) {
            guard linear.bias == nil, let w = VellaNemotronFusedEncoder.bf16(linear) else { return nil }
            self.init(weight: w, fallback: { linear($0) })
        }

        func callAsFunction(_ x: MLXArray, silu: Bool = false) -> MLXArray {
            let m = x.shape[1]
            guard x.dtype == .float32, x.ndim == 3, x.shape[0] == 1, m >= 1, m <= VellaNemotronFusedMetal.maxRows, x.shape[2] == k else {
                let y = fallback(x)
                return silu ? MLXNN.silu(y) : y
            }
            let (r, s) = shape
            return VellaNemotronFusedEncoder.linearKernel(
                [x, weight], template: [("N", n), ("KD", k), ("M", m), ("R", r), ("S", s), ("SILU", silu)],
                grid: (n / r * s * 32, 1, 1), threadGroup: (s * 32, 1, 1),
                outputShapes: [[1, m, n]], outputDTypes: [.float32])[0]
        }
    }

    private struct Norm {
        let weight: MLXArray
        let bias: MLXArray
        let eps: Float
        init?(_ norm: LayerNorm) {
            guard let w = norm.weight, let b = norm.bias, norm.eps == 1e-5 else { return nil }
            weight = w; bias = b; eps = norm.eps
        }
    }

    private struct Layer {
        let block: NemotronASRConformerBlock
        let qkv: Projection
        let pw1, pw2: MLXArray  // (out, in) BF16 1×1 conv weights, shared with the stock modules
        /// BF16 small-M kernels for FF1/FF2 (linear1 with the SiLU epilogue), Q/K/V and linear_out (`VELLA_NEMO_BF16LINEAR`).
        let ff1a, ff1b, ff2a, ff2b, qkvLin, outLin: SmallLinear?
        let dw: MLXArray        // (C, K)
        let ff1, att, conv, convLN, ff2, out: Norm
    }

    private let layers: [Layer]
    let dModel: Int
    let heads: Int
    let headDim: Int
    let kernelSize: Int
    private var dims: [Int: MLXArray] = [:]
    private var zeros: [DType: MLXArray] = [:]

    /// `denseBF16`: the dense (BF16 checkpoint) Linears in BF16 (lossless only; the load skips their Float32 copies),
    /// shared with the stock modules and run through `SmallLinear`. Quantized checkpoints keep MLX's quantized matmul.
    init?(_ encoder: NemotronASRConformer, denseBF16: Bool = false) {
        let first = encoder.layers[0]
        let d = first.selfAttn.nFeat, h = first.selfAttn.nHead, hd = first.selfAttn.headDim
        let k = first.conv.depthwiseConv.weight.shape[1]
        guard d % 256 == 0, d <= 1024, hd == 128, h * hd == d, k >= 1, first.conv.padRight == 0, first.conv.padLeft == k - 1 else { return nil }
        var built: [Layer] = []
        for b in encoder.layers {
            let a = b.selfAttn, c = b.conv
            guard a.nHead == h, a.headDim == hd, c.depthwiseConv.bias == nil, c.pointwiseConv1.bias == nil, c.pointwiseConv2.bias == nil,
                  c.depthwiseConv.weight.shape == [d, k, 1], c.pointwiseConv1.weight.shape == [2 * d, 1, d], c.pointwiseConv2.weight.shape == [d, 1, d],
                  let qkv = Projection([a.linearQ, a.linearK, a.linearV], denseBF16: denseBF16),
                  let ff1 = Norm(b.normFeedForward1), let att = Norm(b.normSelfAtt), let conv = Norm(b.normConv),
                  let convLN = Norm(c.batchNorm), let ff2 = Norm(b.normFeedForward2), let out = Norm(b.normOut) else { return nil }
            // The 1×1 convs run from BF16 weights (half the traffic of the Float32 copies); only when that is exact.
            guard let pw1 = Self.bf16(c.pointwiseConv1), let pw2 = Self.bf16(c.pointwiseConv2) else { return nil }
            func small(_ l: Linear) -> SmallLinear? { denseBF16 ? SmallLinear(l) : nil }
            let qkvLin = denseBF16 && qkv.scales == nil ? SmallLinear(weight: qkv.weight, fallback: { qkv($0) }) : nil
            built.append(Layer(block: b, qkv: qkv,
                               pw1: pw1.reshaped([2 * d, d]),
                               pw2: pw2.reshaped([d, d]),
                               ff1a: small(b.feedForward1.linear1), ff1b: small(b.feedForward1.linear2),
                               ff2a: small(b.feedForward2.linear1), ff2b: small(b.feedForward2.linear2),
                               qkvLin: qkvLin, outLin: small(a.linearOut),
                               dw: c.depthwiseConv.weight.reshaped([d, k]),
                               ff1: ff1, att: att, conv: conv, convLN: convLN, ff2: ff2, out: out))
        }
        layers = built
        dModel = d; heads = h; headDim = hd; kernelSize = k
        MLX.eval(layers.flatMap { [$0.qkv.weight, $0.dw] })
    }

    /// The conv's weight as BF16 if that is lossless (checkpoint values are BF16); the stock module then uses it too.
    private static func bf16(_ conv: Conv1d) -> MLXArray? {
        guard let b = losslessBF16(conv.weight) else { return nil }
        if b !== conv.weight { _ = conv.update(parameters: ModuleParameters.unflattened(["weight": b])) }
        return b
    }
    /// Same for a dense Linear (lever b): the stock module then reads BF16 and MLX promotes it per call, which
    /// gives the values of the Float32 copy exactly.
    fileprivate static func bf16(_ linear: Linear) -> MLXArray? {
        guard !(linear is QuantizedLinear), let b = losslessBF16(linear.weight) else { return nil }
        if b !== linear.weight { _ = linear.update(parameters: ModuleParameters.unflattened(["weight": b])) }
        return b
    }
    fileprivate static func losslessBF16(_ w: MLXArray) -> MLXArray? {
        guard w.dtype != .bfloat16 else { return w }
        guard w.dtype == .float32 else { return nil }
        let b = w.asType(.bfloat16)
        guard MLX.all(b.asType(w.dtype) .== w).item(Bool.self) else { return nil }
        eval(b)
        return b
    }
    fileprivate static let linearKernel = MLXFast.metalKernel(
        name: "vella_nemo_linear_bf16", inputNames: ["x", "W"], outputNames: ["y"],
        source: VellaNemotronFusedMetal.linear, header: VellaNemotronFusedMetal.header)

    private func dimsArray(_ m: Int, _ c: Int, _ cn: Int) -> MLXArray {
        let key = m | (c << 16) | (cn << 32)
        if let hit = dims[key] { return hit }
        let a = MLXArray([Int32(m), Int32(c), Int32(cn)])
        dims[key] = a
        return a
    }

    private func zeroRows(_ dtype: DType) -> MLXArray {
        if let hit = zeros[dtype] { return hit }
        let z = MLXArray.zeros([1, kernelSize - 1, dModel], dtype: dtype)
        eval(z)
        zeros[dtype] = z
        return z
    }

    private static let addNormKernel = MLXFast.metalKernel(
        name: "vella_nemo_add_ln", inputNames: ["x", "r", "w1", "b1", "w2", "b2"], outputNames: ["o0", "o1"],
        source: VellaNemotronFusedMetal.addNorm, header: VellaNemotronFusedMetal.header)
    private static let attentionKernel = MLXFast.metalKernel(
        name: "vella_nemo_relpos_attention", inputNames: ["qkv", "kc", "vc", "p", "bu", "bv", "dims"], outputNames: ["out", "kn", "vn"],
        source: VellaNemotronFusedMetal.attention, header: VellaNemotronFusedMetal.header)
    private static let gemvKernel = MLXFast.metalKernel(
        name: "vella_nemo_gemv_bf16", inputNames: ["x", "W"], outputNames: ["y"],
        source: VellaNemotronFusedMetal.gemv, header: VellaNemotronFusedMetal.header)
    private static let convKernel = MLXFast.metalKernel(
        name: "vella_nemo_glu_dwconv_ln_silu", inputNames: ["pw", "cc", "w", "lw", "lb"], outputNames: ["y", "cn"],
        source: VellaNemotronFusedMetal.conv, header: VellaNemotronFusedMetal.header)

    /// `twoNorms` false: (x + a·r, LN1(x + a·r)); true: (LN1(x + a·r), LN2(LN1(x + a·r))).
    private func addNorm(_ x: MLXArray, _ r: MLXArray, half: Bool, _ n1: Norm, _ n2: Norm? = nil) -> (MLXArray, MLXArray) {
        let m = x.shape[1]
        let o = Self.addNormKernel(
            [x, r, n1.weight, n1.bias, (n2 ?? n1).weight, (n2 ?? n1).bias],
            template: [("C", dModel), ("HALF", half), ("TWO", n2 != nil), ("T", x.dtype)],
            grid: (dModel, m, 1), threadGroup: (dModel, 1, 1),
            outputShapes: [x.shape, x.shape], outputDTypes: [x.dtype, x.dtype])
        return (o[0], o[1])
    }

    private static let gemvRows = 2
    private func gemv(_ x: MLXArray, _ w: MLXArray) -> MLXArray {
        let n = w.shape[0], kd = w.shape[1], m = x.shape[1]
        return Self.gemvKernel(
            [x, w], template: [("N", n), ("KD", kd), ("ROWS", Self.gemvRows), ("T", x.dtype)],
            grid: (n / (Self.gemvRows * 8) * 256, 1, 1), threadGroup: (256, 1, 1),
            outputShapes: [[1, m, n]], outputDTypes: [x.dtype])[0]
    }

    /// The stack of conformer layers for one streaming chunk `x` (1, M, d), updating the
    /// per-layer K/V and conv caches in `state`. Returns the last layer's output.
    func callAsFunction(_ x0: MLXArray, model: NemotronASRModel, state: NemotronASRStreamEncoderState, leftCache: Int) -> MLXArray {
        let m = x0.shape[1], dtype = x0.dtype, d = dModel
        var x = x0
        let n0 = layers[0].ff1
        var h = MLXFast.layerNorm(x0, weight: n0.weight, bias: n0.bias, eps: n0.eps)
        for (li, l) in layers.enumerated() {
            let b = l.block, a = b.selfAttn
            // FF1 (½ residual)
            var f = feedForward(h, b.feedForward1, l.ff1a, l.ff1b)
            (x, h) = addNorm(x, f, half: true, l.att)
            // relative-position attention over [K/V cache ++ chunk]; the kernel also writes the next K/V cache
            let qkv = l.qkvLin?(h) ?? l.qkv(h)
            let cacheLen = state.keyCache[li]?.shape[1] ?? 0
            let cn = Swift.min(cacheLen + m, leftCache)
            let position = model.streamPositionProjection(a, layer: li, h, cacheLen: cacheLen, leftCache: leftCache, cached: state.usePositionCache)
            let empty = zeroRows(dtype)[0..., 0..<1, 0...]
            let att = Self.attentionKernel(
                [qkv, state.keyCache[li] ?? empty, state.valueCache[li] ?? empty, position,
                 a.posBiasU.asType(dtype), a.posBiasV.asType(dtype), dimsArray(m, cacheLen, cn)],
                template: [("H", heads), ("D", headDim), ("T", dtype)],
                grid: (headDim * heads, m, 1), threadGroup: (headDim, 1, 1),
                outputShapes: [[1, m, d], [1, cn, d], [1, cn, d]], outputDTypes: [dtype, dtype, dtype])
            state.keyCache[li] = att[1]
            state.valueCache[li] = att[2]
            (x, h) = addNorm(x, l.outLin?(att[0]) ?? a.linearOut(att[0]), half: false, l.conv)
            // GLU + causal depthwise conv + LayerNorm + SiLU; the kernel also writes the next conv cache
            let conv = Self.convKernel(
                [gemv(h, l.pw1), state.convCache[li] ?? zeroRows(dtype), l.dw, l.convLN.weight, l.convLN.bias],
                template: [("C", d), ("K", kernelSize), ("T", dtype)],
                grid: (d, 1, 1), threadGroup: (d, 1, 1),
                outputShapes: [[1, m, d], [1, kernelSize - 1, d]], outputDTypes: [dtype, dtype])
            state.convCache[li] = conv[1]
            (x, h) = addNorm(x, gemv(conv[0], l.pw2), half: false, l.ff2)
            // FF2 (½ residual), normOut, and the next layer's first norm
            f = feedForward(h, b.feedForward2, l.ff2a, l.ff2b)
            let next = li + 1 < layers.count ? layers[li + 1].ff1 : l.out
            (x, h) = addNorm(x, f, half: true, l.out, next)
        }
        state.attnCache = state.attnCache.map { _ in nil }
        return x
    }

    /// linear2(silu(linear1(h))): two small-M kernels (SiLU in the first one's epilogue) when both are eligible.
    private func feedForward(_ h: MLXArray, _ ff: NemotronASRFeedForward, _ a: SmallLinear?, _ b: SmallLinear?) -> MLXArray {
        if let a, let b { return b(a(h, silu: true)) }
        return ff.linear2(MLXNN.silu(ff.linear1(h)))
    }
}
