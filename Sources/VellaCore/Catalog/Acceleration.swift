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

/// Components of a quantized cell's recipe that put its matrix products on the tensor units: Vella's native integer
/// kernels (Parakeet Fast), which feed the stored codes to the tensor unit. (Nemotron's `bf16_linears` is not one: it
/// prepares dense BF16 linears; its quantized linears stay `quantizedMM` with float32 activations,
/// VellaNemotronFused.swift.)
public let tensorQuantizedComponents: Set<String> = ["int8_gemm", "int4_gemm"]

/// How a family's quantized layers feed MLX: with 16-bit activations (MLX's quantized tensor-unit kernel takes them,
/// on the optimized and the stock path alike) or with float32 activations (it does not; only
/// `tensorQuantizedComponents` reach the units). Whisper's decoder runs fp16 and Qwen's text decoder bf16 (its audio
/// tower, f32 on the optimized path, is never quantized). Every catalog family is listed (AccelerationTests); an unknown
/// family counts as float32, so it is never over-claimed.
public enum QuantizedActivations: Sendable { case half, float32 }
public let quantizedActivations: [String: QuantizedActivations] = [
    "parakeet-v3": .float32, "parakeet-v3-ultra": .float32, "nemotron-3.5-streaming-0.6b": .float32,
    "whisper-large-v3": .half, "whisper-large-v3-turbo": .half, "qwen3-asr-1.7b": .half, "qwen3-asr-0.6b": .half
]

/// What this Mac's qualification decided for a precision's files: the worker's report for a loaded model, else the
/// persisted self-test verdict. Nil before any verdict exists (the derivation decides).
public enum Qualification: Equatable, Sendable {
    /// The whole model runs stock MLX (self-test failed, family unsupported, or a runtime fallback).
    case stock
    /// The optimized path runs, without these components (each failed its own self-test).
    case optimized(disabled: Set<String>)
}

/// Whether `tier` runs on the GPU's matrix hardware in `cell` (its recipe) on `gpu`: 16-bit always; 8- and 4-bit only
/// with tensor units and a path to them (16-bit activations, which MLX's own quantized kernel takes on any path, or a
/// tensor component in the recipe that this Mac's qualification left on).
public func runsOnMatrixHardware(
    _ family: ModelFamily, tier: ModelTier, cell: BenchmarkCell?, gpu: GPUCapability, qualification: Qualification? = nil
) -> Bool {
    if tier == .t16 { return true }
    guard gpu.tensorOps else { return false }
    if quantizedActivations[family.id] == .half { return true }
    var kernels = Set(cell?.recipe.kernels ?? [])
    switch qualification {
    case .stock: kernels = []
    case .optimized(let disabled): kernels.subtract(disabled)
    case nil: break
    }
    return !tensorQuantizedComponents.isDisjoint(with: kernels)
}

// MARK: Recommended precision and software warnings

/// The Models table's advice for one family in one switch position on this Mac (Toby, 15 Oct: "the recommended option
/// would be always the smallest one that has the best accelerator ... if the quality is okay"). Two separate facts per
/// precision: `hardware` (matrix or software, truthful in the API and the only basis for recommendation) and `warnings`
/// (the orange triangle, a speed warning; left off on the measured Mac where that precision measured faster than 16-bit,
/// where "may be slower" would be false).
public struct PrecisionAdvice: Equatable {
    public var recommended: ModelTier?
    public var recommendedHelp: String?
    /// Tier → runs on the GPU's matrix hardware here (true) or in software (false).
    public var hardware: [ModelTier: Bool]
    /// Tier → its triangle line.
    public var warnings: [ModelTier: String]
    /// Tier → why it runs in software here (the API's `hardware_note`), for every software tier.
    public var softwareNotes: [ModelTier: String]
    public init(
        recommended: ModelTier? = nil, recommendedHelp: String? = nil, hardware: [ModelTier: Bool] = [:], warnings: [ModelTier: String] = [:],
        softwareNotes: [ModelTier: String] = [:]
    ) {
        self.recommended = recommended; self.recommendedHelp = recommendedHelp; self.hardware = hardware; self.warnings = warnings
        self.softwareNotes = softwareNotes
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
/// says this Mac is the measured configuration (a precision measured faster than the 16-bit cell of the same position
/// carries no triangle there); `qualification` gives this Mac's verdict per tier (nil: none yet).
public func precisionAdvice(
    _ family: ModelFamily, _ benchmark: FamilyBenchmark?, mode: OptimizedMode, tiers: [ModelTier], gpu: GPUCapability, measuredHere: Bool,
    qualification: (ModelTier) -> Qualification? = { _ in nil }
) -> PrecisionAdvice {
    guard let benchmark, !benchmark.tiers.isEmpty, tiers.contains(.t16) else { return PrecisionAdvice() }
    let base = benchmarkCell(benchmark, ModelSelection(tier: .t16, mode: mode))
    let baseName = tierDTypeLabel(family, .t16)
    var advice = PrecisionAdvice()
    advice.hardware[.t16] = true
    var quality: Set<ModelTier> = [.t16]
    for tier in tiers where tier != .t16 {
        let cell = benchmarkCell(benchmark, ModelSelection(tier: tier, mode: mode))
        let matrix = runsOnMatrixHardware(family, tier: tier, cell: cell, gpu: gpu, qualification: qualification(tier))
        advice.hardware[tier] = matrix
        if keepsQuality(benchmark, tier: tier, cell: cell) { quality.insert(tier) }
        guard !matrix else { continue }
        // The measured figures are those of the recipe as derived; once this Mac's qualification changed what runs,
        // they no longer describe it.
        var ranAsMeasured = true
        switch qualification(tier) {
        case .stock: ranAsMeasured = false
        case .optimized(let disabled): ranAsMeasured = disabled.isDisjoint(with: cell?.recipe.kernels ?? [])
        case nil: break
        }
        var faster: Bool?
        if measuredHere, ranAsMeasured, let x = cell.flatMap({ $0.isPending ? nil : $0.result.speed_x }),
            let y = base.flatMap({ $0.isPending ? nil : $0.result.speed_x })
        {
            faster = x > y
        }
        let dtype = tierDTypeLabel(family, tier)
        let lead =
            gpu.tensorOps
            ? (mode == .exact ? "Exact runs \(dtype) without the matrix hardware on this Mac" : "Runs \(dtype) without the matrix hardware on this Mac")
            : "No hardware support for \(dtype) on this Mac"
        advice.softwareNotes[tier] = lead
        // The triangle is a speed warning: false where this exact Mac measured the precision faster than 16-bit.
        if faster != true {
            advice.warnings[tier] = "\(lead): saves memory, " + (faster == false ? "measured slower than \(baseName) here" : "may be slower than \(baseName)")
        }
    }
    // Smallest first (4, 8, 16): the first that keeps quality on the matrix hardware.
    let pick = tiers.sorted { $0.bits < $1.bits }.first { quality.contains($0) && advice.hardware[$0] == true } ?? .t16
    advice.recommended = pick
    let name = tierDTypeLabel(family, pick)
    if pick != .t16 {
        advice.recommendedHelp = "Recommended for this Mac: \(name) keeps \(baseName) accuracy, uses less memory and runs on this Mac's matrix hardware"
    } else {
        // One clause per smaller precision, int8 first: the measure that failed the quality gate, else no hardware.
        let clauses: [String] = tiers.filter { $0 != .t16 }.sorted { $0.bits > $1.bits }.map { tier in
            let dtype = tierDTypeLabel(family, tier)
            if !quality.contains(tier) {
                let segment = ModelSelection(tier: tier, mode: mode).segmentKey
                let loss = cellLoss(benchmark, tier: tier, segment: segment).first ?? benchmark.tiers[tier]?.gate.loss.first
                return "\(dtype) fails the quality gate" + (loss.map { " (\($0))" } ?? "")
            }
            return gpu.tensorOps ? "\(dtype) runs without the matrix hardware here" : "\(dtype) has no hardware support here"
        }
        advice.recommendedHelp = "Recommended for this Mac" + (clauses.isEmpty ? "" : ": " + clauses.joined(separator: "; "))
    }
    return advice
}

// MARK: This Mac's qualification verdicts

/// One persisted self-test verdict (the worker's FastPath/*.json, written by FastPathGate.persist): what it decided for a
/// model folder, on which worker version, GPU and OS build.
public struct QualificationVerdict: Equatable, Sendable {
    public var status: String
    /// The model folder's name (a derived precision's own folder); nil for verdicts written before it was recorded.
    public var model: String?
    /// Tolerant components left off (`disabled.<component>` keys).
    public var disabled: Set<String>
    public var workerVersion: String?
    public var gpuArchitecture: String?
    public var osBuild: String?
    public init(
        status: String, model: String?, disabled: Set<String> = [], workerVersion: String? = nil, gpuArchitecture: String? = nil, osBuild: String? = nil
    ) {
        self.status = status; self.model = model; self.disabled = disabled; self.workerVersion = workerVersion
        self.gpuArchitecture = gpuArchitecture; self.osBuild = osBuild
    }

    /// Every verdict file in `directory` (unreadable ones skipped).
    public static func read(_ directory: URL) -> [QualificationVerdict] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
                let status = o["status"]
            else { return nil }
            let disabled = Set(o.keys.filter { $0.hasPrefix("disabled.") }.map { String($0.dropFirst("disabled.".count)) })
            return QualificationVerdict(
                status: status, model: o["model"], disabled: disabled, workerVersion: o["workerVersion"], gpuArchitecture: o["gpuArchitecture"],
                osBuild: o["osBuild"])
        }
    }
}

/// This Mac's qualification of a precision's files from the persisted verdicts: those for one of `folders`, written by
/// this worker version (when known) on this GPU and OS build (when recorded). A stock verdict wins (the files exist for
/// Exact and Fast alike and the files do not record which; claiming less acceleration is the safe side); else the
/// optimized verdicts' disabled components together. Nil without a matching verdict.
public func qualification(
    folders: Set<String>, verdicts: [QualificationVerdict], workerVersion: String?, gpu: GPUCapability, osBuild: String?
) -> Qualification? {
    let mine = verdicts.filter { v in
        guard let model = v.model, folders.contains(model) else { return false }
        if let workerVersion, let version = v.workerVersion, version != workerVersion { return false }
        if let arch = v.gpuArchitecture, !gpu.architecture.isEmpty, arch != gpu.architecture { return false }
        if let build = v.osBuild, let osBuild, build != osBuild { return false }
        return v.status == "fast" || v.status == "stock"
    }
    guard !mine.isEmpty else { return nil }
    if mine.contains(where: { $0.status == "stock" }) { return .stock }
    return .optimized(disabled: mine.reduce(into: Set<String>()) { $0.formUnion($1.disabled) })
}
