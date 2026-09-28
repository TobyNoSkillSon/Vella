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
    /// is false for this call.
    public static func matmul(_ x: MLXArray, _ weights: Weights, epilogue: Epilogue = .none) -> MLXArray? {
        let k = x.dim(-1), n = weights.n, rows = x.size / max(k, 1)
        guard weights.w.ndim == 2, weights.w.dtype == x.dtype, weights.w.dim(1) == k else { return nil }
        guard let plan = tilePlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind) else { return nil }
        let x2 = x.reshaped([rows, k])
        let out = tileKernelBF16([x2, weights.w], template: [("BM", tile), ("BN", tile), ("SG", plan.simdgroups)],
                                 grid: ((rows + tile - 1) / tile * 32 * plan.simdgroups, (n + tile - 1) / tile, 1),
                                 threadGroup: (32 * plan.simdgroups, 1, 1), outputShapes: [[rows, n]], outputDTypes: [.bfloat16])[0]
        return out.reshaped(Array(x.shape.dropLast()) + [n])
    }

    // MARK: - Self-test

    /// Runs every supported (kernel, dtype, format, epilogue, M class) on fixed random inputs against stock MLX and
    /// returns the relative RMS per class (non-finite → ∞). Classes this GPU cannot run are absent.
    public static func selfTest() -> [String: Float] {
        var results: [String: Float] = [:]
        func random(_ shape: [Int], _ index: Int, _ dtype: DType, scale: Float = 1) -> MLXArray {
            (MLXRandom.normal(shape, key: MLXRandom.key(UInt64(0x5eed + index))) * scale).asType(dtype)
        }
        // (M, N, K): both simdgroup counts, a partial row tile, a partial column tile.
        let tileShapes = [(9, 96, 256), (33, 200, 512), (100, 160, 1024), (256, 64, 384)]
        for (index, (m, n, k)) in tileShapes.enumerated() {
            let dtype = DType.bfloat16
            guard supports(m: m, n: n, k: k, dtype: dtype, format: .dense, epilogue: .none) else { continue }
            let x = random([m, k], 2 * index, dtype), w = random([n, k], 2 * index + 1, dtype, scale: 0.05)
            let reference = MLX.matmul(x, w.transposed())
            let name = "tile.bf16.dense.none.m\(m)"
            results[name] = matmul(x, .dense(w)).map { relativeRMS($0, reference) } ?? .infinity
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
    private struct TilePlan { let simdgroups: Int }

    private static func tilePlan(m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind) -> TilePlan? {
        // More simdgroups for fewer rows: 8 up to 64 rows, 4 above (microbench, M5 Max).
        let simdgroups = m <= 64 ? 8 : 4
        guard tensorOpsAvailable, dtype == .bfloat16, format == .dense, epilogue == .none, tileRows.contains(m), n > 0,
              k > 0, k % (simdgroups * 16) == 0 else { return nil }
        return TilePlan(simdgroups: simdgroups)
    }

    static let tileHeader = #"""
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace mpp::tensor_ops;
"""#

    // x [M, K] and w [N, K] row-major BF16; out [M, N]. Grid: x = M tiles (threadgroups sharing a weight tile are
    // dispatched together), y = N tiles. The host guarantees K % (SG * 16) == 0.
    static let tileSourceBF16 = #"""
    const int M = x_shape[0], K = x_shape[1], N = w_shape[0];
    const int tm = threadgroup_position_in_grid.x, tn = threadgroup_position_in_grid.y;
    const int sg = simdgroup_index_in_threadgroup;
    const int kc = K / SG;
    auto A = tensor<device bfloat, dextents<int32_t, 2>, tensor_inline>((device bfloat*)x + sg * kc, dextents<int32_t, 2>(kc, M), array<int, 2>{1, K});
    auto B = tensor<device bfloat, dextents<int32_t, 2>, tensor_inline>((device bfloat*)w + sg * kc, dextents<int32_t, 2>(kc, N), array<int, 2>{1, K});
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
        if (n < N && m < M) out[m * N + n] = static_cast<bfloat>(s);
    }
"""#

    private static let tileKernelBF16 = MLXFast.metalKernel(name: "smallm_tile1_bf16", inputNames: ["x", "w"], outputNames: ["out"],
                                                            source: tileSourceBF16, header: tileHeader)
}
