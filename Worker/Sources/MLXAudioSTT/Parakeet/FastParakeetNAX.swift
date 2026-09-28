import Foundation
import MLX
import SmallMGEMM

/// Parakeet's switches for the small-M BF16 GEMM of the shared SmallMGEMM package (its tile kernel, revision
/// `SmallMGEMM.tileRevision`; the kernel was this file's until 28 Sep and moved there unchanged).
///
/// Why: at app segment lengths (M ≈ 16–150 rows) the encoder is weight-streaming GEMMs, and MLX 0.32.2's NAX GEMM
/// tiles 64 × 128 with 8 simdgroups, so a 66 × 1024 GEMM is 16 threadgroups for a 40-core GPU. The package's split-K
/// tile kernel reorders the sums (≤ 1 BF16 ulp per GEMM), so the self-test bounds the encoder deviation instead of
/// requiring bit-identity.
enum FastParakeetNAX {
    /// Tensor-op matmul needs Metal 4 and an Apple GPU of generation 17 or later (SmallMGEMM's test).
    static var available: Bool { SmallMGEMM.tensorOpsAvailable }

    /// The one default switch. On since 28 Sep: the kernel passed the full-v2 gate of lab/notes/GATE-REVISION.md for
    /// Ultra and v3 BF16 against the fused MLX-GEMM path and stock (lab/bench/GATE-RESULTS.md); on M5 Max it made the
    /// v2-mini run ~10 % faster. Its reordered sums flip near-tie tokens, so it is the gate's one tolerant Parakeet
    /// component. Flipping it needs a FastPathGate.version bump.
    static let enabledByDefault = true
    /// `VELLA_PARAKEET_NAX=1` / `=0` overrides the default (part of the gate key). An eligible checkpoint then
    /// self-tests the kernel within a tolerance (ParakeetModel.naxMaxDeviation, ≤ 1 word edit over the clips); a
    /// failure disables only the kernel and keeps the fused path.
    static let enabled: Bool = {
        switch ProcessInfo.processInfo.environment["VELLA_PARAKEET_NAX"] {
        case "1": return true
        case "0": return false
        default: return enabledByDefault
        }
    }()

    /// BF16 x [..., K] · w [N, K]ᵀ, or nil when the shape is outside the kernel's range (caller uses `matmul`).
    /// Row range 9…256 (SmallMGEMM.tileRows): above ~256 rows MLX's own tiling fills the GPU and the split-K kernel no
    /// longer wins (M5 Max, 24-layer encoder stack: T 150 1.21×, T 375 0.99×); up to 8 rows MLX's gemv streams weights
    /// at ~390 GB/s (Ultra BF16 v2-mini, encoder calls with T ≤ 8: 5.5 ms MLX vs 6.4 ms here).
    static func matmul(_ x: MLXArray, _ w: MLXArray) -> MLXArray? {
        // Tile rows only: the package's GEMV family (M ≤ 8) is not part of Parakeet's qualified path.
        guard x.dtype == .bfloat16, SmallMGEMM.tileRows.contains(x.size / max(x.dim(-1), 1)) else { return nil }
        return SmallMGEMM.matmul(x, .dense(w))
    }

    /// The package's own unit self-test for the classes Parakeet uses (tile, BF16, dense, no epilogue); run once
    /// per process inside the gate child. Empty = pass.
    static let libraryFailures: [String] = {
        SmallMGEMM.selfTestFailures(SmallMGEMM.selfTest().filter { $0.key.hasPrefix("tile.bf16.dense.none") })
    }()
}
