import Foundation
import MLX
import MLXFast

/// Small-M GEMM kernels for Apple GPUs: out[M, N] = epilogue(x[M, K] · Wᵀ), W row-major [N, K] (nn.Linear layout).
///
/// Canonical copy; vendor verbatim and record the source commit. Depends only on MLX and MLXFast.
///
/// Tile kernel (M 9…256): Metal 4 tensor ops (`matmul2d`, the matrix units of Apple GPU generation 17+). One
/// threadgroup owns a 32 × 32 output tile and its SG simdgroups each multiply 1/SG of K (split-K inside the
/// threadgroup); the float partial sums are added in threadgroup memory and rounded once. MLX 0.32.2 tiles 64 × 128
/// with 8 simdgroups on these GPUs, so small M leaves most cores idle; this kernel was 1.5–3.2× faster per GEMM at
/// M 16–64 on an M5 Max. Split-K reorders the sums (≤ 1 output ulp per GEMM): every caller gates it by tolerance.
///
/// GEMV kernel (M 1…8, any Apple GPU): one pass over the weights for all rows, float accumulation. Raw bandwidth is
/// about MLX's gemv; the gain comes from the fused epilogues (the SiLU-gate pair reads gate and up in one pass,
/// residual/bias added before the single rounding) and fewer launches. Also inexact (different summation order).
///
/// Callers: `let y = SmallMGEMM.matmul(x, weights, epilogue: e) ?? stock(x)`. `supports` answers the same question
/// without building a graph. `revision` is part of every gate key and changes whenever a summation order can change.
public enum SmallMGEMM {
    public enum WeightFormat: Equatable, Sendable {
        /// bfloat16 or float16 (x's dtype; w must match).
        case dense
        /// MLX quantized layout: packed w + scales + biases.
        case affine(bits: Int, groupSize: Int)
        /// MXFP4 / MXFP8, group 32.
        case mxfp(bits: Int)
    }

    public enum EpilogueKind: Equatable, Sendable { case none, bias, residual, biasResidual, siluGate }

    public struct Weights {
        public let w: MLXArray
        public let scales: MLXArray?
        public let biases: MLXArray?
        public let format: WeightFormat
        public init(w: MLXArray, scales: MLXArray? = nil, biases: MLXArray? = nil, format: WeightFormat = .dense) {
            self.w = w; self.scales = scales; self.biases = biases; self.format = format
        }
        /// Dense BF16/FP16 weight [N, K].
        public static func dense(_ w: MLXArray) -> Weights { Weights(w: w) }
        /// Output features N (rows of the unpacked weight).
        var n: Int { w.dim(0) }
    }

    public enum Epilogue {
        case none
        /// [N]
        case bias(MLXArray)
        /// [M, N]: out = xWᵀ + r
        case residual(MLXArray)
        case biasResidual(MLXArray, MLXArray)
        /// out = silu(x · gateᵀ) ⊙ (x · upᵀ); gate = the main `weights`, both read in one pass.
        case siluGate(up: Weights)

        public var kind: EpilogueKind {
            switch self {
            case .none: return .none
            case .bias: return .bias
            case .residual: return .residual
            case .biasResidual: return .biasResidual
            case .siluGate: return .siluGate
            }
        }
    }

    /// Per kernel family; gate keys include the families they use (or `revision` for all).
    public static let tileRevision = "tile-1"
    public static let gemvRevision = "gemv-1"
    public static let revision = tileRevision + " " + gemvRevision

    /// Row ranges per kernel family.
    public static let tileRows = 9 ... 256
    public static let gemvRows = 1 ... 8

    /// Tensor-op matmul needs Metal 4 and an Apple GPU of generation 17 or later (MLX's own test before its NAX
    /// kernels: `applegpu_g<gen><class>`, gen ≥ 17, phones ≥ 18).
    public static let tensorOpsAvailable: Bool = {
        let architecture = GPU.deviceInfo().architecture
        guard architecture.hasPrefix("applegpu_g") else { return false }
        let tail = architecture.dropFirst("applegpu_g".count)
        guard let generation = Int(tail.prefix(while: \.isNumber)), let family = tail.last else { return false }
        return generation >= (family == "p" ? 18 : 17)
    }()

    // MARK: - Capability

    /// Per-call capability check: false → the caller uses stock MLX for this call.
    /// Covers the GPU family (Apple gen ≥ 17 for the tile kernel's `matmul2d`; the GEMV kernel runs on any Apple
    /// GPU), dtype (bfloat16/float16), weight format, M range and K alignment (tile: K % 16; dense GEMV: K % 8;
    /// affine GEMV: bits 4|8, group 64, K % 64).
    public static func supports(m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind) -> Bool {
        gemvRows.contains(m) ? gemvPlan(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: epilogue) != nil
            : tilePlan(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: epilogue) != nil
    }

    /// out[M, N] = epilogue(x[..., K] · Wᵀ) with the leading dimensions of x flattened into M; nil when `supports`
    /// is false for this call or an operand does not fit (bias [N], residual [M, N] or [..., N]; the up projection of
    /// `.siluGate` in the same format and shape as the gate).
    public static func matmul(_ x: MLXArray, _ weights: Weights, epilogue: Epilogue = .none) -> MLXArray? {
        let k = x.dim(-1), n = weights.n, rows = x.size / max(k, 1)
        guard fits(weights, k: k, dtype: x.dtype) else { return nil }
        var bias: MLXArray?, residual: MLXArray?, up: Weights?
        switch epilogue {
        case .none: break
        case .bias(let b): bias = b
        case .residual(let r): residual = r
        case .biasResidual(let b, let r): bias = b; residual = r
        case .siluGate(let u): up = u
        }
        guard bias.map({ $0.size == n }) ?? true, residual.map({ $0.size == rows * n }) ?? true else { return nil }
        if let up {
            guard up.format == weights.format, up.w.shape == weights.w.shape, up.scales?.shape == weights.scales?.shape,
                  up.biases?.shape == weights.biases?.shape, fits(up, k: k, dtype: x.dtype) else { return nil }
        }
        let x2 = x.reshaped([rows, k])
        let out: MLXArray
        if gemvRows.contains(rows) {
            guard let plan = gemvPlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind) else { return nil }
            let flags: [(String, any KernelTemplateArg)] = [("MR", rows), ("R", plan.rowsPerGroup), ("SGK", plan.simdgroups),
                ("GATE", up != nil), ("HAS_BIAS", bias != nil), ("HAS_RES", residual != nil)]
            let geometry = (grid: ((n + plan.rowsPerGroup - 1) / plan.rowsPerGroup * 32 * plan.simdgroups, 1, 1),
                            threadGroup: (32 * plan.simdgroups, 1, 1))
            switch weights.format {
            case .dense:
                out = gemvKernel([x2, weights.w, up?.w ?? weights.w, bias ?? placeholder, residual ?? placeholder],
                                 template: [("T", x.dtype)] + flags, grid: geometry.grid, threadGroup: geometry.threadGroup,
                                 outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
            case .affine(let bits, let groupSize):
                let u = up ?? weights
                out = gemvAffineKernel([x2, weights.w, weights.scales!, weights.biases!, u.w, u.scales!, u.biases!,
                                        bias ?? placeholder, residual ?? placeholder],
                                       template: [("T", x.dtype), ("BITS", bits), ("GS", groupSize)] + flags,
                                       grid: geometry.grid, threadGroup: geometry.threadGroup,
                                       outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
            case .mxfp:
                return nil
            }
        } else {
            guard up == nil, let simdgroups = tilePlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind)
            else { return nil }
            out = tileKernel([x2, weights.w, bias ?? placeholder, residual ?? placeholder],
                             template: [("T", x.dtype), ("BM", tile), ("BN", tile), ("SG", simdgroups),
                                        ("HAS_BIAS", bias != nil), ("HAS_RES", residual != nil)],
                             grid: ((rows + tile - 1) / tile * 32 * simdgroups, (n + tile - 1) / tile, 1),
                             threadGroup: (32 * simdgroups, 1, 1), outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
        }
        return out.reshaped(Array(x.shape.dropLast()) + [n])
    }

    /// The weights' arrays match their format, K and the activation dtype.
    private static func fits(_ weights: Weights, k: Int, dtype: DType) -> Bool {
        guard weights.w.ndim == 2 else { return false }
        switch weights.format {
        case .dense:
            return weights.w.dtype == dtype && weights.w.dim(1) == k
        case .affine(let bits, let groupSize):
            guard bits == 4 || bits == 8, groupSize > 0, weights.w.dtype == .uint32, weights.w.dim(1) * 32 / bits == k,
                  let scales = weights.scales, let biases = weights.biases else { return false }
            let groups = [weights.w.dim(0), k / groupSize]
            return scales.shape == groups && biases.shape == groups && scales.dtype == dtype && biases.dtype == dtype
        case .mxfp:
            return false
        }
    }

    /// Stands in for an absent epilogue operand (never read); a host constant, so it adds no dispatch.
    private static let placeholder = MLXArray([Float(0)])

    // MARK: - Self-test

    /// Runs every supported (kernel, dtype, format, epilogue) class on fixed random inputs covering its M range and
    /// edge cases against stock MLX and returns the largest relative RMS per class (non-finite → ∞). Classes this GPU
    /// cannot run are absent. Class names: "<kernel>.<dtype>.<format>.<epilogue>", e.g. "tile.f16.dense.bias".
    public static func selfTest() -> [String: Float] {
        var results: [String: Float] = [:]
        var seed: UInt64 = 0x5eed
        func random(_ shape: [Int], _ dtype: DType, scale: Float = 1) -> MLXArray {
            seed += 1
            return (MLXRandom.normal(shape, key: MLXRandom.key(seed)) * scale).asType(dtype)
        }
        func record(_ name: String, _ value: Float) { results[name] = Swift.max(results[name] ?? 0, value) }
        // (M, N, K): both simdgroup counts, partial row and column tiles, uneven K splits (K % (SG * 16) != 0).
        let tileShapes = [(9, 96, 272), (33, 200, 512), (100, 160, 1040), (256, 64, 384)]
        let epilogues: [(String, EpilogueKind)] = [("none", .none), ("bias", .bias), ("residual", .residual), ("biasResidual", .biasResidual)]
        for (dtypeName, dtype) in [("bf16", DType.bfloat16), ("f16", DType.float16)] {
            for (m, n, k) in tileShapes {
                let x = random([m, k], dtype), w = random([n, k], dtype, scale: 0.05)
                let b = random([n], dtype), r = random([m, n], dtype)
                let product = MLX.matmul(x, w.transposed())
                for (epilogueName, kind) in epilogues where supports(m: m, n: n, k: k, dtype: dtype, format: .dense, epilogue: kind) {
                    let epilogue: Epilogue, reference: MLXArray
                    switch kind {
                    case .bias: epilogue = .bias(b); reference = product + b
                    case .residual: epilogue = .residual(r); reference = product + r
                    case .biasResidual: epilogue = .biasResidual(b, r); reference = product + b + r
                    default: epilogue = .none; reference = product
                    }
                    let name = "tile.\(dtypeName).dense.\(epilogueName)"
                    record(name, matmul(x, .dense(w), epilogue: epilogue).map { relativeRMS($0, reference) } ?? .infinity)
                }
            }
        }
        // GEMV: every row count 1…8 appears; N not a multiple of the rows per threadgroup; K not a multiple of 256;
        // the last two are in the quantized kernels' range (M ≤ 2, K ≥ 2048).
        let gemvShapes = [(1, 200, 1032), (2, 96, 512), (3, 64, 264), (4, 136, 2048), (5, 72, 776), (6, 48, 128), (7, 520, 1024), (8, 257, 3072),
                          (1, 136, 2048), (2, 70, 3072)]
        for (dtypeName, dtype) in [("bf16", DType.bfloat16), ("f16", DType.float16)] {
            for (m, n, k) in gemvShapes {
                let x = random([m, k], dtype), w = random([n, k], dtype, scale: 0.05), u = random([n, k], dtype, scale: 0.05)
                let b = random([n], dtype), r = random([m, n], dtype)
                // Dense and, where K allows, MLX affine 8/4-bit group 64 (reference: MLX's quantized matmul).
                // (name, gate weights, up weights, stock x · gateᵀ, stock x · upᵀ)
                var formats: [(String, Weights, Weights, MLXArray, MLXArray)] = [
                    ("dense", .dense(w), .dense(u), MLX.matmul(x, w.transposed()), MLX.matmul(x, u.transposed()))]
                if k % 64 == 0 {
                    for bits in [8, 4] {
                        let qw = MLX.quantized(w, groupSize: 64, bits: bits), qu = MLX.quantized(u, groupSize: 64, bits: bits)
                        let format = WeightFormat.affine(bits: bits, groupSize: 64)
                        let ww = Weights(w: qw.wq, scales: qw.scales, biases: qw.biases, format: format)
                        let uw = Weights(w: qu.wq, scales: qu.scales, biases: qu.biases, format: format)
                        formats.append(("affine\(bits)", ww, uw,
                                        MLX.quantizedMM(x, qw.wq, scales: qw.scales, biases: qw.biases, transpose: true, groupSize: 64, bits: bits),
                                        MLX.quantizedMM(x, qu.wq, scales: qu.scales, biases: qu.biases, transpose: true, groupSize: 64, bits: bits)))
                    }
                }
                for (formatName, ww, uw, pw, pu) in formats {
                    let cases: [(String, Epilogue, () -> MLXArray)] = [
                        ("none", .none, { pw }), ("bias", .bias(b), { pw + b }), ("residual", .residual(r), { pw + r }),
                        ("biasResidual", .biasResidual(b, r), { pw + b + r }),
                        ("siluGate", .siluGate(up: uw), { silu(pw) * pu })]
                    for (epilogueName, epilogue, reference) in cases
                    where supports(m: m, n: n, k: k, dtype: dtype, format: ww.format, epilogue: epilogue.kind) {
                        let name = "gemv.\(dtypeName).\(formatName).\(epilogueName)"
                        record(name, matmul(x, ww, epilogue: epilogue).map { relativeRMS($0, reference()) } ?? .infinity)
                    }
                }
            }
        }
        return results
    }

    /// silu(a) = a · sigmoid(a), as MLXNN's `silu`, without depending on MLXNN.
    private static func silu(_ a: MLXArray) -> MLXArray { a * MLX.sigmoid(a) }

    /// Self-test bounds per weight format (relative RMS vs stock MLX).
    public static func selfTestBound(_ className: String) -> Float {
        className.contains(".affine") || className.contains(".mxfp") ? 3e-2 : 2e-2
    }

    /// Names of the classes whose self-test result is non-finite or above its bound (empty = pass).
    public static func selfTestFailures(_ results: [String: Float]) -> [String] {
        results.filter { !($0.value <= selfTestBound($0.key)) }.keys.sorted()
    }

    /// ‖a − b‖ / ‖b‖ in Float32; ∞ when non-finite.
    public static func relativeRMS(_ a: MLXArray, _ b: MLXArray) -> Float {
        let a32 = a.asType(.float32), b32 = b.asType(.float32), d = a32 - b32
        let value = MLX.sqrt((d * d).sum() / (b32 * b32).sum()).item(Float.self)
        return value.isFinite ? value : .infinity
    }

    // MARK: - Tile kernel (tile-1)

    private static let tile = 32
    /// Simdgroups per threadgroup for the tile kernel, or nil when it cannot run the call.
    private static func tilePlan(m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind) -> Int? {
        // More simdgroups for fewer rows: 8 up to 64 rows, 4 above (microbench, M5 Max).
        let simdgroups = m <= 64 ? 8 : 4
        guard tensorOpsAvailable, dtype == .bfloat16 || dtype == .float16, format == .dense, epilogue != .siluGate,
              tileRows.contains(m), n > 0, k % 16 == 0, k >= simdgroups * 16 else { return nil }
        return simdgroups
    }

    private struct GemvPlan { let rowsPerGroup: Int; let simdgroups: Int }

    /// Output features per threadgroup (R) and simdgroups splitting K (SGK) for the GEMV kernels, or nil when they
    /// cannot run the call. Chosen per shape from the M5 Max microbench (lab notes, 28 Sep).
    private static func gemvPlan(m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind) -> GemvPlan? {
        guard gemvRows.contains(m), n > 0, k > 0, dtype == .bfloat16 || dtype == .float16 else { return nil }
        switch format {
        case .dense:
            guard k % 8 == 0 else { return nil }
            // M5 Max, 16 decode shapes (N×K 256…8192): within 3–4 % of each shape's best (R, SGK).
            return GemvPlan(rowsPerGroup: 2, simdgroups: m <= 4 ? 4 : 2)
        case .affine(let bits, let groupSize):
            // Rows 1…2 and K ≥ 2048 only: there it beat MLX's qmv (M5 Max, FFN blocks, M = 1: 1.06–1.14×); at K 1024
            // or M ≥ 3 it was slower (0.46–0.8×), so those calls stay on MLX. R = 4 / SGK = 2 measured worse per block.
            guard bits == 4 || bits == 8, groupSize == 64, k % groupSize == 0, k >= 2048, m <= 2 else { return nil }
            return GemvPlan(rowsPerGroup: 2, simdgroups: 4)
        case .mxfp:
            return nil
        }
    }

    static let tileHeader = #"""
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace mpp::tensor_ops;
"""#

    // x [M, K] and w [N, K] row-major T (bfloat or half); out [M, N] = x · wᵀ (+ bias[n]) (+ res[m, n]).
    // Grid: x = M tiles (threadgroups sharing a weight tile are dispatched together), y = N tiles. K is split into
    // 16-wide chunks spread over the SG simdgroups as evenly as possible; with K % (SG * 16) == 0 every simdgroup gets
    // K / SG, which is tile-1's order. The epilogue adds in float and rounds once; `bias`/`res` are 1-element
    // placeholders when HAS_BIAS/HAS_RES is 0. The host guarantees K % 16 == 0 and K >= SG * 16.
    static let tileSource = #"""
    const int M = x_shape[0], K = x_shape[1], N = w_shape[0];
    const int tm = threadgroup_position_in_grid.x, tn = threadgroup_position_in_grid.y;
    const int sg = simdgroup_index_in_threadgroup;
    const int chunks = K / 16, base = chunks / SG, extra = chunks % SG;
    const int k0 = 16 * (sg * base + min(sg, extra)), kc = 16 * (base + (sg < extra ? 1 : 0));
    auto A = tensor<device T, dextents<int32_t, 2>, tensor_inline>((device T*)x + k0, dextents<int32_t, 2>(kc, M), array<int, 2>{1, K});
    auto B = tensor<device T, dextents<int32_t, 2>, tensor_inline>((device T*)w + k0, dextents<int32_t, 2>(kc, N), array<int, 2>{1, K});
    constexpr auto desc = matmul2d_descriptor(BM, BN, static_cast<int>(dynamic_extent), false, true, false);
    matmul2d<desc, execution_simdgroup> op;
    auto mA = A.slice(0, tm * BM);
    auto mB = B.slice(0, tn * BN);
    auto cT = op.template get_destination_cooperative_tensor<decltype(mA), decltype(mB), float>();
    #pragma unroll
    for (uint16_t i = 0; i < cT.get_capacity(); ++i) { if (cT.is_valid_element(i)) cT[i] = 0; }
    op.run(mA, mB, cT);
    threadgroup float red[SG][BM * BN];
    #pragma unroll
    for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
        if (!cT.is_valid_element(i)) continue;
        auto idx = cT.get_multidimensional_index(i);
        red[sg][idx[1] * BN + idx[0]] = cT[i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int e = thread_index_in_threadgroup; e < BM * BN; e += SG * 32) {
        float s = 0.0f;
        #pragma unroll
        for (int j = 0; j < SG; ++j) s += red[j][e];
        const int n = tn * BN + e % BN, m = tm * BM + e / BN;
        if (n < N && m < M) {
            if (HAS_BIAS) s += static_cast<float>(bias[n]);
            if (HAS_RES) s += static_cast<float>(res[m * N + n]);
            out[m * N + n] = static_cast<T>(s);
        }
    }
"""#

    private static let tileKernel = MLXFast.metalKernel(name: "smallm_tile", inputNames: ["x", "w", "bias", "res"], outputNames: ["out"],
                                                        source: tileSource, header: tileHeader)

    // MARK: - GEMV kernel (gemv-1)

    // x [MR, K] and w [N, K] row-major T (bfloat or half), MR = 1…8 rows; out [MR, N] = x · wᵀ, or with GATE
    // silu(x · wᵀ) ⊙ (x · upᵀ) (up [N, K]), then (+ bias[n]) (+ res[m, n]). One threadgroup = SGK simdgroups computing
    // R consecutive output features for all MR rows, so every weight element is read once. Lane l of simdgroup s reads
    // 8 consecutive elements at k = (i · SGK + s) · 256 + 8 l; per lane the products are summed in order in float,
    // then `simd_sum`, then the SGK partials in order; the epilogue runs in float and rounds once. Absent operands are
    // 1-element placeholders (`up` = w when GATE is 0). The host guarantees K % 8 == 0.
    static let gemvSource = #"""
    constexpr int V = 8;
    const int K = x_shape[1], N = w_shape[0];
    const int n0 = threadgroup_position_in_grid.x * R;
    const int sg = simdgroup_index_in_threadgroup, lane = thread_index_in_simdgroup;
    constexpr int G = GATE ? 2 : 1;
    float acc[G][MR][R];
    #pragma unroll
    for (int g = 0; g < G; ++g)
        #pragma unroll
        for (int m = 0; m < MR; ++m)
            #pragma unroll
            for (int r = 0; r < R; ++r) acc[g][m][r] = 0.0f;
    for (int k = (sg * 32 + lane) * V; k < K; k += SGK * 32 * V) {
        vec<T, 4> xv[MR][2];
        #pragma unroll
        for (int m = 0; m < MR; ++m) {
            xv[m][0] = *(device const vec<T, 4>*)(x + m * K + k);
            xv[m][1] = *(device const vec<T, 4>*)(x + m * K + k + 4);
        }
        #pragma unroll
        for (int g = 0; g < G; ++g) {
            device const T* wg = g == 0 ? w : up;
            #pragma unroll
            for (int r = 0; r < R; ++r) {
                const size_t row = (size_t)min(n0 + r, N - 1) * K;
                const vec<T, 4> w0 = *(device const vec<T, 4>*)(wg + row + k);
                const vec<T, 4> w1 = *(device const vec<T, 4>*)(wg + row + k + 4);
                #pragma unroll
                for (int m = 0; m < MR; ++m) {
                    float s = 0.0f;
                    #pragma unroll
                    for (int i = 0; i < 4; ++i) s += static_cast<float>(xv[m][0][i]) * static_cast<float>(w0[i]);
                    #pragma unroll
                    for (int i = 0; i < 4; ++i) s += static_cast<float>(xv[m][1][i]) * static_cast<float>(w1[i]);
                    acc[g][m][r] += s;
                }
            }
        }
    }
    threadgroup float part[SGK][G * MR * R];
    #pragma unroll
    for (int g = 0; g < G; ++g)
        #pragma unroll
        for (int m = 0; m < MR; ++m)
            #pragma unroll
            for (int r = 0; r < R; ++r) {
                const float v = simd_sum(acc[g][m][r]);
                if (lane == 0) part[sg][(g * MR + m) * R + r] = v;
            }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int e = sg * 32 + lane; e < MR * R; e += SGK * 32) {
        const int m = e / R, n = n0 + e % R;
        if (n >= N) continue;
        float a = 0.0f;
        #pragma unroll
        for (int j = 0; j < SGK; ++j) a += part[j][e];
        if (GATE) {
            float u = 0.0f;
            #pragma unroll
            for (int j = 0; j < SGK; ++j) u += part[j][MR * R + e];
            a = a / (1.0f + metal::precise::exp(-a)) * u;
        }
        if (HAS_BIAS) a += static_cast<float>(bias[n]);
        if (HAS_RES) a += static_cast<float>(res[m * N + n]);
        out[m * N + n] = static_cast<T>(a);
    }
"""#

    private static let gemvKernel = MLXFast.metalKernel(name: "smallm_gemv", inputNames: ["x", "w", "up", "bias", "res"], outputNames: ["out"],
                                                        source: gemvSource)

    // x [MR, K] row-major T; w = MLX affine-quantized [N, K]: packed uint32 [N, K · BITS / 32], scales and biases
    // [N, K / GS] (T), element = scale · q + bias. Same threadgroup layout and epilogue as the dense GEMV; each lane
    // reads 16 bytes of packed weights per row and step (4-bit 32 elements, 8-bit 16), which lie in one group, and
    // adds scale · Σ x·q + bias · Σ x for it (the product form MLX's qmv uses). The host guarantees K % GS == 0.
    static let gemvAffineSource = #"""
    constexpr int PW = 32 / BITS;                 // elements per uint32
    constexpr int V = 4 * PW;                     // elements per lane and step (one uint4 of packed weights)
    constexpr uint MASK = (1u << BITS) - 1u;
    const int K = x_shape[1], N = scales_shape[0];
    const int KW = K / PW, KG = K / GS;
    const int n0 = threadgroup_position_in_grid.x * R;
    const int sg = simdgroup_index_in_threadgroup, lane = thread_index_in_simdgroup;
    constexpr int G = GATE ? 2 : 1;
    float acc[G][MR][R];
    #pragma unroll
    for (int g = 0; g < G; ++g)
        #pragma unroll
        for (int m = 0; m < MR; ++m)
            #pragma unroll
            for (int r = 0; r < R; ++r) acc[g][m][r] = 0.0f;
    for (int k = (sg * 32 + lane) * V; k < K; k += SGK * 32 * V) {
        uint4 q[G][R];
        #pragma unroll
        for (int g = 0; g < G; ++g) {
            device const uint32_t* wg = g == 0 ? w : upw;
            #pragma unroll
            for (int r = 0; r < R; ++r) q[g][r] = *(device const uint4*)(wg + (size_t)min(n0 + r, N - 1) * KW + k / PW);
        }
        float dot[G][MR][R];
        float xs[MR];
        #pragma unroll
        for (int m = 0; m < MR; ++m) {
            xs[m] = 0.0f;
            #pragma unroll
            for (int g = 0; g < G; ++g)
                #pragma unroll
                for (int r = 0; r < R; ++r) dot[g][m][r] = 0.0f;
        }
        #pragma unroll
        for (int j = 0; j < 4; ++j) {
            #pragma unroll
            for (int m = 0; m < MR; ++m) {
                float xv[PW];
                #pragma unroll
                for (int i = 0; i < PW; ++i) { xv[i] = static_cast<float>(x[m * K + k + j * PW + i]); xs[m] += xv[i]; }
                #pragma unroll
                for (int g = 0; g < G; ++g)
                    #pragma unroll
                    for (int r = 0; r < R; ++r) {
                        const uint word = q[g][r][j];
                        float d = 0.0f;
                        #pragma unroll
                        for (int i = 0; i < PW; ++i) d += xv[i] * static_cast<float>((word >> (BITS * i)) & MASK);
                        dot[g][m][r] += d;
                    }
            }
        }
        #pragma unroll
        for (int g = 0; g < G; ++g) {
            device const T* sc = g == 0 ? scales : upscales;
            device const T* bi = g == 0 ? biases : upbiases;
            #pragma unroll
            for (int r = 0; r < R; ++r) {
                const size_t gi = (size_t)min(n0 + r, N - 1) * KG + k / GS;
                const float s = static_cast<float>(sc[gi]), b = static_cast<float>(bi[gi]);
                #pragma unroll
                for (int m = 0; m < MR; ++m) acc[g][m][r] += s * dot[g][m][r] + b * xs[m];
            }
        }
    }
    threadgroup float part[SGK][G * MR * R];
    #pragma unroll
    for (int g = 0; g < G; ++g)
        #pragma unroll
        for (int m = 0; m < MR; ++m)
            #pragma unroll
            for (int r = 0; r < R; ++r) {
                const float v = simd_sum(acc[g][m][r]);
                if (lane == 0) part[sg][(g * MR + m) * R + r] = v;
            }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int e = sg * 32 + lane; e < MR * R; e += SGK * 32) {
        const int m = e / R, n = n0 + e % R;
        if (n >= N) continue;
        float a = 0.0f;
        #pragma unroll
        for (int j = 0; j < SGK; ++j) a += part[j][e];
        if (GATE) {
            float u = 0.0f;
            #pragma unroll
            for (int j = 0; j < SGK; ++j) u += part[j][MR * R + e];
            a = a / (1.0f + metal::precise::exp(-a)) * u;
        }
        if (HAS_BIAS) a += static_cast<float>(bias[n]);
        if (HAS_RES) a += static_cast<float>(res[m * N + n]);
        out[m * N + n] = static_cast<T>(a);
    }
"""#

    private static let gemvAffineKernel = MLXFast.metalKernel(
        name: "smallm_gemv_affine", inputNames: ["x", "w", "scales", "biases", "upw", "upscales", "upbiases", "bias", "res"],
        outputNames: ["out"], source: gemvAffineSource)
}
