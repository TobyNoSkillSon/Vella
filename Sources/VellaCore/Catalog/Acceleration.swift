import Foundation
import Metal

// MARK: What this Mac's GPU accelerates

/// This Mac's GPU as the precision advice needs it: its Apple GPU family and whether the GPU's matrix (tensor) units are
/// usable, read from Metal at run time, never from a chip-name table, so a future chip is judged by what it reports.
///
/// 16-bit weights run on every Apple GPU's matrix path. 8- and 4-bit weights have no integer matrix hardware before the
/// tensor units (Apple GPU generation 17, the M5 family): there MLX dequantizes them in the shader, which saves memory but
/// not time. With tensor units, a quantized matrix product reaches them through Vella's native integer kernel
/// (`int8_gemm`, `int4_gemm`) or MLX's own quantized tensor-unit kernel, which MLX takes only for 16-bit activations
/// (mlx backend/metal/quantized.cpp: `qmm_nax` when NAX is available and the input is not float32).
public struct GPUCapability: Equatable, Sendable {
    /// The highest Apple GPU family the device supports (7 = M1, 8 = M2, 9 = M3/M4, 10 = M5 in Apple's tables); nil
    /// when Metal reports none.
    public var appleFamily: Int?
    /// `MTLDevice.architecture.name`, e.g. `applegpu_g17s`; empty when unknown.
    public var architecture: String
    /// The OS version the tensor units need (macOS 26.2 or newer, as MLX and SmallMGEMM require).
    public var osMajor: Int, osMinor: Int
    public init(appleFamily: Int?, architecture: String, osMajor: Int, osMinor: Int) {
        self.appleFamily = appleFamily; self.architecture = architecture; self.osMajor = osMajor; self.osMinor = osMinor
    }

    /// The GPU's tensor units are usable: the same rule as MLX's `is_nax_available` and the worker's
    /// `SmallMGEMM.tensorOpsAvailable` (macOS ≥ 26.2 and `applegpu_g<gen><class>` with gen ≥ 17, phones ≥ 18).
    public var tensorOps: Bool {
        Self.tensorOpsAvailable(architecture: architecture, osMajor: osMajor, osMinor: osMinor)
    }
    public static func tensorOpsAvailable(architecture: String, osMajor: Int, osMinor: Int) -> Bool {
        guard osMajor > 26 || (osMajor == 26 && osMinor >= 2) else { return false }
        guard architecture.hasPrefix("applegpu_g") else { return false }
        let tail = architecture.dropFirst("applegpu_g".count)
        guard let generation = Int(tail.prefix(while: \.isNumber)), let kind = tail.last else { return false }
        return generation >= (kind == "p" ? 18 : 17)
    }

    /// This Mac, read once from the default Metal device.
    public static let current: GPUCapability = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let device = MTLCreateSystemDefaultDevice() else {
            return GPUCapability(appleFamily: nil, architecture: "", osMajor: os.majorVersion, osMinor: os.minorVersion)
        }
        // MTLGPUFamily.appleN has raw value 1000 + N; a newer family than the SDK names is still asked by number.
        let family = (7...12).reversed().first { n in MTLGPUFamily(rawValue: 1000 + n).map(device.supportsFamily) ?? false }
        return GPUCapability(appleFamily: family, architecture: device.architecture.name, osMajor: os.majorVersion, osMinor: os.minorVersion)
    }()
}

/// Components of a quantized cell's recipe that move its matrix products onto the tensor units: Vella's native integer
/// kernels (Parakeet) and 16-bit linears (Nemotron Fast, whose quantized layers then take bf16 activations).
public let tensorQuantizedComponents: Set<String> = ["int8_gemm", "int4_gemm", "bf16_linears"]

/// How a family's quantized layers feed MLX on the stock path: with 16-bit activations (MLX's quantized tensor-unit
/// kernel takes them) or with float32 activations (it does not; only `tensorQuantizedComponents` reach the units).
/// Every catalog family is listed (CatalogTests); an unknown family counts as float32, so it is never over-claimed.
public enum QuantizedActivations: Sendable { case half, float32 }
public let quantizedActivations: [String: QuantizedActivations] = [
    "parakeet-v3": .float32, "parakeet-v3-ultra": .float32, "nemotron-3.5-streaming-0.6b": .float32,
    "whisper-large-v3": .half, "whisper-large-v3-turbo": .half, "qwen3-asr-1.7b": .half, "qwen3-asr-0.6b": .half
]

/// Whether `tier` runs on the GPU's matrix hardware in `cell` (its recipe) on `gpu`: 16-bit always; 8- and 4-bit only
/// with tensor units and a path to them (16-bit activations on stock MLX, or a tensor component in the recipe).
public func runsOnMatrixHardware(_ family: ModelFamily, tier: ModelTier, cell: BenchmarkCell?, gpu: GPUCapability) -> Bool {
    if tier == .t16 { return true }
    guard gpu.tensorOps else { return false }
    if quantizedActivations[family.id] == .half { return true }
    return !tensorQuantizedComponents.isDisjoint(with: cell?.recipe.kernels ?? [])
}

// MARK: Recommended precision and software warnings

/// The Models table's advice for one family in one switch position on this Mac (Toby, 15 Oct: "the recommended option
/// would be always the smallest one that has the best accelerator ... if the quality is okay"): the recommended tier
/// (gold, with `recommendedHelp`) and the tiers that run without matrix hardware here (the orange triangle, with their
/// warning line).
public struct PrecisionAdvice: Equatable {
    public var recommended: ModelTier?
    public var recommendedHelp: String?
    /// Tier → its one-line warning; absent for tiers on the matrix hardware or measured faster than 16-bit here.
    public var software: [ModelTier: String]
    /// Tiers whose advice rests on a measurement on this exact Mac that overrides the derivation.
    public var measuredOverride: Set<ModelTier>
    public init(recommended: ModelTier? = nil, recommendedHelp: String? = nil, software: [ModelTier: String] = [:], measuredOverride: Set<ModelTier> = []) {
        self.recommended = recommended; self.recommendedHelp = recommendedHelp; self.software = software; self.measuredOverride = measuredOverride
    }
}

/// A smaller tier keeps the 16-bit quality: its tier gate passed, none of its cells failed the presence check, and its
/// own cell (if gated) passed. A failed cell stays offered with its loss in the tooltip; it is never recommended.
public func keepsQuality(_ benchmark: FamilyBenchmark?, tier: ModelTier, cell: BenchmarkCell?) -> Bool {
    if tier == .t16 { return true }
    guard let t = benchmark?.tiers[tier], let cell, !cell.isPending else { return false }
    let presenceFailed = t.cells.values.contains { $0.gate?.presence?.offered == false }
    return t.gate.status == .pass && !presenceFailed && (cell.gate.map { $0.status == .pass } ?? true)
}

/// The advice for `family` in switch position `mode`. `tiers` are the offered tiers of that position; `measuredHere`
/// says this Mac is the measured configuration, where a cell measured faster than the 16-bit cell of the same position
/// counts as accelerated and carries no warning whatever the derivation says.
public func precisionAdvice(
    _ family: ModelFamily, _ benchmark: FamilyBenchmark?, mode: OptimizedMode, tiers: [ModelTier], gpu: GPUCapability, measuredHere: Bool
) -> PrecisionAdvice {
    guard let benchmark, !benchmark.tiers.isEmpty, tiers.contains(.t16) else { return PrecisionAdvice() }
    let base = benchmarkCell(benchmark, ModelSelection(tier: .t16, mode: mode))
    let baseName = tierDTypeLabel(family, .t16)
    var advice = PrecisionAdvice()
    var native: Set<ModelTier> = [.t16]
    var quality: Set<ModelTier> = [.t16]
    for tier in tiers where tier != .t16 {
        let cell = benchmarkCell(benchmark, ModelSelection(tier: tier, mode: mode))
        let derived = runsOnMatrixHardware(family, tier: tier, cell: cell, gpu: gpu)
        var faster: Bool?
        if measuredHere, let x = cell.flatMap({ $0.isPending ? nil : $0.result.speed_x }), let y = base.flatMap({ $0.isPending ? nil : $0.result.speed_x }) {
            faster = x > y
        }
        if keepsQuality(benchmark, tier: tier, cell: cell) { quality.insert(tier) }
        if derived || faster == true {
            native.insert(tier)
            if !derived { advice.measuredOverride.insert(tier) }
        } else {
            let dtype = tierDTypeLabel(family, tier)
            let lead =
                gpu.tensorOps
                ? (mode == .exact ? "Exact runs \(dtype) without the matrix hardware on this Mac" : "Runs \(dtype) without the matrix hardware on this Mac")
                : "No hardware support for \(dtype) on this Mac"
            let speed = faster == false ? "measured slower than \(baseName) here" : "may be slower than \(baseName)"
            advice.software[tier] = "\(lead): saves memory, \(speed)"
        }
    }
    // Smallest first (4, 8, 16): the first that keeps quality on the matrix hardware.
    let pick = tiers.sorted { $0.bits < $1.bits }.first { quality.contains($0) && native.contains($0) } ?? .t16
    advice.recommended = pick
    let name = tierDTypeLabel(family, pick)
    if pick != .t16 {
        let how = advice.measuredOverride.contains(pick) ? "measured faster than \(baseName) on this Mac" : "runs on this Mac's matrix hardware"
        advice.recommendedHelp = "Recommended for this Mac: \(name) keeps \(baseName) accuracy, uses less memory and \(how)"
    } else {
        let smaller = tiers.filter { $0 != .t16 }.sorted { $0.bits > $1.bits }
        let lossy = smaller.filter { !quality.contains($0) }.map { tierDTypeLabel(family, $0) }
        let soft = smaller.filter { quality.contains($0) && !native.contains($0) }.map { tierDTypeLabel(family, $0) }
        func list(_ names: [String]) -> String { names.joined(separator: " and ") }
        // One clause per reason, in tier order (int8 before int4).
        var why: [String] = []
        let lossClause = lossy.isEmpty ? nil : "\(list(lossy)) \(lossy.count == 1 ? "loses" : "lose") accuracy against \(baseName)"
        let softClause =
            soft.isEmpty
            ? nil
            : gpu.tensorOps
                ? "\(list(soft)) \(soft.count == 1 ? "runs" : "run") without the matrix hardware here"
                : "\(list(soft)) \(soft.count == 1 ? "has" : "have") no hardware support here"
        let lossFirst = smaller.first.map { !quality.contains($0) } ?? true
        why = (lossFirst ? [lossClause, softClause] : [softClause, lossClause]).compactMap { $0 }
        advice.recommendedHelp = "Recommended for this Mac" + (why.isEmpty ? "" : ": " + why.joined(separator: "; "))
    }
    return advice
}
