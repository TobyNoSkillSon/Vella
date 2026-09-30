import Foundation
import MLX
import MLXNN

enum VellaNemotronFusedMetal {
    /// Rows per chunk the kernels support (a streaming chunk has 4 frames; the flush tail a few more).
    static let maxRows = 8
    /// Small-M linear shape: output columns per threadgroup (R) and simdgroups splitting K (S).
    /// Per shape from a dependent-chain microbench (M5 Max, M = 4, BF16 weights; `lab/perf/vk-stream/gemvchain.py`):
    /// K 4096 (FF linear2) R8 S4, N >= 2048 (FF linear1, Q/K/V) R2 S4, 1024x1024 R2 S2.
    static func linearShape(n: Int, k: Int) -> (r: Int, s: Int) {
        if k >= 4096 { return (8, 4) }
        return n >= 2048 ? (2, 4) : (2, 2)
    }

    /// y (M, N) = x (M, KD) * W^T for M <= 8 Float32 rows: a threadgroup of S simdgroups owns R output columns, each
    /// simdgroup a contiguous K/S slice (8 consecutive K per lane and step), float accumulation, the S partial sums
    /// added in threadgroup memory in simdgroup order; SILU applies x*sigmoid(x) to the sum. The weight is read once
    /// for all M rows. W is BF16 (N, KD) row-major.
    static let linear = #"""
constexpr int KS = KD / S;
uint lane = thread_index_in_simdgroup;
uint sg = simdgroup_index_in_threadgroup;
uint n0 = threadgroup_position_in_grid.x * R;
threadgroup float red[S][M][R];
float acc[M][R];
for (int m = 0; m < M; m++) for (int r = 0; r < R; r++) acc[m][r] = 0.0f;
for (int k = int(sg) * KS + int(lane) * 8; k < int(sg + 1) * KS; k += 256) {
    float xv[M][8];
    for (int m = 0; m < M; m++) {
        const device float4* xr = reinterpret_cast<const device float4*>(x + m * KD + k);
        float4 a = xr[0], b = xr[1];
        xv[m][0] = a.x; xv[m][1] = a.y; xv[m][2] = a.z; xv[m][3] = a.w;
        xv[m][4] = b.x; xv[m][5] = b.y; xv[m][6] = b.z; xv[m][7] = b.w;
    }
    for (int r = 0; r < R; r++) {
        float wv[8];
        vn_load8(W + (n0 + r) * KD + k, wv);
        for (int m = 0; m < M; m++) { float s = 0.0f; for (int u = 0; u < 8; u++) s += xv[m][u] * wv[u]; acc[m][r] += s; }
    }
}
for (int m = 0; m < M; m++) for (int r = 0; r < R; r++) {
    float s = simd_sum(acc[m][r]);
    if (lane == 0) red[sg][m][r] = s;
}
threadgroup_barrier(mem_flags::mem_threadgroup);
uint t = sg * 32 + lane;
if (t < uint(M * R)) {
    int m = int(t) / R, r = int(t) % R;
    float s = 0.0f;
    for (int i = 0; i < S; i++) s += red[i][m][r];
    if (SILU) s = s / (1.0f + metal::precise::exp(-s));
    y[m * N + n0 + r] = s;
}
"""#
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
