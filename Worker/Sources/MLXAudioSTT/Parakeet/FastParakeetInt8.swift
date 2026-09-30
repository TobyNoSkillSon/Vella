import Foundation
import MLX
import SmallMGEMM

/// Parakeet's switch for the native-int8 encoder of quantized checkpoints (8-bit affine, group 64, BF16 scales): the
/// encoder runs in BF16 activations like the BF16 checkpoint's, and its Linears use SmallMGEMM's native quantized tile
/// kernel (revision `SmallMGEMM.qtileRevision`), which feeds the stored 8-bit codes straight to the tensor unit (no
/// dequantization, one weight byte per element), the pointwise convolutions the BF16 tile kernel.
///
/// Why: the stock 8-bit path runs MLX's quantized matmul with Float32 activations, which at encoder row counts
/// (M ≈ 16–150) is `qmm_splitk` without tensor ops: 1.3–3× slower per GEMM than the native kernel and about twice the
/// energy of BF16 (lab/models/Parakeet/L3-int8.md). The kernel is inexact (float order, BF16 activations), so it is a
/// tolerant gate component, `int8_gemm`, like `nax_gemm`.
enum FastParakeetInt8 {
    static var available: Bool { SmallMGEMM.tensorOpsAvailable }

    /// Off until the lever is kept (lab/models/Parakeet/L3-RESULTS.md); flipping it needs a FastPathGate.version bump.
    static let enabledByDefault = false
    /// `VELLA_PARAKEET_INT8=1` / `=0` overrides the default (part of the gate key).
    static let enabled: Bool = {
        switch ProcessInfo.processInfo.environment["VELLA_PARAKEET_INT8"] {
        case "1": return true
        case "0": return false
        default: return enabledByDefault
        }
    }()

    /// The quantization the kernel takes: MLX affine 8-bit, group 64, scales and biases in the activation dtype.
    static func eligible(bits: Int, groupSize: Int, mode: QuantizationMode, scales: MLXArray?) -> Bool {
        bits == 8 && groupSize == 64 && mode == .affine && scales?.dtype == .bfloat16
    }

    /// x [..., K] · Wᵀ (+ bias) on the native kernel, or nil outside its range (the caller runs MLX's quantized matmul).
    static func matmul(_ x: MLXArray, weight: MLXArray, scales: MLXArray, biases: MLXArray, bits: Int, groupSize: Int, bias: MLXArray?) -> MLXArray? {
        guard x.dtype == .bfloat16 else { return nil }
        let weights = SmallMGEMM.Weights(w: weight, scales: scales, biases: biases, format: .affine(bits: bits, groupSize: groupSize))
        return SmallMGEMM.matmul(x, weights, epilogue: bias.map { .bias($0) } ?? .none, native: true)
    }

    /// The package's unit self-test for the classes this path uses (native tile BF16 affine 8-bit none/bias, and the BF16
    /// tile for the pointwise convolutions); run
    /// once per process inside the gate child. Empty = pass.
    static let libraryFailures: [String] = {
        let results = SmallMGEMM.selfTest(including: { ["qtile.bf16.affine8.none", "qtile.bf16.affine8.bias", "tile.bf16.dense.none"].contains($0) })
        for (name, value) in results.sorted(by: { $0.key < $1.key }) { FastPathGate.debug("smallm \(name) \(value)") }
        return SmallMGEMM.selfTestFailures(results)
    }()
}
