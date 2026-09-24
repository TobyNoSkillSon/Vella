import MLX

// Adapted from the Python/MLX reference for the checkpoint's actual dtypes.
// All weights remain kernel inputs, never captured compilation constants.
enum FastParakeetMetal {
    static let src = #"""
uint c = thread_position_in_grid.x;
uint t = thread_position_in_grid.y;
int T = int(y_shape[1]);  // runtime length: one compiled kernel serves every clip
if (c >= C || int(t) >= T) return;
float acc = 0.0f;
for (int k = 0; k < K; k++) {
    int s = int(t) + k - PAD;
    if (s < 0 || s >= T) continue;
    float a = float(y[s * 2 * C + c]);
    float g = float(y[s * 2 * C + C + c]);
    // Match the stock activation dtype (BF16 or FP32) at each materialized op.
    float gate = static_cast<float>(static_cast<OT>(1.0f / (1.0f + metal::exp(-g))));
    float glu = static_cast<float>(static_cast<OT>(a * gate));
    acc += glu * float(w[c * K + k]);
}
float v = static_cast<float>(static_cast<OT>(acc));
v = static_cast<float>(static_cast<OT>(v + float(bias[c])));
float o = v / (1.0f + metal::exp(-v));
out[t * C + c] = static_cast<OT>(o);
"""#
    static let header = #"""

// Eight bf16 values from 16 bytes, widened to float (bf16 is the top half of an fp32).
inline void load8(const device bfloat16_t* p, thread float* o) {
    uint4 u = *reinterpret_cast<const device uint4*>(p);
    uint w[4] = {u.x, u.y, u.z, u.w};
    for (int i = 0; i < 4; i++) { o[2*i] = as_type<float>(w[i] << 16); o[2*i+1] = as_type<float>(w[i] & 0xffff0000u); }
}
inline void load8(const device half* p, thread float* o) { for (int i = 0; i < 8; i++) o[i] = float(p[i]); }
inline void load8(const device float* p, thread float* o) { for (int i = 0; i < 8; i++) o[i] = p[i]; }
inline float sigm(float v) { return 1.0f / (1.0f + metal::exp(-v)); }
// metal::tanh overflows to NaN for |v| > ~44; this form saturates to +/-1.
inline float stanh(float v) { float e = metal::exp(-2.0f * metal::abs(v)); return metal::copysign((1.0f - e) / (1.0f + e), v); }
"""#
    static let joint = #"""
#define rb(v) static_cast<float>(static_cast<RT>(v))
uint lane = thread_position_in_threadgroup.x;
uint sg = thread_position_in_threadgroup.y;
uint row = thread_position_in_grid.y;
threadgroup float z[D];
int tt = min(t[0], int(enc_p_shape[0]) - 1);
for (uint k = sg * 32 + lane; k < D; k += 32 * NSG) z[k] = max(rb(float(enc_p[tt * D + k]) + float(pred_p[k])), 0.0f);
threadgroup_barrier(mem_flags::mem_threadgroup);
if (row >= NOUT) return;
float acc = 0.0f, w[8];
for (uint k = lane * 8; k < D; k += 256) {
    load8(W + row * D + k, w);
    for (int i = 0; i < 8; i++) acc += z[k + i] * w[i];
}
acc = simd_sum(acc);
if (lane == 0) logits[row] = rb(rb(acc) + float(b[row]));
"""#
    static let argmax = #"""
uint tid = thread_position_in_threadgroup.x;
uint lane = tid % 32, sg = tid / 32;
threadgroup float sv[32];
threadgroup int si[32];
float best = -INFINITY; int bi = 0x7fffffff;
for (uint i = tid; i < V; i += 1024) {
    float v = logits[i];
    if (v > best) { best = v; bi = int(i); }
}
for (ushort o = 16; o > 0; o >>= 1) {
    float ov = simd_shuffle_down(best, o); int oi = simd_shuffle_down(bi, o);
    if (ov > best || (ov == best && oi < bi)) { best = ov; bi = oi; }
}
if (lane == 0) { sv[sg] = best; si[sg] = bi; }
threadgroup_barrier(mem_flags::mem_threadgroup);
if (tid == 0) {
    float b2 = sv[0]; int i2 = si[0];
    for (int s = 1; s < 32; s++) if (sv[s] > b2 || (sv[s] == b2 && si[s] < i2)) { b2 = sv[s]; i2 = si[s]; }
    int di = 0; float dv = logits[V];
    for (int d = 1; d < NDUR; d++) if (logits[V + d] > dv) { dv = logits[V + d]; di = d; }
    int dur = durations[di];
    int time = t[0];
    bool active = time < n_frames[0];
    bool emit = active && (i2 != BLANK);
    int syms = new_syms[0] + 1;
    int nt = time + dur;
    bool forced = (dur == 0) && (syms >= max_symbols[0]);
    if (forced) nt += 1;
    if (dur != 0 || forced) syms = 0;
    tok_o[0] = i2; dur_o[0] = dur; emit_o[0] = emit ? 1 : 0;
    t_o[0] = active ? nt : time;
    syms_o[0] = active ? syms : new_syms[0];
    last_o[0] = emit ? i2 : last[0];
}
"""#
    static let lstm1 = #"""
#define rb(v) static_cast<float>(static_cast<RT>(v))
uint lane = thread_position_in_grid.x;
uint j = thread_position_in_grid.y;
if (j >= H) return;
bool e = emit[0] != 0;
if (!e) {
    if (lane == 0) { h_o[j] = h[j]; c_o[j] = c[j]; ch_o[j] = ch[j]; cc_o[j] = cc[j]; }
    return;
}
// Emission: committed state := candidate; new candidate from the emitted token.
float acc[4] = {0, 0, 0, 0};
float w[8];
for (uint k = lane * 8; k < H; k += 256) {
    float hv[8]; for (int i = 0; i < 8; i++) hv[i] = float(ch[k + i]);
    for (int q = 0; q < 4; q++) { load8(Wh + (q * H + j) * H + k, w); for (int i = 0; i < 8; i++) acc[q] += hv[i] * w[i]; }
}
for (int q = 0; q < 4; q++) acc[q] = simd_sum(acc[q]);
if (lane == 0) {
    int tk = tok[0];
    float g[4];
    for (int q = 0; q < 4; q++) g[q] = rb(float(table[tk * 4 * H + q * H + j]) + acc[q]);
    // MLX materializes each BF16 activation and product, then the sum.
    float cn = rb(rb(rb(sigm(g[1])) * float(cc[j])) + rb(rb(sigm(g[0])) * rb(stanh(g[2]))));
    float hn = rb(rb(sigm(g[3])) * rb(stanh(cn)));
    h_o[j] = ch[j]; c_o[j] = cc[j]; ch_o[j] = OT(hn); cc_o[j] = OT(cn);
}
"""#
    static let lstm2 = #"""
#define rb(v) static_cast<float>(static_cast<RT>(v))
uint lane = thread_position_in_grid.x;
uint j = thread_position_in_grid.y;
if (j >= H) return;
bool e = emit[0] != 0;
if (!e) {
    if (lane == 0) { h_o[j] = h[j]; c_o[j] = c[j]; ch_o[j] = ch[j]; cc_o[j] = cc[j]; }
    return;
}
float accX[4] = {0, 0, 0, 0};
float accH[4] = {0, 0, 0, 0};
float w[8];
for (uint k = lane * 8; k < H; k += 256) {
    float xv[8], hv[8]; for (int i = 0; i < 8; i++) { xv[i] = float(x[k + i]); hv[i] = float(ch[k + i]); }
    for (int q = 0; q < 4; q++) {
        load8(Wx + (q * H + j) * H + k, w); for (int i = 0; i < 8; i++) accX[q] += xv[i] * w[i];
        load8(Wh + (q * H + j) * H + k, w); for (int i = 0; i < 8; i++) accH[q] += hv[i] * w[i];
    }
}
for (int q = 0; q < 4; q++) { accX[q] = simd_sum(accX[q]); accH[q] = simd_sum(accH[q]); }
if (lane == 0) {
    float g[4];
    for (int q = 0; q < 4; q++) g[q] = rb(rb(float(bias[q * H + j]) + accX[q]) + accH[q]);
    float cn = rb(rb(rb(sigm(g[1])) * float(cc[j])) + rb(rb(sigm(g[0])) * rb(stanh(g[2]))));
    float hn = rb(rb(sigm(g[3])) * rb(stanh(cn)));
    h_o[j] = ch[j]; c_o[j] = cc[j]; ch_o[j] = OT(hn); cc_o[j] = OT(cn);
}
"""#
    static let pred = #"""
#define rb(v) static_cast<float>(static_cast<RT>(v))
uint lane = thread_position_in_grid.x;
uint j = thread_position_in_grid.y;
if (j >= P) return;
if (emit[0] == 0) { if (lane == 0) out[j] = old[j]; return; }
float acc = 0.0f;
float w[8];
for (uint k = lane * 8; k < H; k += 256) { load8(W + j * H + k, w); for (int i = 0; i < 8; i++) acc += float(x[k + i]) * w[i]; }
acc = simd_sum(acc);
if (lane == 0) out[j] = OT(rb(rb(acc) + float(b[j])));
"""#
}
