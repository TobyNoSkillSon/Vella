import Foundation
import MLX
import MLXNN

/// A dense Linear with an optional bias as one small-M pass over a lossless BF16 copy of its weight: M <= 8 rows of
/// Float32 activations, Float32 accumulation (`VellaNemotronFusedMetal.linear`), the bias added in Float32 afterwards.
/// Not bit-identical to MLX's Float32 addmm (another accumulation order over the same weight values).
final class VellaNemotronSmallLinear {
    let weight: MLXArray
    let bias: MLXArray?
    let n: Int, k: Int, r: Int, s: Int

    /// `weight` Float32 or BF16 (N, K); nil when a BF16 copy would not be exact or the shape does not fit the kernel
    /// (K a multiple of 8 per simdgroup slice, N a multiple of R, M·R reduction threads within the threadgroup).
    init?(weight w: MLXArray, bias: MLXArray?, r: Int, s: Int) {
        guard Self.fits(weightShape: w.shape, dtype: w.dtype, r: r, s: s) else { return nil }
        let n = w.shape[0], k = w.shape[1]
        switch w.dtype {
        case .bfloat16: weight = w
        case .float32:
            let b = w.asType(.bfloat16)
            guard MLX.all(b.asType(.float32) .== w).item(Bool.self) else { return nil }   // only a lossless copy
            eval(b); weight = b
        default: return nil
        }
        self.bias = bias.map { $0.asType(.float32) }
        self.n = n; self.k = k; self.r = r; self.s = s
    }

    /// A weight the kernel can take: (N, K) Float32 or BF16, N a multiple of R, K of S · 8, M·R reduction threads
    /// within the threadgroup. (A Float32 weight must also have a lossless BF16 copy, checked by `init`.)
    static func fits(weightShape shape: [Int], dtype: DType, r: Int, s: Int) -> Bool {
        guard shape.count == 2, dtype == .bfloat16 || dtype == .float32 else { return false }
        return shape[0] % r == 0 && shape[1] % (s * 8) == 0 && r * VellaNemotronFusedMetal.maxRows <= s * 32
    }

    /// An input `callAsFunction` takes: (1, M, K) Float32 with 1 <= M <= 8.
    static func accepts(inputShape shape: [Int], dtype: DType, k: Int) -> Bool {
        dtype == .float32 && shape.count == 3 && shape[0] == 1 && (1...VellaNemotronFusedMetal.maxRows).contains(shape[1]) && shape[2] == k
    }

    /// x (1, M, K) Float32, M <= 8 → (1, M, N) Float32; nil for any other input (the caller keeps its stock path).
    func callAsFunction(_ x: MLXArray) -> MLXArray? {
        guard Self.accepts(inputShape: x.shape, dtype: x.dtype, k: k) else { return nil }
        let m = x.shape[1]
        var y = Self.kernel(
            [x, weight], template: [("N", n), ("KD", k), ("M", m), ("R", r), ("S", s), ("SILU", false)],
            grid: (n / r * s * 32, 1, 1), threadGroup: (s * 32, 1, 1),
            outputShapes: [[1, m, n]], outputDTypes: [.float32])[0]
        if let bias { y = y + bias }
        return y
    }

    private static let kernel = MLXFast.metalKernel(
        name: "vella_nemo_small_linear_bf16", inputNames: ["x", "W"], outputNames: ["y"],
        source: VellaNemotronFusedMetal.linear, header: VellaNemotronFusedMetal.header)
}

/// L3 lever (`VELLA_NEMO_JOINTBATCH=1`, optimized sessions, dense checkpoints): the RNNT joint's output projection
/// (`joint_net`, 13088 x 640) for every remaining frame of a chunk in one small-M pass over a BF16 copy of the weight
/// (read once for up to 8 rows) instead of one Float32 GEMV per frame that re-reads the 33 MB Float32 weight each time.
/// Inexact (accumulation order); the argmax can differ only on near-ties, so it is off under Optimized · Exact
/// (`VellaNemotronOptions`). Quantized joints keep the per-frame path.
enum VellaNemotronJointBatch {
    /// Dense Linears only: a quantized joint keeps the per-frame path.
    static func admits(_ linear: Linear) -> Bool { !(linear is QuantizedLinear) }
    static var enabled: Bool { VellaNemotronOptions.labLevers.contains("jointbatch-1") }
    /// K 640 = 2.5 x 256: one simdgroup walks all of K, 4 output columns per threadgroup.
    static func make(_ linear: Linear) -> VellaNemotronSmallLinear? {
        guard admits(linear) else { return nil }
        return VellaNemotronSmallLinear(weight: linear.weight, bias: linear.bias, r: 4, s: 1)
    }
}
