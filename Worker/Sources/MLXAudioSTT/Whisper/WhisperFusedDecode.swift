import Foundation
import MLX
import MLXFast
import MLXNN

/// Fused Whisper decode step (one new token against the KV caches), part of the optimized `decoder` component.
/// Stock runs ~22 dispatches per decoder layer at FP16 (~30 quantized) for a step that is launch-bound at M = 1:
/// three self-attention projections, two concatenations of two copies each for the K/V cache, and three separate
/// residual adds before three LayerNorms. This path is token-exact with stock (same kernels on the same values):
/// - `qkv`: one GEMV over the concatenated q|k|v rows (MLX picks the same `gemv` configuration for N 1280 and
///   3840, and each output row's reduction depends only on K; k's zero bias adds exactly 0), then one kernel that
///   appends the new K/V rows to the caches and lays q out per head (pure copies).
/// - `norm`: the residual add and the following LayerNorm in one kernel that replays MLX's `add` (one rounding in
///   the activation dtype) and `layer_norm_single_row` (N_READS 8, sequential per-thread sum, `simd_sum`, `simd_sum` of
///   the simdgroup sums, precise `rsqrt`, `w * T(x) + b`). Quantized checkpoints also fold the preceding Linear's
///   bias add (stock: `quantizedMM` then `+ bias`, one rounding each).
/// Used on quantized checkpoints only. v2-mini A/B (M5 Max, 28 Sep, lab/notes/vk-whisper-REPORT.md): large-v3 4b
/// 36.5 → 38.1× and 104.7 → 95.9 J/min; at FP16 the step is GEMV-bandwidth bound and the fusion was within noise
/// (v3 +1.0 % speed / +0.5 % J, turbo +0.6 % / −1.1 %), so dense checkpoints keep the plain step.
final class WhisperFusedDecoder {
    static let parts: Set<String> = ["qkv", "norm"]

    /// One projection over concatenated rows: FP16 `addMM` with the concatenated bias, or `quantizedMM` + bias.
    struct Projection {
        let weight: MLXArray
        let bias: MLXArray
        let scales: MLXArray?, biases: MLXArray?
        let groupSize: Int, bits: Int, mode: QuantizationMode

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            guard let scales else { return addMM(bias, x, weight.T) }
            return quantizedMM(x, weight, scales: scales, biases: biases, transpose: true, groupSize: groupSize,
                               bits: bits, mode: mode) + bias
        }
    }

    let useQKV: Bool
    let useNorm: Bool
    private let qkv: [Projection]
    private let dModel: Int, heads: Int, headDim: Int
    private let eps: MLXArray

    /// nil when this checkpoint does not have the stock Whisper decoder layout the kernels assume.
    init?(_ decoder: WhisperDecoder, parts: Set<String> = WhisperFusedDecoder.parts) {
        guard !parts.isEmpty, let first = decoder.layers.first,
              first.selfAttn.qProj is QuantizedLinear else { return nil }
        let attention = first.selfAttn
        dModel = attention.embedDim; heads = attention.numHeads; headDim = attention.headDim
        guard heads * headDim == dModel, dModel % 8 == 0, dModel <= 6656,
              [DType.float16, .bfloat16, .float32].contains(first.selfAttnLayerNorm.weight?.dtype ?? .int32) else { return nil }
        eps = MLXArray(first.selfAttnLayerNorm.eps)
        useNorm = parts.contains("norm")
        var projections: [Projection] = []
        if parts.contains("qkv") {
            for layer in decoder.layers {
                let a = layer.selfAttn
                guard let projection = Self.fuse([a.qProj, a.kProj, a.vProj]) else { return nil }
                projections.append(projection)
            }
        }
        qkv = projections
        useQKV = !projections.isEmpty
    }

    /// Concatenate the rows of q|k|v. The stock layers are then pointed at row slices of the fused copy (views,
    /// identical values), so fusing keeps no second copy of the weights and stock stays exact.
    private static func fuse(_ layers: [Linear]) -> Projection? {
        let dtype = (layers[0] as? QuantizedLinear)?.scales.dtype ?? layers[0].weight.dtype
        let bias = MLX.concatenated(layers.map { $0.bias ?? MLXArray.zeros([$0.weight.shape[0]], dtype: dtype) }, axis: 0)
        let quantized = layers.compactMap { $0 as? QuantizedLinear }
        if quantized.count == layers.count {
            let q0 = quantized[0]
            guard quantized.allSatisfy({ $0.groupSize == q0.groupSize && $0.bits == q0.bits && $0.mode == q0.mode
                                         && $0.globalScale == nil && ($0.biases == nil) == (q0.biases == nil) }) else { return nil }
            var fused = ["weight": MLX.concatenated(quantized.map(\.weight), axis: 0),
                         "scales": MLX.concatenated(quantized.map(\.scales), axis: 0)]
            if q0.biases != nil { fused["biases"] = MLX.concatenated(quantized.compactMap(\.biases), axis: 0) }
            eval(Array(fused.values) + [bias])
            share(layers, fused)
            return Projection(weight: fused["weight"]!, bias: bias, scales: fused["scales"], biases: fused["biases"],
                              groupSize: q0.groupSize, bits: q0.bits, mode: q0.mode)
        }
        guard quantized.isEmpty, layers.allSatisfy({ $0.weight.dtype == dtype }) else { return nil }
        let weight = MLX.concatenated(layers.map(\.weight), axis: 0)
        eval(weight, bias)
        share(layers, ["weight": weight])
        return Projection(weight: weight, bias: bias, scales: nil, biases: nil, groupSize: 0, bits: 0, mode: .affine)
    }

    private static func share(_ layers: [Linear], _ fused: [String: MLXArray]) {
        var row = 0
        for layer in layers {
            let rows = layer.weight.shape[0]
            let slices = fused.mapValues { $0[row ..< row + rows] }
            eval(Array(slices.values))
            _ = layer.update(parameters: ModuleParameters.unflattened(slices))
            row += rows
        }
    }

    // MARK: - Step

    /// The decoder for one token at `position` (caches already hold the prompt): returns the final-LayerNorm
    /// hidden state [1, 1, d], equal to `WhisperDecoder.callAsFunction` on the same inputs.
    func step(_ decoder: WhisperDecoder, token: MLXArray, position: Int, caches: inout [WhisperLayerCache]) -> MLXArray {
        let positions = decoder.embedPositions(MLXArray([Int32(position)])).expandedDimensions(axis: 0)
        var h = decoder.embedTokens(token) + positions
        var normed = decoder.layers[0].selfAttnLayerNorm(h)
        let count = decoder.layers.count
        for index in 0 ..< count {
            let layer = decoder.layers[index]
            // Self-attention.
            let attention = layer.selfAttn
            let q: MLXArray
            if useQKV, let keys = caches[index].selfKeys, let values = caches[index].selfValues {
                let parts = append(qkv[index](normed), keys: keys, values: values)
                q = parts[0]; caches[index].selfKeys = parts[1]; caches[index].selfValues = parts[2]
            } else {
                q = attention.qProj(normed).reshaped([1, 1, heads, headDim]).transposed(0, 2, 1, 3)
                let k = attention.kProj(normed).reshaped([1, 1, heads, headDim]).transposed(0, 2, 1, 3)
                let v = attention.vProj(normed).reshaped([1, 1, heads, headDim]).transposed(0, 2, 1, 3)
                caches[index].selfKeys = caches[index].selfKeys.map { MLX.concatenated([$0, k], axis: 2) } ?? k
                caches[index].selfValues = caches[index].selfValues.map { MLX.concatenated([$0, v], axis: 2) } ?? v
            }
            let selfOut = MLXFast.scaledDotProductAttention(
                queries: q, keys: caches[index].selfKeys!, values: caches[index].selfValues!,
                scale: attention.scaling, mask: .none)
            (h, normed) = residualNorm(h, attention.outProj, merge(selfOut), layer.encoderAttnLayerNorm)
            // Cross-attention over the cached encoder K/V.
            let cross = layer.encoderAttn
            let q2 = cross.qProj(normed).reshaped([1, 1, heads, headDim]).transposed(0, 2, 1, 3)
            let crossOut = MLXFast.scaledDotProductAttention(
                queries: q2, keys: caches[index].crossKeys!, values: caches[index].crossValues!,
                scale: cross.scaling, mask: .none)
            (h, normed) = residualNorm(h, cross.outProj, merge(crossOut), layer.finalLayerNorm)
            // MLP, then the next layer's first LayerNorm (the decoder's final one after the last layer).
            let next = index + 1 < count ? decoder.layers[index + 1].selfAttnLayerNorm : decoder.layerNorm
            (h, normed) = residualNorm(h, layer.fc2, gelu(layer.fc1(normed)), next)
        }
        return normed
    }

    private func merge(_ attention: MLXArray) -> MLXArray {
        attention.transposed(0, 2, 1, 3).reshaped([1, 1, dModel])
    }

    /// residual + linear(x), then `norm` of the sum; returns (sum, normalized).
    private func residualNorm(_ residual: MLXArray, _ linear: Linear, _ x: MLXArray, _ norm: LayerNorm) -> (MLXArray, MLXArray) {
        guard useNorm, let w = norm.weight, let b = norm.bias, w.dtype == residual.dtype, b.dtype == residual.dtype else {
            let sum = residual + linear(x)
            return (sum, norm(sum))
        }
        let dtype = residual.dtype
        let threads = 32 * (((dModel + 7) / 8 + 31) / 32)
        let template: [(String, any KernelTemplateArg)] = [("T", dtype), ("D", dModel)]
        if let q = linear as? QuantizedLinear, let bias = q.bias {
            let raw = quantizedMM(x, q.weight, scales: q.scales, biases: q.biases, transpose: true,
                                  groupSize: q.groupSize, bits: q.bits, mode: q.mode)
            guard q.globalScale == nil else {
                let sum = residual + linear(x)
                return (sum, norm(sum))
            }
            let out = Self.addNormBias([residual, raw, bias, w, b, eps], template: template, grid: (threads, 1, 1),
                                       threadGroup: (threads, 1, 1), outputShapes: [residual.shape, residual.shape],
                                       outputDTypes: [dtype, dtype])
            return (out[0], out[1])
        }
        let out = Self.addNorm([residual, linear(x), w, b, eps], template: template, grid: (threads, 1, 1),
                               threadGroup: (threads, 1, 1), outputShapes: [residual.shape, residual.shape],
                               outputDTypes: [dtype, dtype])
        return (out[0], out[1])
    }

    /// qkv [1, 1, 3d] + caches [1, H, T, hd] → q [1, H, 1, hd], K/V [1, H, T+1, hd] (one dispatch, copies only).
    private func append(_ qkv: MLXArray, keys: MLXArray, values: MLXArray) -> [MLXArray] {
        let t = keys.shape[2]
        return Self.appendKernel([qkv, keys, values], template: [("T", qkv.dtype), ("H", heads), ("HD", headDim)],
                                 grid: (headDim, t + 1, 2 * heads), threadGroup: (min(headDim, 64), 1, 1),
                                 outputShapes: [[1, heads, 1, headDim], [1, heads, t + 1, headDim], [1, heads, t + 1, headDim]],
                                 outputDTypes: [qkv.dtype, qkv.dtype, qkv.dtype])
    }

    // MARK: - Kernels

    private static let appendKernel = MLXFast.metalKernel(
        name: "vella_whisper_qkv_append", inputNames: ["qkv", "kc", "vc"], outputNames: ["q", "k", "v"],
        source: """
            uint d = thread_position_in_grid.x;
            uint t = thread_position_in_grid.y;
            uint z = thread_position_in_grid.z;
            uint head = z % H;
            bool isValue = z >= H;
            uint old = kc_shape[2];
            uint row = head * HD + d;
            uint dst = (head * (old + 1) + t) * HD + d;
            if (!isValue) {
                k[dst] = t < old ? kc[(head * old + t) * HD + d] : qkv[H * HD + row];
                if (t == 0) { q[row] = qkv[row]; }
            } else {
                v[dst] = t < old ? vc[(head * old + t) * HD + d] : qkv[2 * H * HD + row];
            }
            """)

    /// MLX `layer_norm_single_row` (N_READS 8) on `r + y`, verbatim apart from the fused add.
    private static let normBody = """
            constexpr int N_READS = 8;
            constexpr int SIMD_SIZE = 32;
            uint lid = thread_position_in_threadgroup.x;
            float thread_x[N_READS] = {0};
            threadgroup float local_buffer[SIMD_SIZE];
            if (simdgroup_index_in_threadgroup == 0) { local_buffer[thread_index_in_simdgroup] = 0; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            const uint base = lid * N_READS;
            const bool safe = base + N_READS <= D;
            const int n = int(D) - int(base);
            for (int i = 0; i < N_READS; i++) {
                if (safe || i < n) {
                    T s = SUM_EXPR;
                    h_out[base + i] = s;
                    thread_x[i] = s;
                }
            }
            float mean = 0;
            for (int i = 0; i < N_READS; i++) { mean += thread_x[i]; }
            mean = simd_sum(mean);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (thread_index_in_simdgroup == 0) { local_buffer[simdgroup_index_in_threadgroup] = mean; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            mean = local_buffer[thread_index_in_simdgroup];
            mean = simd_sum(mean);
            mean /= D;
            float normalizer = 0;
            if (!safe) { for (int i = max(n, 0); i < N_READS; i++) { thread_x[i] = mean; } }
            for (int i = 0; i < N_READS; i++) {
                thread_x[i] -= mean;
                normalizer += thread_x[i] * thread_x[i];
            }
            normalizer = simd_sum(normalizer);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (thread_index_in_simdgroup == 0) { local_buffer[simdgroup_index_in_threadgroup] = normalizer; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            normalizer = local_buffer[thread_index_in_simdgroup];
            normalizer = simd_sum(normalizer);
            normalizer = metal::precise::rsqrt(normalizer / D + eps);
            for (int i = 0; i < N_READS; i++) {
                if (safe || i < n) {
                    thread_x[i] *= normalizer;
                    n_out[base + i] = w[base + i] * static_cast<T>(thread_x[i]) + b[base + i];
                }
            }
            """

    private static let addNorm = MLXFast.metalKernel(
        name: "vella_whisper_add_norm", inputNames: ["r", "y", "w", "b", "eps"], outputNames: ["h_out", "n_out"],
        source: normBody.replacingOccurrences(of: "SUM_EXPR", with: "r[base + i] + y[base + i]"))

    private static let addNormBias = MLXFast.metalKernel(
        name: "vella_whisper_add_bias_norm", inputNames: ["r", "y", "yb", "w", "b", "eps"], outputNames: ["h_out", "n_out"],
        source: normBody.replacingOccurrences(of: "SUM_EXPR", with: "r[base + i] + static_cast<T>(y[base + i] + yb[base + i])"))
}
