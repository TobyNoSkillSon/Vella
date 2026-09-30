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
/// Native quantized tile kernel (`qtile`, M 9…256 by default, opt-in with `native: true`): MLX affine g64 weights fed to
/// `matmul2d` as they are stored — 8-bit codes as `uint8_t`, 4-bit as `uint4b_format`, both native right operands of
/// the tensor unit next to a bfloat/half left operand on macOS 26 — so weights stream from memory at 1 or ½ byte per
/// element with no dequantization. Per K group of 64: one `matmul2d` of the raw codes into a fresh float tile, then
/// acc += scale[n, g] · P + bias[n, g] · Σₖ x[m, k] (MLX's qmv product form), split-K over the simdgroups by whole
/// groups, float reduction, one rounding. Inexact like the others (float order; x is read in its own dtype).
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
    /// Covers the tile and GEMV families (unchanged by the native kernel, so keys built on it stay as they were).
    public static let revision = tileRevision + " " + gemvRevision
    /// The native quantized tile kernel; callers that pass `native: true` put it in their gate keys.
    public static let qtileRevision = "qtile-1"

    /// Row ranges per kernel family.
    public static let tileRows = 9...256
    public static let gemvRows = 1...8
    /// Rows of the native quantized tile kernel (`native: true`).
    public static let qtileRows = 9...256

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
    /// `native`: also allow the native quantized tile kernel (revision `qtileRevision`) for `.affine(8|4, 64)`
    /// weights; it takes the call wherever its plan exists, else the standard families decide as without it.
    public static func supports(
        m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind, native: Bool = false
    ) -> Bool {
        if native, qtilePlan(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: epilogue) != nil { return true }
        return gemvRows.contains(m)
            ? gemvPlan(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: epilogue) != nil
            : tilePlan(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: epilogue) != nil
    }

    /// out[M, N] = epilogue(x[..., K] · Wᵀ) with the leading dimensions of x flattened into M; nil when `supports`
    /// is false for this call or an operand does not fit (bias [N], residual [M, N] or [..., N]; the up projection of
    /// `.siluGate` in the same format and shape as the gate).
    /// `native`: as in `supports`.
    public static func matmul(_ x: MLXArray, _ weights: Weights, epilogue: Epilogue = .none, native: Bool = false) -> MLXArray? {
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
                up.biases?.shape == weights.biases?.shape, fits(up, k: k, dtype: x.dtype)
            else { return nil }
        }
        let x2 = x.reshaped([rows, k])
        let out: MLXArray
        if native, up == nil, case .affine(let bits, let groupSize) = weights.format,
            let simdgroups = qtilePlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind)
        {
            out =
                (bits == 8 ? qtile8Kernel : qtile4Kernel)(
                    [x2, weights.w, weights.scales!, weights.biases!, bias ?? placeholder, residual ?? placeholder],
                    template: [
                        ("T", x.dtype), ("BITS", bits), ("GS", groupSize), ("BM", tile), ("BN", tile), ("SG", simdgroups),
                        ("HAS_BIAS", bias != nil), ("HAS_RES", residual != nil)
                    ],
                    grid: ((rows + tile - 1) / tile * 32 * simdgroups, (n + tile - 1) / tile, 1),
                    threadGroup: (32 * simdgroups, 1, 1), outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
        } else if gemvRows.contains(rows) {
            guard let plan = gemvPlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind) else { return nil }
            let flags: [(String, any KernelTemplateArg)] = [
                ("MR", rows), ("R", plan.rowsPerGroup), ("SGK", plan.simdgroups),
                ("GATE", up != nil), ("HAS_BIAS", bias != nil), ("HAS_RES", residual != nil)
            ]
            let geometry = (
                grid: ((n + plan.rowsPerGroup - 1) / plan.rowsPerGroup * 32 * plan.simdgroups, 1, 1),
                threadGroup: (32 * plan.simdgroups, 1, 1)
            )
            switch weights.format {
            case .dense:
                out =
                    gemvKernel(
                        [x2, weights.w, up?.w ?? weights.w, bias ?? placeholder, residual ?? placeholder],
                        template: [("T", x.dtype)] + flags, grid: geometry.grid, threadGroup: geometry.threadGroup,
                        outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
            case .affine(let bits, let groupSize):
                let u = up ?? weights
                out =
                    gemvAffineKernel(
                        [
                            x2, weights.w, weights.scales!, weights.biases!, u.w, u.scales!, u.biases!,
                            bias ?? placeholder, residual ?? placeholder
                        ],
                        template: [("T", x.dtype), ("BITS", bits), ("GS", groupSize)] + flags,
                        grid: geometry.grid, threadGroup: geometry.threadGroup,
                        outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
            case .mxfp:
                let u = up ?? weights
                out =
                    gemvMXFP4Kernel(
                        [x2, weights.w, weights.scales!, u.w, u.scales!, bias ?? placeholder, residual ?? placeholder],
                        template: [("T", x.dtype)] + flags, grid: geometry.grid, threadGroup: geometry.threadGroup,
                        outputShapes: [[rows, n]], outputDTypes: [x.dtype])[0]
            }
        } else {
            guard up == nil, let simdgroups = tilePlan(m: rows, n: n, k: k, dtype: x.dtype, format: weights.format, epilogue: epilogue.kind)
            else { return nil }
            out =
                tileKernel(
                    [x2, weights.w, bias ?? placeholder, residual ?? placeholder],
                    template: [
                        ("T", x.dtype), ("BM", tile), ("BN", tile), ("SG", simdgroups),
                        ("HAS_BIAS", bias != nil), ("HAS_RES", residual != nil)
                    ],
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
                let scales = weights.scales, let biases = weights.biases
            else { return false }
            let groups = [weights.w.dim(0), k / groupSize]
            return scales.shape == groups && biases.shape == groups && scales.dtype == dtype && biases.dtype == dtype
        case .mxfp(let bits):
            guard bits == 4, weights.w.dtype == .uint32, weights.w.dim(1) * 8 == k, let scales = weights.scales,
                weights.biases == nil
            else { return false }
            return scales.dtype == .uint8 && scales.shape == [weights.w.dim(0), k / 32]
        }
    }

    /// Stands in for an absent epilogue operand (never read); a host constant, so it adds no dispatch.
    private static let placeholder = MLXArray([Float(0)])

    // MARK: - Self-test

    /// Runs every supported (kernel, dtype, format, epilogue) class on fixed random inputs covering its M range and
    /// edge cases against stock MLX and returns the largest relative RMS per class (non-finite → ∞). Classes this GPU
    /// cannot run are absent. Class names: "<kernel>.<dtype>.<format>.<epilogue>", e.g. "tile.f16.dense.bias".
    /// `including` limits the run to the classes a caller uses. The default, `standardClasses`, is every tile and GEMV
    /// class (`revision`) and no native quantized tile class (`qtile.*`, `qtileRevision`): those run only when a
    /// caller of `native: true` selects them, so `selfTest()` tests exactly what it tested before they existed.
    /// `{ _ in true }` runs everything. An excluded class runs no kernel; the random inputs are still drawn in the same
    /// order, so an included class sees exactly the inputs (and gives the value) of a full run.
    public static func selfTest(including: (String) -> Bool = SmallMGEMM.standardClasses) -> [String: Float] {
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
                for (epilogueName, kind) in epilogues
                where supports(m: m, n: n, k: k, dtype: dtype, format: .dense, epilogue: kind)
                    && including("tile.\(dtypeName).dense.\(epilogueName)")
                {
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
        let gemvShapes = [
            (1, 200, 1032), (2, 96, 512), (3, 64, 264), (4, 136, 2048), (5, 72, 776), (6, 48, 128), (7, 520, 1024), (8, 257, 3072),
            (1, 136, 2048), (2, 70, 3072)
        ]
        for (dtypeName, dtype) in [("bf16", DType.bfloat16), ("f16", DType.float16)] {
            for (m, n, k) in gemvShapes {
                let x = random([m, k], dtype), w = random([n, k], dtype, scale: 0.05), u = random([n, k], dtype, scale: 0.05)
                let b = random([n], dtype), r = random([m, n], dtype)
                // Dense and, where K allows, MLX affine 8/4-bit group 64 (reference: MLX's quantized matmul).
                // (name, gate weights, up weights, stock x · gateᵀ, stock x · upᵀ)
                var formats: [(String, Weights, Weights, MLXArray, MLXArray)] = [
                    ("dense", .dense(w), .dense(u), MLX.matmul(x, w.transposed()), MLX.matmul(x, u.transposed()))
                ]
                if k % 64 == 0 {
                    for bits in [8, 4] {
                        let qw = MLX.quantized(w, groupSize: 64, bits: bits), qu = MLX.quantized(u, groupSize: 64, bits: bits)
                        let format = WeightFormat.affine(bits: bits, groupSize: 64)
                        let ww = Weights(w: qw.wq, scales: qw.scales, biases: qw.biases, format: format)
                        let uw = Weights(w: qu.wq, scales: qu.scales, biases: qu.biases, format: format)
                        formats.append(
                            (
                                "affine\(bits)", ww, uw,
                                MLX.quantizedMM(x, qw.wq, scales: qw.scales, biases: qw.biases, transpose: true, groupSize: 64, bits: bits),
                                MLX.quantizedMM(x, qu.wq, scales: qu.scales, biases: qu.biases, transpose: true, groupSize: 64, bits: bits)
                            ))
                    }
                    let mw = MLX.quantized(w, groupSize: 32, bits: 4, mode: .mxfp4), mu = MLX.quantized(u, groupSize: 32, bits: 4, mode: .mxfp4)
                    formats.append(
                        (
                            "mxfp4", Weights(w: mw.wq, scales: mw.scales, format: .mxfp(bits: 4)),
                            Weights(w: mu.wq, scales: mu.scales, format: .mxfp(bits: 4)),
                            MLX.quantizedMM(x, mw.wq, scales: mw.scales, biases: nil, transpose: true, groupSize: 32, bits: 4, mode: .mxfp4),
                            MLX.quantizedMM(x, mu.wq, scales: mu.scales, biases: nil, transpose: true, groupSize: 32, bits: 4, mode: .mxfp4)
                        ))
                }
                for (formatName, ww, uw, pw, pu) in formats {
                    let cases: [(String, Epilogue, () -> MLXArray)] = [
                        ("none", .none, { pw }), ("bias", .bias(b), { pw + b }), ("residual", .residual(r), { pw + r }),
                        ("biasResidual", .biasResidual(b, r), { pw + b + r }),
                        ("siluGate", .siluGate(up: uw), { silu(pw) * pu })
                    ]
                    for (epilogueName, epilogue, reference) in cases
                    where supports(m: m, n: n, k: k, dtype: dtype, format: ww.format, epilogue: epilogue.kind)
                        && including("gemv.\(dtypeName).\(formatName).\(epilogueName)")
                    {
                        let name = "gemv.\(dtypeName).\(formatName).\(epilogueName)"
                        record(name, matmul(x, ww, epilogue: epilogue).map { relativeRMS($0, reference()) } ?? .infinity)
                    }
                }
            }
        }
        // Native quantized tile, last so the classes above draw the same inputs as before it existed: MLX affine
        // 8/4-bit group 64 against MLX's quantized matmul; both simdgroup counts, partial row and column tiles, K
        // groups spread unevenly over the simdgroups (G % SG != 0).
        let qtileShapes = [(9, 96, 320), (33, 200, 1088), (100, 160, 1024), (256, 64, 448)]
        for (dtypeName, dtype) in [("bf16", DType.bfloat16), ("f16", DType.float16)] {
            for (m, n, k) in qtileShapes {
                let x = random([m, k], dtype), w = random([n, k], dtype, scale: 0.05)
                let b = random([n], dtype), r = random([m, n], dtype)
                for bits in [8, 4] {
                    let format = WeightFormat.affine(bits: bits, groupSize: 64)
                    let names = epilogues.map { "qtile.\(dtypeName).affine\(bits).\($0.0)" }
                    guard names.contains(where: including) else { continue }
                    let q = MLX.quantized(w, groupSize: 64, bits: bits)
                    let weights = Weights(w: q.wq, scales: q.scales, biases: q.biases, format: format)
                    let product = MLX.quantizedMM(x, q.wq, scales: q.scales, biases: q.biases, transpose: true, groupSize: 64, bits: bits)
                    for (epilogueName, kind) in epilogues
                    where supports(m: m, n: n, k: k, dtype: dtype, format: format, epilogue: kind, native: true)
                        && including("qtile.\(dtypeName).affine\(bits).\(epilogueName)")
                    {
                        let epilogue: Epilogue, reference: MLXArray
                        switch kind {
                        case .bias: epilogue = .bias(b); reference = product + b
                        case .residual: epilogue = .residual(r); reference = product + r
                        case .biasResidual: epilogue = .biasResidual(b, r); reference = product + b + r
                        default: epilogue = .none; reference = product
                        }
                        let name = "qtile.\(dtypeName).affine\(bits).\(epilogueName)"
                        record(name, matmul(x, weights, epilogue: epilogue, native: true).map { relativeRMS($0, reference) } ?? .infinity)
                    }
                }
            }
        }
        return results
    }

    /// The default self-test selection: the tile and GEMV families (`revision`), not the native quantized tile kernel.
    public static func standardClasses(_ className: String) -> Bool { !className.hasPrefix("qtile.") }

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
            tileRows.contains(m), n > 0, k % 16 == 0, k >= simdgroups * 16
        else { return nil }
        return simdgroups
    }

    /// Simdgroups per threadgroup for the native quantized tile kernel, or nil when it cannot run the call: MLX affine
    /// 8/4-bit group 64, scales and biases in x's dtype (checked by `fits`), tensor ops, rows `qtileRows`.
    private static func qtilePlan(m: Int, n: Int, k: Int, dtype: DType, format: WeightFormat, epilogue: EpilogueKind) -> Int? {
        guard tensorOpsAvailable, dtype == .bfloat16 || dtype == .float16, case .affine(let bits, let groupSize) = format,
            bits == 8 || bits == 4, groupSize == 64, epilogue != .siluGate, qtileRows.contains(m), n > 0, k % groupSize == 0,
            // M5 Max, 8-bit, vs MLX's quantized matmul (bf16 or f32 x): faster at M 12–256 for N ≤ 2048 (1024²: 7.1 vs
            // 9.4 µs at M 16, 20.4 vs 47.6 at M 256) but only up to M ≈ 100 for N 3072/4096 (1024→4096 at M 256: 66 vs
            // 51 µs); M ≤ 8 and M ≥ 512 lose everywhere (lab/models/Parakeet/l3-int8/bench-range.jsonl).
            n <= 2048 || m <= 100
        else { return nil }
        // Same split as the dense tile kernel: 8 simdgroups up to 64 rows, 4 above; K is split by whole groups, so a
        // simdgroup may get none (it then adds zeros).
        return m <= 64 ? 8 : 4
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
        case .mxfp(let bits):
            // MXFP4 only (MXFP8 not built). One row and K ≥ 2048 only: there it beat MLX's qmv (M5 Max: 1.15–1.17× per
            // FFN block); two or more rows or K 1024 were slower (0.47–0.92×).
            guard bits == 4, k % 32 == 0, k >= 2048, m == 1 else { return nil }
            return GemvPlan(rowsPerGroup: 2, simdgroups: 4)
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

    private static let tileKernel = MLXFast.metalKernel(
        name: "smallm_tile", inputNames: ["x", "w", "bias", "res"], outputNames: ["out"],
        source: tileSource, header: tileHeader)

    // MARK: - Native quantized tile kernel (qtile-1)

    // x [M, K] row-major T (bfloat or half); w = MLX affine-quantized [N, K] (packed uint32 [N, K · BITS / 32], read as
    // bytes: 8-bit codes in element order, 4-bit two per byte low nibble first — `uint8_t` / `uint4b_format` operands of
    // matmul2d as stored), scales and biases [N, K / GS] (T), element = scale · q + bias. out [M, N] = x · wᵀ (+ bias[n])
    // (+ res[m, n]). Grid as the dense tile kernel. Simdgroup sg owns the K groups [g0, g0 + gc) (spread as evenly as
    // possible); per group: P = matmul2d(x tile, raw codes) into a fresh float tile, xs = Σ of the lane's x row over the
    // group (lane l = tile row l), then per element acc += scale[n, g] · P + bias[n, g] · xs[m] (scale/bias of tile
    // column l and xs of tile row l are lane l's values, fetched by simd_shuffle). The partial tiles are added in
    // threadgroup memory in simdgroup order, the epilogue adds in float and rounds once. The host guarantees K % GS == 0.
    static let qtileSource = #"""
            const int M = x_shape[0], K = x_shape[1], N = scales_shape[0];
            const int G = K / GS;
            const int tm = threadgroup_position_in_grid.x, tn = threadgroup_position_in_grid.y;
            const int sg = simdgroup_index_in_threadgroup, lane = thread_index_in_simdgroup;
            const int base = G / SG, extra = G % SG;
            const int g0 = sg * base + min(sg, extra), gc = base + (sg < extra ? 1 : 0);
            constexpr auto desc = matmul2d_descriptor(BM, BN, static_cast<int>(dynamic_extent), false, true, false);
            matmul2d<desc, execution_simdgroup> op;
            const int xrow = min(tm * BM + lane, M - 1), wcol = min(tn * BN + lane, N - 1);
            device const T* xr = x + (size_t)xrow * K;
            device const T* sc = scales + (size_t)wcol * G;
            device const T* bi = biases + (size_t)wcol * G;
            device uchar* wb = (device uchar*)w;
            constexpr int CAP = BM * BN / 32;
            float acc[CAP];
            #pragma unroll
            for (int i = 0; i < CAP; ++i) acc[i] = 0.0f;
            for (int g = g0; g < g0 + gc; ++g) {
                const int k0 = g * GS;
                auto A = tensor<device T, dextents<int32_t, 2>, tensor_inline>((device T*)x + k0, dextents<int32_t, 2>(GS, M), array<int, 2>{1, K});
                auto B = tensor<device WT, dextents<int32_t, 2>, tensor_inline>(wb + k0 * BITS / 8, dextents<int32_t, 2>(GS, N), array<int, 2>{1, K});
                auto mA = A.slice(0, tm * BM);
                auto mB = B.slice(0, tn * BN);
                auto cT = op.template get_destination_cooperative_tensor<decltype(mA), decltype(mB), float>();
                #pragma unroll
                for (uint16_t i = 0; i < cT.get_capacity(); ++i) { if (cT.is_valid_element(i)) cT[i] = 0; }
                op.run(mA, mB, cT);
                float xs = 0.0f;
                #pragma unroll
                for (int j = 0; j < GS; j += 8) {
                    const vec<T, 4> a = *(device const vec<T, 4>*)(xr + k0 + j);
                    const vec<T, 4> b = *(device const vec<T, 4>*)(xr + k0 + j + 4);
                    xs += (float(a[0]) + float(a[1])) + (float(a[2]) + float(a[3])) + (float(b[0]) + float(b[1])) + (float(b[2]) + float(b[3]));
                }
                const float s = float(sc[g]), bb = float(bi[g]);
                #pragma unroll
                for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
                    if (!cT.is_valid_element(i)) continue;
                    auto idx = cT.get_multidimensional_index(i);
                    acc[i] += simd_shuffle(s, ushort(idx[0])) * cT[i] + simd_shuffle(bb, ushort(idx[0])) * simd_shuffle(xs, ushort(idx[1]));
                }
            }
            threadgroup float red[SG][BM * BN];
            {
                auto A = tensor<device T, dextents<int32_t, 2>, tensor_inline>((device T*)x, dextents<int32_t, 2>(GS, M), array<int, 2>{1, K});
                auto B = tensor<device WT, dextents<int32_t, 2>, tensor_inline>(wb, dextents<int32_t, 2>(GS, N), array<int, 2>{1, K});
                auto mA = A.slice(0, tm * BM);
                auto mB = B.slice(0, tn * BN);
                auto cT = op.template get_destination_cooperative_tensor<decltype(mA), decltype(mB), float>();
                #pragma unroll
                for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
                    if (!cT.is_valid_element(i)) continue;
                    auto idx = cT.get_multidimensional_index(i);
                    red[sg][idx[1] * BN + idx[0]] = acc[i];
                }
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

    private static let qtile8Kernel = MLXFast.metalKernel(
        name: "smallm_qtile8", inputNames: ["x", "w", "scales", "biases", "bias", "res"], outputNames: ["out"],
        source: qtileSource.replacingOccurrences(of: "WT", with: "uint8_t"), header: tileHeader)
    private static let qtile4Kernel = MLXFast.metalKernel(
        name: "smallm_qtile4", inputNames: ["x", "w", "scales", "biases", "bias", "res"], outputNames: ["out"],
        source: qtileSource.replacingOccurrences(of: "WT", with: "uint4b_format"), header: tileHeader)

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

    private static let gemvKernel = MLXFast.metalKernel(
        name: "smallm_gemv", inputNames: ["x", "w", "up", "bias", "res"], outputNames: ["out"],
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

    // x [MR, K] row-major T; w = MLX MXFP4 [N, K]: packed uint32 [N, K / 8] of E2M1 codes (low nibble first), scales
    // uint8 [N, K / 32] (E8M0: 2^(s − 127), s = 0 → 2^−127), element = code value · scale, no biases. Same threadgroup
    // layout and epilogue as the dense GEMV; each lane reads one group (16 bytes of codes) per row and step. The host
    // guarantees K % 32 == 0.
    static let gemvMXFP4Source = #"""
            const int K = x_shape[1], N = scales_shape[0];
            const int KW = K / 8, KG = K / 32;
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
            for (int k = (sg * 32 + lane) * 32; k < K; k += SGK * 32 * 32) {
                uint4 q[G][R];
                #pragma unroll
                for (int g = 0; g < G; ++g) {
                    device const uint32_t* wg = g == 0 ? w : upw;
                    #pragma unroll
                    for (int r = 0; r < R; ++r) q[g][r] = *(device const uint4*)(wg + (size_t)min(n0 + r, N - 1) * KW + k / 8);
                }
                float dot[G][MR][R];
                #pragma unroll
                for (int g = 0; g < G; ++g)
                    #pragma unroll
                    for (int m = 0; m < MR; ++m)
                        #pragma unroll
                        for (int r = 0; r < R; ++r) dot[g][m][r] = 0.0f;
                #pragma unroll
                for (int j = 0; j < 4; ++j) {
                    #pragma unroll
                    for (int m = 0; m < MR; ++m) {
                        float xv[8];
                        #pragma unroll
                        for (int i = 0; i < 8; ++i) xv[i] = static_cast<float>(x[m * K + k + j * 8 + i]);
                        #pragma unroll
                        for (int g = 0; g < G; ++g)
                            #pragma unroll
                            for (int r = 0; r < R; ++r) {
                                const uint word = q[g][r][j];
                                float d = 0.0f;
                                #pragma unroll
                                for (int i = 0; i < 8; ++i) {
                                    const uint c = (word >> (4 * i)) & 0xFu;
                                    const float v = static_cast<float>(as_type<half>(ushort((c & 7u) << 9))) * 16384.0f;
                                    d += xv[i] * ((c & 8u) ? -v : v);
                                }
                                dot[g][m][r] += d;
                            }
                    }
                }
                #pragma unroll
                for (int g = 0; g < G; ++g) {
                    device const uint8_t* sc = g == 0 ? scales : upscales;
                    #pragma unroll
                    for (int r = 0; r < R; ++r) {
                        const uint8_t e = sc[(size_t)min(n0 + r, N - 1) * KG + k / 32];
                        const float s = as_type<float>(e == 0 ? 0x400000u : (uint(e) << 23));
                        #pragma unroll
                        for (int m = 0; m < MR; ++m) acc[g][m][r] += s * dot[g][m][r];
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

    private static let gemvMXFP4Kernel = MLXFast.metalKernel(
        name: "smallm_gemv_mxfp4", inputNames: ["x", "w", "scales", "upw", "upscales", "bias", "res"],
        outputNames: ["out"], source: gemvMXFP4Source)
}
