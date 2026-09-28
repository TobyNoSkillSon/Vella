import Foundation
import MLX

/// Small-M BF16 GEMM on Metal 4 tensor ops (the NAX matrix units of Apple GPU generation 17+, M5), y = x · wᵀ.
///
/// Why: at app segment lengths (M ≈ 16–150 rows) the encoder is weight-streaming GEMMs, and MLX 0.32.2's NAX GEMM
/// tiles 64 × 128 with 8 simdgroups, so a 66 × 1024 GEMM is 16 threadgroups for a 40-core GPU (~60–190 GB/s of
/// ~550). Here one threadgroup owns a 32 × 32 output tile and its SG simdgroups each run a `matmul2d` over 1/SG of K
/// (split-K inside the threadgroup), then the float partial sums are added in threadgroup memory and rounded to BF16
/// once. Same inputs and output dtype as `matmul`; the summation order differs (≤ 1 BF16 ulp per GEMM), so the
/// self-test bounds the encoder deviation instead of requiring bit-identity.
enum FastParakeetNAX {
    static let header = #"""
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace mpp::tensor_ops;
"""#

    // x [M, K] and w [N, K] row-major BF16; out [M, N]. Grid: x = M tiles (threadgroups sharing a weight tile are
    // dispatched together), y = N tiles. The host guarantees K % (SG * 16) == 0.
    static let source = #"""
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

    private static let kernel = MLXFast.metalKernel(name: "vella_nax_gemm", inputNames: ["x", "w"], outputNames: ["out"],
                                                    source: source, header: header)
    private static let tile = 32

    /// Tensor-op matmul needs Metal 4 and an Apple GPU of generation 17 or later (the same test MLX uses before its
    /// own NAX kernels: `applegpu_g<gen><class>`, gen ≥ 17, phones ≥ 18). Anything else is not eligible.
    static let available: Bool = {
        let architecture = GPU.deviceInfo().architecture
        guard architecture.hasPrefix("applegpu_g") else { return false }
        let tail = architecture.dropFirst("applegpu_g".count)
        guard let generation = Int(tail.prefix(while: \.isNumber)), let family = tail.last else { return false }
        return generation >= (family == "p" ? 18 : 17)
    }()

    /// Opt-in: `VELLA_PARAKEET_NAX=1` (part of the gate key). Off by default: on M5 Max it made the v2-mini run ~10 %
    /// faster, but its reordered sums flip near-tie tokens (Ultra BF16 v2-quick English +3 words vs the fused
    /// MLX-GEMM path, outside the 0.1-pt band) and other equally valid split-K orders already fail the token-exact
    /// self-test on clip-a or clip-b.
    static let enabledByEnvironment = ProcessInfo.processInfo.environment["VELLA_PARAKEET_NAX"] == "1"

    /// Row range: above ~256 rows MLX's own tiling fills the GPU and the split-K kernel no longer wins (M5 Max,
    /// 24-layer encoder stack: T 150 1.21×, T 375 0.99×); up to 8 rows MLX's gemv streams weights at ~390 GB/s
    /// (Ultra BF16 v2-mini, encoder calls with T ≤ 8: 5.5 ms MLX vs 6.4 ms here).
    static let minRows = 9
    static let maxRows = 256

    /// BF16 x [..., K] · w [N, K]ᵀ, or nil when the shape is outside the kernel's range (caller uses `matmul`).
    static func matmul(_ x: MLXArray, _ w: MLXArray) -> MLXArray? {
        let k = x.dim(-1), n = w.dim(0), rows = x.size / max(k, 1)
        // More simdgroups for fewer rows: 8 below 64 rows, 4 above (microbench, M5 Max).
        let simdgroups = rows <= 64 ? 8 : 4
        guard x.dtype == .bfloat16, w.dtype == .bfloat16, w.ndim == 2, w.dim(1) == k, rows >= minRows, rows <= maxRows,
              k % (simdgroups * 16) == 0 else { return nil }
        let x2 = x.reshaped([rows, k])
        let out = kernel([x2, w], template: [("BM", tile), ("BN", tile), ("SG", simdgroups)],
                         grid: ((rows + tile - 1) / tile * 32 * simdgroups, (n + tile - 1) / tile, 1),
                         threadGroup: (32 * simdgroups, 1, 1), outputShapes: [[rows, n]], outputDTypes: [.bfloat16])[0]
        return out.reshaped(Array(x.shape.dropLast()) + [n])
    }
}
