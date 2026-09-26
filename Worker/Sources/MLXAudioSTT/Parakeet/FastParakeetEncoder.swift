import MLX
import MLXNN

/// Inference-only fused Conformer, kept outside the checkpoint's module tree.
/// Construct only after weights are loaded; every compiled FFN receives weights as arguments.
final class FastParakeetEncoder {
    private struct Projection {
        let weight: MLXArray
        let scales: MLXArray?
        let biases: MLXArray?
        let bias: MLXArray?
        let groupSize: Int
        let bits: Int
        let mode: QuantizationMode

        init(_ layers: [Linear], dense: Bool, dtype: DType) {
            let quantized = layers.compactMap { $0 as? QuantizedLinear }
            if !dense && quantized.count == layers.count && quantized.allSatisfy({ $0.groupSize == quantized[0].groupSize && $0.bits == quantized[0].bits && $0.mode == quantized[0].mode }) {
                weight = MLX.concatenated(quantized.map(\.weight), axis: 0)
                scales = MLX.concatenated(quantized.map(\.scales), axis: 0)
                biases = quantized[0].biases == nil ? nil : MLX.concatenated(quantized.compactMap(\.biases), axis: 0)
                groupSize = quantized[0].groupSize; bits = quantized[0].bits; mode = quantized[0].mode
                if layers.count > 1 {
                    var fused = ["weight": weight, "scales": scales!]
                    if let biases { fused["biases"] = biases }
                    Self.share(layers, fused)
                }
            } else {
                let weights = layers.map { layer -> MLXArray in
                    guard let q = layer as? QuantizedLinear else { return layer.weight.asType(dtype) }
                    return MLX.dequantized(q.weight, scales: q.scales, biases: q.biases, groupSize: q.groupSize, bits: q.bits, mode: q.mode, globalScale: q.globalScale, dtype: dtype)
                }
                let fused = MLX.concatenated(weights, axis: 0)
                weight = fused.transposed()
                if layers.count > 1 && layers.allSatisfy({ !($0 is QuantizedLinear) && $0.weight.dtype == dtype }) {
                    Self.share(layers, ["weight": fused])
                }
                scales = nil; biases = nil; groupSize = 0; bits = 0; mode = .affine
            }
            bias = layers.allSatisfy { $0.bias != nil } ? MLX.concatenated(layers.compactMap(\.bias), axis: 0).asType(dtype) : nil
        }

        /// Point the stock layers' parameters at row slices of the fused copy (views, same values),
        /// so fusing Q/K/V does not keep a second copy of those weights (Ultra BF16: ~150 MB).
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

        func call(_ x: MLXArray) -> MLXArray {
            let y: MLXArray
            if let scales {
                y = MLX.quantizedMM(x, weight, scales: scales, biases: biases, groupSize: groupSize, bits: bits, mode: mode)
            } else {
                y = MLX.matmul(x, weight)
            }
            return bias.map { y + $0 } ?? y
        }
    }

    private struct Pointwise {
        let weight: MLXArray
        let bias: MLXArray?
        init(_ conv: Conv1d, dtype: DType) {
            weight = conv.weight[0..., 0, 0...].asType(dtype).transposed()
            bias = conv.bias?.asType(dtype)
        }
        func call(_ x: MLXArray) -> MLXArray {
            let y = MLX.matmul(x, weight)
            return bias.map { y + $0 } ?? y
        }
    }

    private struct Block {
        let stock: ParakeetConformerBlock
        let qkv, out, pos, ff11, ff12, ff21, ff22: Projection
        let pw1, pw2: Pointwise
        let dwWeight, dwBias: MLXArray
        let heads, headDim, kernelSize: Int
        let scale: Float
    }

    private let stock: ParakeetConformer
    private let blocks: [Block]
    private let useFusedConvolution: Bool
    private let fusedConv = MLXFast.metalKernel(name: "vella_glu_dwconv_silu", inputNames: ["y", "w", "bias"], outputNames: ["out"], source: FastParakeetMetal.src)
    private let compiledFFN: @Sendable ([MLXArray]) -> [MLXArray] = MLX.compile(shapeless: true) { a in
        let h = MLXFast.layerNorm(a[0], weight: a[1], bias: a[2], eps: 1e-5)
        return [a[0] + 0.5 * MLX.matmul(MLXNN.silu(MLX.matmul(h, a[3])), a[4])]
    }

    init?(_ encoder: ParakeetConformer, dense: Bool = true, dtype: DType = .bfloat16, fusedConvolution: Bool = true) {
        guard encoder.posEnc != nil, encoder.preEncodeDw != nil,
              encoder.layers.allSatisfy({ $0.relSelfAttn != nil && Dictionary(uniqueKeysWithValues: $0.conv.batchNorm.parameters().flattened())["running_var"] != nil && Dictionary(uniqueKeysWithValues: $0.conv.batchNorm.parameters().flattened())["running_mean"] != nil && $0.conv.batchNorm.weight != nil && $0.conv.batchNorm.bias != nil }) else { return nil }
        stock = encoder
        useFusedConvolution = fusedConvolution
        blocks = encoder.layers.map { b in
            let a = b.relSelfAttn!, c = b.conv, bn = c.batchNorm
            let stats = Dictionary(uniqueKeysWithValues: bn.parameters().flattened())
            let scale = bn.weight! / MLX.sqrt(stats["running_var"]! + MLXArray(bn.eps))
            let dw = (c.depthwiseConv.weight * scale.reshaped([-1, 1, 1])).asType(dtype)
            let dwBias = (bn.bias! - stats["running_mean"]! * scale + (c.depthwiseConv.bias.map { $0 * scale } ?? MLXArray.zeros(like: scale))).asType(dtype)
            return Block(stock: b, qkv: Projection([a.linearQ, a.linearK, a.linearV], dense: dense, dtype: dtype),
                         out: Projection([a.linearOut], dense: dense, dtype: dtype), pos: Projection([a.linearPos], dense: dense, dtype: dtype),
                         ff11: Projection([b.feedForward1.linear1], dense: dense, dtype: dtype), ff12: Projection([b.feedForward1.linear2], dense: dense, dtype: dtype),
                         ff21: Projection([b.feedForward2.linear1], dense: dense, dtype: dtype), ff22: Projection([b.feedForward2.linear2], dense: dense, dtype: dtype),
                         pw1: Pointwise(c.pointwiseConv1, dtype: dtype), pw2: Pointwise(c.pointwiseConv2, dtype: dtype),
                         dwWeight: dw, dwBias: dwBias, heads: a.nHead, headDim: a.headDim,
                         kernelSize: c.depthwiseConv.weight.shape[1], scale: a.scale)
        }
        MLX.eval(blocks.flatMap { [$0.dwWeight, $0.dwBias, $0.qkv.weight, $0.pw1.weight, $0.pw2.weight] })
    }

    private func ff(_ x: MLXArray, norm: LayerNorm, a: Projection, b: Projection) -> MLXArray {
        if a.scales == nil && b.scales == nil && a.bias == nil && b.bias == nil,
           let nw = norm.weight, let nb = norm.bias {
            return compiledFFN([x, nw, nb, a.weight, b.weight])[0]
        }
        return x + 0.5 * b.call(MLXNN.silu(a.call(norm(x))))
    }

    private func relShift(_ x: MLXArray) -> MLXArray {
        let s = x.shape
        let padded = MLX.padded(x, widths: [.init(0), .init(0), .init(0), .init((1, 0))])
        return padded.reshaped([s[0], s[1], s[3]+1, s[2]])[0..., 0..., 1..., 0...].reshaped(s)
    }

    func call(_ mel: MLXArray, lengths: MLXArray?) -> (MLXArray, MLXArray) {
        let n = lengths ?? MLXArray(Array(repeating: Int32(mel.shape[1]), count: mel.shape[0]))
        let encoded = stock.preEncodeDw!(mel, lengths: n)
        let positioned = stock.posEnc!(encoded.0)
        var x = positioned.0
        let position = positioned.1
        for l in blocks {
            let b = l.stock, a = b.relSelfAttn!
            x = ff(x, norm: b.normFeedForward1, a: l.ff11, b: l.ff12)
            let h = b.normSelfAtt(x), batch = h.shape[0], time = h.shape[1], dim = h.shape[2]
            let projected = l.qkv.call(h).split(parts: 3, axis: -1)
            let q = projected[0].reshaped([batch, time, l.heads, l.headDim])
            let k = projected[1].reshaped([batch, time, l.heads, l.headDim]).transposed(0, 2, 1, 3)
            let v = projected[2].reshaped([batch, time, l.heads, l.headDim]).transposed(0, 2, 1, 3)
            let p = l.pos.call(position).reshaped([batch, -1, l.heads, l.headDim]).transposed(0, 2, 1, 3)
            let qu = (q + a.posBiasU.asType(q.dtype)).transposed(0, 2, 1, 3)
            let qv = (q + a.posBiasV.asType(q.dtype)).transposed(0, 2, 1, 3)
            let bd = relShift(MLX.matmul(qv, p.swappedAxes(-2, -1)))[0..., 0..., 0..., ..<time] * MLXArray(l.scale).asType(q.dtype)
            let attended = MLXFast.scaledDotProductAttention(queries: qu, keys: k, values: v, scale: l.scale, mask: .array(bd))
            x = x + l.out.call(attended.transposed(0, 2, 1, 3).reshaped([batch, time, dim]))
            let y = l.pw1.call(b.normConv(x))
            let channels = y.shape[2] / 2, kernel = l.kernelSize
            let middle: MLXArray
            if useFusedConvolution {
                middle = fusedConv([y, l.dwWeight.reshaped([channels, kernel]), l.dwBias],
                                   template: [("C", channels), ("K", kernel), ("PAD", (kernel-1)/2), ("OT", y.dtype)],
                                   grid: (channels, time, 1), threadGroup: (256, 1, 1),
                                   outputShapes: [[batch, time, channels]], outputDTypes: [y.dtype])[0]
            } else {
                let split = y.split(parts: 2, axis: -1)
                let gated = split[0] * MLX.sigmoid(split[1])
                middle = MLXNN.silu(MLX.conv1d(gated, l.dwWeight, padding: (kernel-1)/2, groups: channels) + l.dwBias)
            }
            x = x + l.pw2.call(middle)
            x = ff(x, norm: b.normFeedForward2, a: l.ff21, b: l.ff22)
            x = b.normOut(x)
        }
        return (x, encoded.1)
    }
}
