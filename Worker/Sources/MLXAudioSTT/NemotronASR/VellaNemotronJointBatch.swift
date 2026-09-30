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
        guard w.ndim == 2 else { return nil }
        let n = w.shape[0], k = w.shape[1]
        guard n % r == 0, k % (s * 8) == 0, r * VellaNemotronFusedMetal.maxRows <= s * 32 else { return nil }
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

    /// x (1, M, K) Float32, M <= 8 → (1, M, N) Float32; nil for any other input (the caller keeps its stock path).
    func callAsFunction(_ x: MLXArray) -> MLXArray? {
        let m = x.shape[1]
        guard x.dtype == .float32, x.ndim == 3, x.shape[0] == 1, m >= 1, m <= VellaNemotronFusedMetal.maxRows, x.shape[2] == k else { return nil }
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
/// Inexact (accumulation order); the argmax can differ only on near-ties. Quantized joints keep the per-frame path.
enum VellaNemotronJointBatch {
    static var enabled: Bool { VellaNemotronOptions.labLevers.contains("jointbatch-1") }
    /// K 640 = 2.5 x 256: one simdgroup walks all of K, 4 output columns per threadgroup.
    static func make(_ linear: Linear) -> VellaNemotronSmallLinear? {
        guard !(linear is QuantizedLinear) else { return nil }
        return VellaNemotronSmallLinear(weight: linear.weight, bias: linear.bias, r: 4, s: 1)
    }
}
