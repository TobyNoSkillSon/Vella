import Foundation

// The helpers' stdio protocol: one JSON object per line. The app sends requests with an `id`; a helper answers each
// with a reply carrying that `id`, and pushes a `{"status": …}` line (no `id`) before every reply that changes its
// state. The helpers write their lines with JSONSerialization (`asciiJSONLine`), so the values below keep the exact
// JSON the app, the `vella` command and lab scripts read (Tests/Fixtures/wire pins the bytes).

/// A helper's pushed status.
public struct HelperStatus: Equatable, Sendable {
    public enum Kind: String, Sendable { case dictation, streaming }
    public struct Memory: Equatable, Sendable {
        /// Process physical footprint (MB); nil when unavailable.
        public var footprintMB: Double?
        public var mlxActiveMB: Double?
        public var mlxCacheMB: Double?
        public init(footprintMB: Double?, mlxActiveMB: Double?, mlxCacheMB: Double?) {
            self.footprintMB = footprintMB; self.mlxActiveMB = mlxActiveMB; self.mlxCacheMB = mlxCacheMB
        }
    }
    public struct GPU: Equatable, Sendable {
        public var chip: String?
        public var family: String?
        public init(chip: String?, family: String?) { self.chip = chip; self.family = family }
    }
    public var worker: Kind?
    public var pid: Int?
    /// The gate version (`FastPathGate.version`).
    public var version: String?
    /// What changed: `load`, `load-failed`, `unload`, `status`, `trim`, `fallback`.
    public var event: String?
    /// The loaded model's path; nil when none.
    public var model: String?
    /// The dictation helper's loaded architecture.
    public var architecture: String?
    /// `Engine` raw value; nil when no model is loaded.
    public var engine: String?
    /// Why the model runs stock, or which parts are stock; nil when fully optimized.
    public var engineReason: String?
    public var optimizations: [String: Bool]?
    public var loadSeconds: Double?
    public var memory: Memory?
    /// The dictation helper's host GPU.
    public var gpu: GPU?
    /// The recipe the helper runs (`Recipe` raw value).
    public var recipe: String?
    /// Diagnostic switches set in the helper (omitted when none).
    public var testHooks: [String: String]
    /// Tolerant components the gate left off, with why (dictation; omitted when none).
    public var disabledComponents: [String: String]

    public init(worker: Kind?, pid: Int?, version: String?, event: String?, model: String?, architecture: String? = nil,
                engine: String?, engineReason: String?, optimizations: [String: Bool]?, loadSeconds: Double?, memory: Memory?,
                gpu: GPU? = nil, recipe: String?, testHooks: [String: String] = [:], disabledComponents: [String: String] = [:]) {
        self.worker = worker; self.pid = pid; self.version = version; self.event = event; self.model = model
        self.architecture = architecture; self.engine = engine; self.engineReason = engineReason; self.optimizations = optimizations
        self.loadSeconds = loadSeconds; self.memory = memory; self.gpu = gpu; self.recipe = recipe; self.testHooks = testHooks
        self.disabledComponents = disabledComponents
    }

    /// Reads a pushed status object. Like the app always did, a field of an unexpected type counts as absent.
    public init(json object: [String: Any]) {
        let memory = object["memory"] as? [String: Any], gpu = object["gpu"] as? [String: Any]
        self.init(worker: (object["worker"] as? String).flatMap(Kind.init(rawValue:)),
                  pid: (object["pid"] as? NSNumber)?.intValue, version: object["version"] as? String,
                  event: object["event"] as? String, model: object["model"] as? String,
                  architecture: object["architecture"] as? String, engine: object["engine"] as? String,
                  engineReason: object["engine_reason"] as? String, optimizations: object["optimizations"] as? [String: Bool],
                  loadSeconds: object["load_s"] as? Double,
                  memory: memory.map { Memory(footprintMB: $0["footprint_mb"] as? Double, mlxActiveMB: $0["mlx_active_mb"] as? Double,
                                              mlxCacheMB: $0["mlx_cache_mb"] as? Double) },
                  gpu: gpu.map { GPU(chip: $0["chip"] as? String, family: $0["family"] as? String) },
                  recipe: object["recipe"] as? String, testHooks: object["test_hooks"] as? [String: String] ?? [:],
                  disabledComponents: object["disabled_components"] as? [String: String] ?? [:])
    }

    /// The object as the helpers write it. Absent model, engine, reason and load time are `null`; the dictation
    /// helper also writes its architecture (`null` when none) and GPU; empty hooks and disabled components are omitted.
    public var jsonObject: [String: Any] {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        var memoryObject: [String: Any] = [:]
        if let memory {
            if let v = memory.mlxActiveMB { memoryObject["mlx_active_mb"] = v }
            if let v = memory.mlxCacheMB { memoryObject["mlx_cache_mb"] = v }
            if let v = memory.footprintMB { memoryObject["footprint_mb"] = v }
        }
        var object: [String: Any] = [
            "worker": orNull(worker?.rawValue), "pid": orNull(pid), "version": orNull(version), "event": orNull(event),
            "model": orNull(model), "engine": orNull(engine), "engine_reason": orNull(engineReason),
            "optimizations": optimizations ?? [String: Bool](), "load_s": orNull(loadSeconds), "memory": memoryObject,
            "recipe": orNull(recipe),
        ]
        if worker == .dictation {
            object["architecture"] = orNull(architecture)
            if let gpu { object["gpu"] = ["chip": orNull(gpu.chip), "family": orNull(gpu.family)] }
        }
        if !testHooks.isEmpty { object["test_hooks"] = testHooks }
        if !disabledComponents.isEmpty { object["disabled_components"] = disabledComponents }
        return object
    }
}

/// A reply to the streaming helper's requests (`load`/`unload`, audio packets, `finish`).
public struct StreamingReply: Decodable, Equatable, Sendable {
    public let id: UUID
    /// Audio frames the helper has consumed so far.
    public let frames: Int?
    /// Newly committed text (appended; never revised).
    public let committed: String?
    /// The current partial text (replaces the previous partial).
    public let partial: String?
    public let done: Bool?
    public let error: String?
    /// Some recognized text was withheld: the result is incomplete.
    public let incomplete: Bool?
    public let loaded: Bool?
}
