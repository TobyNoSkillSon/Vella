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
    public static let revision = tileRevision

    /// Row ranges per kernel family.
    public static let tileRows = 9 ... 256

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
    public static func supports(m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind) -> Bool {
        tilePlan(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: epilogue) != nil
    }

    /// out[M, N] = epilogue(x[..., K] · Wᵀ) with the leading dimensions of x flattened into M; nil when `supports`
    /// is false for this call or an epilogue operand has the wrong size (bias [N], residual [M, N] or [..., N]).
    public static func matmul(_ x: MLXArray, _ weights: Weights, epilogue: Epilogue = .none) -> MLXArray? {
        let k = x.dim(-1), n = weights.n, rows = x.size / max(k, 1)
        guard weights.w.ndim == 2, weights.format == .dense, weights.w.dtype == x.dtype, weights.w.dim(1) == k else { return nil }
        var bias: MLXArray?, residual: MLXArray?
        switch epilogue {
        case .none: break
        case .bias(let b): bias = b
        case .residual(let r): residual = r
        case .biasResidual(let b, let r): bias = b; residual = r
        case .siluGate: return nil
        }
        guard bias.map({ $0.size == n }) ?? true, residual.map({ $0.size == rows * n }) ?? true,
              let simdgroups = tilePlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind) else { return nil }
        let out = tileKernel([x.reshaped([rows, k]), weights.w, bias ?? placeholder, residual ?? placeholder],
                             template: [("T", x.dtype), ("BM", tile), ("BN", tile), ("SG", simdgroups),
                                        ("HAS_BIAS", bias != nil), ("HAS_RES", residual != nil)],
                             grid: ((rows + tile - 1) / tile * 32 * simdgroups, (n + tile - 1) / tile, 1),
                             threadGroup: (32 * simdgroups, 1, 1), outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
        return out.reshaped(Array(x.shape.dropLast()) + [n])
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
        return results
    }

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
}
