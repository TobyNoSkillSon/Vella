import Foundation
import Darwin

/// Why a model is loaded. Manual: the user clicked Load/Reload, or it is in the launch set. On demand: a dictation
/// needed it. Each class has its own Keep Hot idle window; memory eviction takes on-demand models before manual ones.
public enum ResidencyClass: String, Codable {
    case manual
    case onDemand = "on_demand"
}

/// Keep Hot idle windows, in minutes. 0 means Always (never unloaded for idleness).
public enum KeepHot {
    public static let choices = [5, 15, 30, 60, 0]
    public static let manualDefault = 0
    public static let onDemandDefault = 15
    public static func title(_ minutes: Int) -> String { minutes > 0 ? "\(minutes) min idle" : "Always" }
}

/// A model the runtime can load: one precision of one catalog family, at a local path.
public struct ModelRef: Codable, Hashable {
    /// Catalog family id (models.json v2), else the installed-registry id.
    public var id: String
    /// Exact precision label ("4b", "8b", "BF16", "FP16", "FP32"); empty when unknown.
    public var precision: String
    public var path: String
    public var mode: RecognitionMode
    public var name: String?
    /// Bytes of the downloaded weights at this precision.
    public var diskBytes: Int64?
    /// Measured process memory at this precision (benchmarks.json `memory_mb`).
    public var memoryMB: Double?
    /// Every precision this family offers, any order; used to suggest a smaller one in a refusal.
    public var precisionOptions: [String]?
    /// What the worker runs: tier × Standard/Optimized × Exact/Fast (Selection.swift). Nil (an older launch set, a
    /// model outside the catalog): Optimized · Fast, the behaviour before the selection existed.
    public var selection: ModelSelection?
    public init(id: String, precision: String = "", path: String, mode: RecognitionMode = .dictation, name: String? = nil,
                diskBytes: Int64? = nil, memoryMB: Double? = nil, precisionOptions: [String]? = nil, selection: ModelSelection? = nil) {
        self.id = id; self.precision = precision; self.path = path; self.mode = mode; self.name = name
        self.diskBytes = diskBytes; self.memoryMB = memoryMB; self.precisionOptions = precisionOptions; self.selection = selection
    }
    /// The worker's `VELLA_RECIPE`: `standard`, `optimized_exact` or `optimized_fast`.
    public var recipe: String { workerRecipe(selection) }
    public var displayName: String { name ?? id }
    /// "Parakeet v3 at 4b", or the name alone when the precision is unknown.
    public var displayWithPrecision: String { precision.isEmpty ? displayName : "\(displayName) at \(precisionInProse(precision))" }
}

/// The recipe a worker runs for a selection (`VELLA_RECIPE`): Standard = stock MLX (the VELLA_FORCE_STOCK path);
/// Optimized · Exact = only the components whose output equals stock's; Optimized · Fast = those plus the inexact
/// components that passed the gate. Nil selection = Optimized · Fast (the behaviour before selections existed).
public func workerRecipe(_ selection: ModelSelection?) -> String { (selection?.segmentKey ?? .optimized_fast).rawValue }
/// The selection a load runs when none is passed (an on-demand dictation, an API request, the first-dictation Get):
/// the family's recorded selection (config.json `selections`) at the precision's tier; else Optimized · Fast, both for
/// a family used before selections existed (what it ran) and for a model never loaded (family ruling, 29 Sep: fresh
/// installs and on-demand agent loads never land on Standard).
public func defaultSelection(recorded: ModelSelection?, precision: String) -> ModelSelection {
    let tier = modelTier(ofPrecision: precision) ?? recorded?.tier ?? .t16
    if var recorded { recorded.tier = tier; return recorded }
    return ModelSelection(tier: tier, path: .optimized, mode: .fast)
}
/// `defaultSelection` from config.json (nil = none): what a load of `family` at `precision` runs when no selection is
/// passed.
public func recordedSelection(config: Configuration?, family: String, precision: String) -> ModelSelection {
    defaultSelection(recorded: config?.selections[family], precision: precision)
}

/// What actually runs: the requested selection, except that a worker on stock MLX (`engine` "mlx": Standard asked, the
/// self-test failed, or a runtime fallback) runs Standard whatever was asked. `engine` nil = not loaded (the request).
public func effectiveSelection(_ requested: ModelSelection, engine: String?) -> ModelSelection {
    guard engine == "mlx", requested.path == .optimized else { return requested }
    var running = requested; running.path = .standard; return running
}
/// `Standard`, `Optimized Exact`, `Optimized Fast`.
public func recipeLabel(_ selection: ModelSelection) -> String {
    switch selection.segmentKey {
    case .standard: return "Standard"
    case .optimized_exact: return "Optimized Exact"
    case .optimized_fast: return "Optimized Fast"
    }
}
/// The API's selection object: tier, path, mode and the recipe key.
public func selectionObject(_ selection: ModelSelection) -> [String: Any] {
    ["tier": selection.tier.rawValue, "path": selection.path.rawValue, "mode": selection.mode.rawValue, "recipe": selection.segmentKey.rawValue]
}

/// Environment variable the app sets for every worker it launches.
public let workerRecipeVariable = "VELLA_RECIPE"

/// Residency and memory settings, saved in config.json and applied to the running workers.
public struct ResidencySettings: Codable, Equatable {
    public var manualIdleMinutes: Int
    public var onDemandIdleMinutes: Int
    public var allowSwap: Bool
    /// Manual loads only, in load order. Empty on a fresh install. Loaded again at launch.
    public var launchSet: [ModelRef]
    public init(manualIdleMinutes: Int = KeepHot.manualDefault, onDemandIdleMinutes: Int = KeepHot.onDemandDefault,
                allowSwap: Bool = false, launchSet: [ModelRef] = []) {
        self.manualIdleMinutes = manualIdleMinutes; self.onDemandIdleMinutes = onDemandIdleMinutes
        self.allowSwap = allowSwap; self.launchSet = launchSet
    }
    private enum CodingKeys: String, CodingKey { case manualIdleMinutes, onDemandIdleMinutes, allowSwap, launchSet }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func minutes(_ key: CodingKeys, _ fallback: Int) -> Int {
            guard let value = try? values.decodeIfPresent(Int.self, forKey: key), KeepHot.choices.contains(value) else { return fallback }
            return value
        }
        manualIdleMinutes = minutes(.manualIdleMinutes, KeepHot.manualDefault)
        onDemandIdleMinutes = minutes(.onDemandIdleMinutes, KeepHot.onDemandDefault)
        allowSwap = (try? values.decodeIfPresent(Bool.self, forKey: .allowSwap)) ?? false
        launchSet = (try? values.decodeIfPresent([ModelRef].self, forKey: .launchSet)) ?? []
    }
    public func idleMinutes(_ residency: ResidencyClass) -> Int { residency == .manual ? manualIdleMinutes : onDemandIdleMinutes }
    /// A manual load joins the launch set (replacing the family's other precision). On-demand loads never do.
    public mutating func join(_ ref: ModelRef) {
        if let index = launchSet.firstIndex(where: { $0.id == ref.id }) { launchSet[index] = ref } else { launchSet.append(ref) }
    }
    /// Only an explicit Unload or Delete, after the worker confirmed it, removes a model from the launch set.
    public mutating func leave(_ id: String) { launchSet.removeAll { $0.id == id } }
}

/// When an idle model unloads: `lastUsed` + its class's window; nil = Always.
/// `minuteSeconds` is 60 in production; `VELLA_TEST_MINUTE_SECONDS` shortens it in tests.
public func unloadDeadline(lastUsed: Double, residency: ResidencyClass, settings: ResidencySettings, minuteSeconds: Double = 60) -> Double? {
    let minutes = settings.idleMinutes(residency)
    guard minutes > 0 else { return nil }
    return lastUsed + Double(minutes) * minuteSeconds
}

/// Numeric width of a precision label for ordering: "4b" 4, "8b" 8, "BF16"/"FP16" 16, "FP32" 32.
public func precisionBits(_ label: String) -> Double? {
    let digits = label.filter { $0.isNumber || $0 == "." }
    return Double(digits)
}

// MARK: - Memory admission

/// Best-effort estimate of what macOS can hand out right now without swapping, in MB (1e6 bytes, like `memory_mb`).
/// A load-time check, not a guarantee: other processes and later inference allocations are not bounded by it.
///
///     pages_mb  = (free − speculative + external (file-backed) + purgeable) × page size    disjoint populations
///     level_mb  = kern.memorystatus_level / 100 × RAM                                      the kernel's pressure gauge
///     margin_mb = max(1 GB, 10 % of RAM)
///     raw       = min(pages_mb, level_mb) − margin_mb                                      negative when already short
///
/// inactive_count is not used: it overlaps purgeable and file-backed pages, and its anonymous remainder is compressed
/// or swapped, not freed. Test hooks, re-read on every check: `VELLA_TEST_MEMORY_FILE` = JSON {"available_mb": N}
/// (raw = N − what unloading the loaded models would free, so an unload gives back exactly what it took);
/// `VELLA_TEST_VM_STATS` = JSON with the counters, `page_size` and `memorystatus_level` in place of the kernel's.
public struct MemoryProbe {
    public static let headroomMB = 512.0
    public let totalMB: Double
    public var marginMB: Double { max(1000, totalMB * 0.10) }
    public let testFile: URL?
    public let vmStatsFile: URL?
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, totalMB: Double? = nil) {
        self.totalMB = totalMB ?? Double(ProcessInfo.processInfo.physicalMemory) / 1e6
        testFile = environment["VELLA_TEST_MEMORY_FILE"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        vmStatsFile = environment["VELLA_TEST_VM_STATS"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
    }
    /// Never negative.
    public func availableMB(loadedMB: Double) -> Double { max(0, rawAvailableMB(loadedMB: loadedMB)) }
    /// `loadedMB`: Σ reclaimable MB of the models loaded now (used by the test file probe only).
    public func rawAvailableMB(loadedMB: Double) -> Double {
        if let testFile {
            let base = (Self.json(testFile)?["available_mb"] as? NSNumber)?.doubleValue ?? 0
            return base - loadedMB
        }
        let counters = vmStatsFile.map { Self.json($0) ?? [:] }
        return min(pagesMB(counters), levelPercent(counters) / 100 * totalMB) - marginMB
    }
    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    public static func reclaimableMB(free: Double, speculative: Double, external: Double, purgeable: Double, pageSize: Double) -> Double {
        (max(0, free - speculative) + external + purgeable) * pageSize / 1e6
    }
    private func pagesMB(_ counters: [String: Any]?) -> Double {
        if let counters {
            func value(_ key: String) -> Double { (counters[key] as? NSNumber)?.doubleValue ?? 0 }
            return Self.reclaimableMB(free: value("free_count"), speculative: value("speculative_count"),
                                      external: value("external_page_count"), purgeable: value("purgeable_count"), pageSize: value("page_size"))
        }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Self.reclaimableMB(free: Double(info.free_count), speculative: Double(info.speculative_count),
                                  external: Double(info.external_page_count), purgeable: Double(info.purgeable_count),
                                  pageSize: Double(vm_kernel_page_size))
    }
    private func levelPercent(_ counters: [String: Any]?) -> Double {
        if let level = counters?["memorystatus_level"] as? NSNumber { return level.doubleValue }
        return Self.levelPercent()
    }
    public static func levelPercent() -> Double {
        var value: Int32 = 100; var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 ? Double(value) : 100
    }
}

/// Load-size estimate in MB without the activation headroom: the measured `memory_mb` at this precision (process
/// footprint after load and warm-up), else the weights on disk plus a fixed runtime overhead (768 MB).
public func memoryEstimateMB(_ ref: ModelRef) -> Double {
    if let measured = ref.memoryMB, measured > 0 { return measured }
    return Double(ref.diskBytes ?? 0) / 1e6 + 768
}

/// A model loaded now, as admission sees it.
public struct LoadedModelInfo: Equatable {
    public var id: String
    public var name: String
    public var residency: ResidencyClass
    public var lastUsed: Double
    /// What unloading it frees (its worker's footprint, else the load estimate).
    public var reclaimMB: Double
    public init(id: String, name: String? = nil, residency: ResidencyClass, lastUsed: Double, reclaimMB: Double) {
        self.id = id; self.name = name ?? id; self.residency = residency; self.lastUsed = lastUsed; self.reclaimMB = reclaimMB
    }
}

/// On-demand models least recently used first, then manual ones the same way.
public func evictionOrder(_ loaded: [LoadedModelInfo]) -> [LoadedModelInfo] {
    func lru(_ residency: ResidencyClass) -> [LoadedModelInfo] {
        loaded.filter { $0.residency == residency }.sorted { $0.lastUsed < $1.lastUsed }
    }
    return lru(.onDemand) + lru(.manual)
}

public enum AdmissionDecision: Equatable {
    /// Load; unload these first (in order).
    case admit(evict: [String], needMB: Double, freeMB: Double)
    case refuse(message: String, needMB: Double, freeMB: Double)
}

/// "Fit in free memory": need = estimate + 512 MB activation headroom. Too little: unload idle models (on-demand LRU
/// first, then manual; never `ref` itself or a model in `together`). If even unloading every candidate cannot free
/// enough by their estimates, nothing is unloaded and the load is refused with the numbers and only remedies that can
/// work. `rawAvailableMB` may be negative (a deficit must be paid off first). `credit`: memory the caller frees before
/// loading (the same family at another precision, on Reload); it is added before clamping. Allow swap admits all.
public func planAdmission(_ ref: ModelRef, loaded: [LoadedModelInfo], rawAvailableMB: Double, credit: Double = 0,
                          together: [String] = [], allowSwap: Bool) -> AdmissionDecision {
    let need = memoryEstimateMB(ref) + MemoryProbe.headroomMB
    let raw = rawAvailableMB + credit
    let free = max(0, raw)
    if allowSwap || free >= need { return .admit(evict: [], needMB: need, freeMB: free) }
    let candidates = evictionOrder(loaded).filter { $0.id != ref.id && !together.contains($0.id) }
    if raw + candidates.reduce(0, { $0 + $1.reclaimMB }) >= need {
        var headroom = raw, victims: [String] = []
        for victim in candidates {
            victims.append(victim.id); headroom += victim.reclaimMB
            if headroom >= need { return .admit(evict: victims, needMB: need, freeMB: free) }
        }
    }
    let unloadable = loaded.filter { $0.id != ref.id && !together.contains($0.id) }.map(\.name)
    let needed = loaded.filter { together.contains($0.id) }.map(\.name)
    return .refuse(message: refusalMessage(ref, needMB: need, freeMB: free, loaded: unloadable, together: needed), needMB: need, freeMB: free)
}

/// "1.5" for 1,520 MB.
public func gigabytes(_ mb: Double) -> String { String(format: "%.1f", max(0, mb) / 1000) }

/// The next smaller offered precision label, if any ("8b" for a BF16 request offering 4b/8b/BF16).
public func smallerPrecision(_ ref: ModelRef) -> String? {
    guard let current = precisionBits(ref.precision) else { return nil }
    return (ref.precisionOptions ?? []).compactMap { label in precisionBits(label).map { (label, $0) } }
        .filter { $0.1 < current }.max { $0.1 < $1.1 }?.0
}

/// Need, what is free, and the ways out that exist for this request. `loaded`: models that could be unloaded (never
/// one the request needs). `together`: loaded models this request also needs; unloading them cannot help, so the
/// advice is to load one model at a time instead.
public func refusalMessage(_ ref: ModelRef, needMB: Double, freeMB: Double, loaded: [String], together: [String] = []) -> String {
    var fixes: [String] = []
    var context = ""
    if !together.isEmpty {
        let names = together + [ref.displayName]
        context = " This needs " + names.dropLast().joined(separator: ", ") + " and " + names.last! + " loaded together."
        fixes.append("load one model at a time")
    }
    if !loaded.isEmpty { fixes.append("unload " + loaded.joined(separator: " or ")) }
    if let lower = smallerPrecision(ref) { fixes.append("pick \(precisionInProse(lower))") }
    fixes.append("allow swap in Vella → Memory")
    var advice = fixes.count == 1 ? fixes[0] : fixes.dropLast().joined(separator: ", ") + (fixes.count > 2 ? ", or " : " or ") + fixes.last!
    advice = advice.prefix(1).uppercased() + advice.dropFirst()
    return "\(ref.displayWithPrecision) needs ~\(gigabytes(needMB)) GB; ~\(gigabytes(freeMB)) GB free without swapping.\(context) \(advice)."
}

/// Critical memory pressure: keep the first manual model (else the first loaded), unload the rest except `pinned`.
public func shedVictims(_ loaded: [LoadedModelInfo], order: [String], pinned: Set<String>) -> [String] {
    let keep = order.first { id in loaded.first { $0.id == id }?.residency == .manual } ?? order.first
    return evictionOrder(loaded).map(\.id).filter { $0 != keep && !pinned.contains($0) }
}
