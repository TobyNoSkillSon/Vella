import Foundation
import MLX
import SmallMGEMM

/// Parakeet's switches for the native-integer encoder of quantized checkpoints (affine group 64, BF16 scales; 8-bit
/// component `int8_gemm`, 4-bit component `int4_gemm`, each with its own switch and verdict): the
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

    /// The gate component for a checkpoint's bit width, or nil when the kernel does not take it or its switch is off:
    /// MLX affine 8- or 4-bit, group 64, scales and biases in BF16 (the activation dtype).
    static func component(bits: Int, groupSize: Int, mode: QuantizationMode, scales: MLXArray?, levers: KeptLevers) -> String? {
        guard groupSize == 64, mode == .affine, scales?.dtype == .bfloat16 else { return nil }
        if bits == 8 && levers.contains("VELLA_PARAKEET_INT8") { return "int8_gemm" }
        if bits == 4 && levers.contains("VELLA_PARAKEET_INT4") { return "int4_gemm" }
        return nil
    }

    /// x [..., K] · Wᵀ (+ bias) on the native kernel, or nil outside its range (the caller runs MLX's quantized matmul).
    /// Rows `SmallMGEMM.qtileRows` only: with `native: true` the package would otherwise route 1…2-row calls to its
    /// affine GEMV family, which this component neither self-tests nor keys. Within those rows a call the native kernel
    /// declines (N > 2048 above 100 rows) finds no other quantized family there and returns nil too.
    static func matmul(_ x: MLXArray, weight: MLXArray, scales: MLXArray, biases: MLXArray, bits: Int, groupSize: Int, bias: MLXArray?) -> MLXArray? {
        guard x.dtype == .bfloat16, SmallMGEMM.qtileRows.contains(x.size / max(x.dim(-1), 1)) else { return nil }
        let weights = SmallMGEMM.Weights(w: weight, scales: scales, biases: biases, format: .affine(bits: bits, groupSize: groupSize))
        return SmallMGEMM.matmul(x, weights, epilogue: bias.map { .bias($0) } ?? .none, native: true)
    }

    /// The package self-test classes a component dispatches: the native tile for its own bit width (no epilogue, bias)
    /// and the BF16 tile for the pointwise convolutions. The other bit width is not run, so it cannot disable this one.
    static func libraryClasses(component: String) -> [String] {
        let bits = component == "int4_gemm" ? 4 : 8
        return ["qtile.bf16.affine\(bits).none", "qtile.bf16.affine\(bits).bias", "tile.bf16.dense.none"]
    }

    /// The failing classes among `component`'s own (empty = pass); results of any other class are ignored.
    static func libraryFailures(component: String, results: [String: Float]) -> [String] {
        let classes = Set(libraryClasses(component: component))
        return SmallMGEMM.selfTestFailures(results.filter { classes.contains($0.key) })
    }

    /// The package's unit self-test for the active component's classes only; run at most once per process and bit
    /// width, inside the gate child. Empty = pass.
    static func libraryFailures(component: String) -> [String] {
        component == "int4_gemm" ? int4LibraryFailures : int8LibraryFailures
    }
    private static let int8LibraryFailures = runLibraryTest(component: "int8_gemm")
    private static let int4LibraryFailures = runLibraryTest(component: "int4_gemm")
    private static func runLibraryTest(component: String) -> [String] {
        let classes = Set(libraryClasses(component: component))
        let results = SmallMGEMM.selfTest(including: { classes.contains($0) })
        for (name, value) in results.sorted(by: { $0.key < $1.key }) { FastPathGate.debug("smallm \(name) \(value)") }
        return libraryFailures(component: component, results: results)
    }
}
