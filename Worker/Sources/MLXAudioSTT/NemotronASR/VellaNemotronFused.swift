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

        init?(_ layers: [Linear]) {
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
                weight = MLX.concatenated(layers.map(\.weight), axis: 0)
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

    init?(_ encoder: NemotronASRConformer) {
        let first = encoder.layers[0]
        let d = first.selfAttn.nFeat, h = first.selfAttn.nHead, hd = first.selfAttn.headDim
        let k = first.conv.depthwiseConv.weight.shape[1]
        guard d % 256 == 0, d <= 1024, hd == 128, h * hd == d, k >= 1, first.conv.padRight == 0, first.conv.padLeft == k - 1 else { return nil }
        var built: [Layer] = []
        for b in encoder.layers {
            let a = b.selfAttn, c = b.conv
            guard a.nHead == h, a.headDim == hd, c.depthwiseConv.bias == nil, c.pointwiseConv1.bias == nil, c.pointwiseConv2.bias == nil,
                  c.depthwiseConv.weight.shape == [d, k, 1], c.pointwiseConv1.weight.shape == [2 * d, 1, d], c.pointwiseConv2.weight.shape == [d, 1, d],
                  let qkv = Projection([a.linearQ, a.linearK, a.linearV]),
                  let ff1 = Norm(b.normFeedForward1), let att = Norm(b.normSelfAtt), let conv = Norm(b.normConv),
                  let convLN = Norm(c.batchNorm), let ff2 = Norm(b.normFeedForward2), let out = Norm(b.normOut) else { return nil }
            // The 1×1 convs run from BF16 weights (half the traffic of the Float32 copies); only when that is exact.
            guard let pw1 = Self.bf16(c.pointwiseConv1), let pw2 = Self.bf16(c.pointwiseConv2) else { return nil }
            built.append(Layer(block: b, qkv: qkv,
                               pw1: pw1.reshaped([2 * d, d]),
                               pw2: pw2.reshaped([d, d]),
                               dw: c.depthwiseConv.weight.reshaped([d, k]),
                               ff1: ff1, att: att, conv: conv, convLN: convLN, ff2: ff2, out: out))
        }
        layers = built
        dModel = d; heads = h; headDim = hd; kernelSize = k
        MLX.eval(layers.flatMap { [$0.qkv.weight, $0.dw] })
    }

    /// The conv's weight as BF16 if that is lossless (checkpoint values are BF16); the stock module then uses it too.
    private static func bf16(_ conv: Conv1d) -> MLXArray? {
        let w = conv.weight
        guard w.dtype != .bfloat16 else { return w }
        let b = w.asType(.bfloat16)
        guard MLX.all(b.asType(w.dtype) .== w).item(Bool.self) else { return nil }
        eval(b)
        _ = conv.update(parameters: ModuleParameters.unflattened(["weight": b]))
        return b
    }

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
            var f = b.feedForward1.linear2(MLXNN.silu(b.feedForward1.linear1(h)))
            (x, h) = addNorm(x, f, half: true, l.att)
            // relative-position attention over [K/V cache ++ chunk]; the kernel also writes the next K/V cache
            let qkv = l.qkv(h)
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
            (x, h) = addNorm(x, a.linearOut(att[0]), half: false, l.conv)
            // GLU + causal depthwise conv + LayerNorm + SiLU; the kernel also writes the next conv cache
            let conv = Self.convKernel(
                [gemv(h, l.pw1), state.convCache[li] ?? zeroRows(dtype), l.dw, l.convLN.weight, l.convLN.bias],
                template: [("C", d), ("K", kernelSize), ("T", dtype)],
                grid: (d, 1, 1), threadGroup: (d, 1, 1),
                outputShapes: [[1, m, d], [1, kernelSize - 1, d]], outputDTypes: [dtype, dtype])
            state.convCache[li] = conv[1]
            (x, h) = addNorm(x, gemv(conv[0], l.pw2), half: false, l.ff2)
            // FF2 (½ residual), normOut, and the next layer's first norm
            f = b.feedForward2.linear2(MLXNN.silu(b.feedForward2.linear1(h)))
            let next = li + 1 < layers.count ? layers[li + 1].ff1 : l.out
            (x, h) = addNorm(x, f, half: true, l.out, next)
        }
        state.attnCache = state.attnCache.map { _ in nil }
        return x
    }
}

enum VellaNemotronFusedMetal {
    /// Rows per chunk the kernels support (a streaming chunk has 4 frames; the flush tail a few more).
    static let maxRows = 8

    static let header = #"""
#define rt(v) float(static_cast<T>(v))
// Per-row sums over a threadgroup of C threads (one channel per thread) for up to 8 rows at once;
// every thread gets the totals. red holds 8 × 32 partial sums.
template <int C>
inline void vn_rowsums(thread float* s, int M, threadgroup float* red, uint lane, uint sg) {
    for (int m = 0; m < 8; m++) { if (m < M) { float t = simd_sum(s[m]); if (lane == 0) red[m * 32 + sg] = t; } }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int m = 0; m < 8; m++) { if (m < M) { float t = 0.0f; for (int i = 0; i < C / 32; i++) t += red[m * 32 + i]; s[m] = t; } }
    threadgroup_barrier(mem_flags::mem_threadgroup);
}
// LayerNorm (eps 1e-5) of every row's value v[m] at channel c.
template <int C, typename W>
inline void vn_layernorm(thread float* v, int M, const device W* w, const device W* b, uint c, threadgroup float* red, uint lane, uint sg) {
    float s[8];
    for (int m = 0; m < 8; m++) s[m] = m < M ? v[m] : 0.0f;
    vn_rowsums<C>(s, M, red, lane, sg);
    float mean[8], q[8];
    for (int m = 0; m < 8; m++) { mean[m] = s[m] / float(C); float d = m < M ? v[m] - mean[m] : 0.0f; q[m] = d * d; }
    vn_rowsums<C>(q, M, red, lane, sg);
    float wc = float(w[c]), bc = float(b[c]);
    for (int m = 0; m < 8; m++) if (m < M) v[m] = (v[m] - mean[m]) * metal::precise::rsqrt(q[m] / float(C) + 1e-5f) * wc + bc;
}
// Sum over a threadgroup of C threads; every thread gets the total.
template <int C>
inline float vn_sum1(float s, threadgroup float* red, uint lane, uint sg) {
    s = simd_sum(s);
    if (lane == 0) red[sg] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float t = lane < uint(C / 32) ? red[lane] : 0.0f;
    t = simd_sum(t);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return t;
}
template <int C, typename W>
inline float vn_ln1(float v, W w, W b, threadgroup float* red, uint lane, uint sg) {
    float mean = vn_sum1<C>(v, red, lane, sg) / float(C);
    float d = v - mean;
    float var = vn_sum1<C>(d * d, red, lane, sg) / float(C);
    return d * metal::precise::rsqrt(var + 1e-5f) * float(w) + float(b);
}
// Eight bf16 values from 16 bytes, widened to float (bf16 is the top half of an fp32).
inline void vn_load8(const device bfloat16_t* p, thread float* o) {
    uint4 u = *reinterpret_cast<const device uint4*>(p);
    uint w[4] = {u.x, u.y, u.z, u.w};
    for (int i = 0; i < 4; i++) { o[2*i] = as_type<float>(w[i] << 16); o[2*i+1] = as_type<float>(w[i] & 0xffff0000u); }
}
"""#

    /// grid (C, M), threadgroup C: one row per threadgroup, one channel per thread.
    /// TWO false: o0 = x + a·r, o1 = LN1(o0). TWO true: o0 = LN1(x + a·r), o1 = LN2(o0).
    static let addNorm = #"""
uint c = thread_position_in_threadgroup.x;
uint row = threadgroup_position_in_grid.y;
uint lane = c % 32, sg = c / 32;
threadgroup float red[32];
uint at = row * C + c;
float a = float(x[at]), d = float(r[at]);
float v = rt(HALF ? a + 0.5f * d : a + d);
if (!TWO) o0[at] = static_cast<T>(v);
v = vn_ln1<C>(v, w1[c], b1[c], red, lane, sg);
if (TWO) {
    v = rt(v); o0[at] = static_cast<T>(v);
    v = vn_ln1<C>(v, w2[c], b2[c], red, lane, sg);
}
o1[at] = static_cast<T>(v);
"""#

    /// grid (D·H, M), threadgroup D: one (head h, query i) per threadgroup, one key per thread for the scores.
    /// score_j = scale·(q+u)·k_j + scale·(q+v)·p_(j+M-1-i): the stock Transformer-XL relative shift, p rows
    /// ordered from relative position +(K-1) down to -(K-1). Keys = [K/V cache (C rows) ++ chunk (M rows)];
    /// kn/vn = the last CN rows of those keys/values (the next cache).
    static let attention = #"""
constexpr int HD = H * D;
uint h = threadgroup_position_in_grid.x;
uint i = threadgroup_position_in_grid.y;
uint t = thread_position_in_threadgroup.x;
int M = dims[0], C = dims[1], CN = dims[2];
int K = C + M;
threadgroup float4 qu[D / 4], qv[D / 4];
threadgroup float e[D];
threadgroup float stat[2];
float q = float(qkv[i * 3 * HD + h * D + t]);
((threadgroup float*)qu)[t] = q + float(bu[h * D + t]);
((threadgroup float*)qv)[t] = q + float(bv[h * D + t]);
threadgroup_barrier(mem_flags::mem_threadgroup);
const float scale = metal::precise::rsqrt(float(D));
if (int(t) < K) {
    int j = int(t);
    const device T* k = j < C ? kc + j * HD + h * D : qkv + (j - C) * 3 * HD + HD + h * D;
    const device T* pr = p + (j + M - 1 - int(i)) * HD + h * D;
    float a = 0.0f, b = 0.0f;
    for (int d = 0; d < D / 4; d++) {
        float4 kk = float4(k[4*d], k[4*d+1], k[4*d+2], k[4*d+3]);
        float4 pp = float4(pr[4*d], pr[4*d+1], pr[4*d+2], pr[4*d+3]);
        a += dot(qu[d], kk); b += dot(qv[d], pp);
    }
    e[t] = a * scale + b * scale;
}
threadgroup_barrier(mem_flags::mem_threadgroup);
if (t < 32) {
    float mx = -INFINITY;
    for (int j = int(t); j < K; j += 32) mx = metal::max(mx, e[j]);
    mx = simd_max(mx);
    if (t == 0) stat[0] = mx;
}
threadgroup_barrier(mem_flags::mem_threadgroup);
if (int(t) < K) e[t] = metal::precise::exp(e[t] - stat[0]);
threadgroup_barrier(mem_flags::mem_threadgroup);
if (t < 32) {
    float s = 0.0f;
    for (int j = int(t); j < K; j += 32) s += e[j];
    s = simd_sum(s);
    if (t == 0) stat[1] = s;
}
threadgroup_barrier(mem_flags::mem_threadgroup);
uint col = h * D + t;
float acc = 0.0f;
for (int j = 0; j < K; j++) {
    float v = j < C ? float(vc[j * HD + col]) : float(qkv[(j - C) * 3 * HD + 2 * HD + col]);
    acc += e[j] * v;
}
out[i * HD + col] = static_cast<T>(acc / stat[1]);
for (int r = int(i); r < CN; r += M) {
    int s = K - CN + r;
    kn[r * HD + col] = s < C ? kc[s * HD + col] : qkv[(s - C) * 3 * HD + HD + col];
    vn[r * HD + col] = s < C ? vc[s * HD + col] : qkv[(s - C) * 3 * HD + 2 * HD + col];
}
"""#

    /// One threadgroup of C threads (channel c = thread), every row of the chunk.
    /// din = [cache (K-1 rows) ++ GLU(pw) (M rows)]; y_m = SiLU(LN(Σ_k w_k · din_(m+k))); cn = the last K-1 rows of din.
    static let conv = #"""
constexpr int L = K - 1;
uint c = thread_position_in_threadgroup.x;
uint lane = c % 32, sg = c / 32;
int M = int(pw_shape[1]);
threadgroup float red[8 * 32];
float din[L + 8];
for (int r = 0; r < L; r++) din[r] = float(cc[r * C + c]);
for (int m = 0; m < 8; m++) if (m < M) {
    float a = float(pw[m * 2 * C + c]), b = float(pw[m * 2 * C + C + c]);
    din[L + m] = rt(a * rt(1.0f / (1.0f + metal::precise::exp(-b))));
}
float wk[K];
for (int k = 0; k < K; k++) wk[k] = float(w[c * K + k]);
float v[8];
for (int m = 0; m < 8; m++) if (m < M) {
    float acc = 0.0f;
    for (int k = 0; k < K; k++) acc += wk[k] * din[m + k];
    v[m] = rt(acc);
}
vn_layernorm<C>(v, M, lw, lb, c, red, lane, sg);
for (int m = 0; m < 8; m++) if (m < M) { float z = rt(v[m]); y[m * C + c] = static_cast<T>(z / (1.0f + metal::precise::exp(-z))); }
for (int r = 0; r < L; r++) cn[r * C + c] = static_cast<T>(din[M + r]);
"""#

    /// y (M, N) = x (M, KD) · Wᵀ with W (N, KD) BF16 row-major (the 1×1 conv layout), Float32 accumulation.
    /// Each simdgroup computes ROWS output columns for every row; 8 simdgroups per threadgroup.
    static let gemv = #"""
uint lane = thread_index_in_simdgroup;
uint n0 = (threadgroup_position_in_grid.x * 8 + simdgroup_index_in_threadgroup) * ROWS;
int M = int(x_shape[1]);
if (n0 >= uint(N)) return;
float acc[8][ROWS];
for (int m = 0; m < 8; m++) for (int r = 0; r < ROWS; r++) acc[m][r] = 0.0f;
for (int k = lane * 8; k < KD; k += 256) {
    float wv[ROWS][8];
    for (int r = 0; r < ROWS; r++) vn_load8(W + (n0 + r) * KD + k, wv[r]);
    for (int m = 0; m < 8; m++) if (m < M) {
        const device T* xr = x + m * KD + k;
        float xv[8];
        for (int u = 0; u < 8; u++) xv[u] = float(xr[u]);
        for (int r = 0; r < ROWS; r++) { float s = 0.0f; for (int u = 0; u < 8; u++) s += xv[u] * wv[r][u]; acc[m][r] += s; }
    }
}
for (int m = 0; m < 8; m++) if (m < M) for (int r = 0; r < ROWS; r++) {
    float s = simd_sum(acc[m][r]);
    if (lane == 0) y[m * N + n0 + r] = static_cast<T>(s);
}
"""#
}

