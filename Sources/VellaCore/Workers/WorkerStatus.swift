import Foundation
import VellaWire

/// One loaded model in `worker-status.json`. Every field is optional on decode so older files still render.
public struct WorkerModelStatus: Codable, Equatable {
    public var mode: RecognitionMode?
    public var precision: String?
    public var path: String?
    public var name: String?
    public var pid: Int32?
    /// "optimized" (self-tested optimized components active) or "mlx" (stock path).
    public var engine: String?
    /// Why the model is on the stock path, or which parts are stock (nil when fully optimized).
    public var engine_reason: String?
    /// Component → active on the optimized path.
    public var optimizations: [String: Bool]?
    /// "manual" or "on_demand".
    public var residency: String?
    /// Keep Hot window for its class in minutes; 0 = Always.
    public var keep_hot_min: Int?
    /// Seconds since 1970.
    public var last_used: Double?
    public var unloads_at: Double?
    public var load_s: Double?
    /// Worker process footprint.
    public var memory_mb: Double?
    /// The worker's optimized-path gate version (e.g. "native-kernels-8"), for `vella diagnose`.
    public var worker_version: String?
    /// The requested selection the worker was launched with (tier × Standard/Optimized × Exact/Fast); `engine` says what
    /// actually runs (a failed self-test or a runtime fallback leaves an Optimized selection on stock MLX).
    public var selection: ModelSelection?
    public init() {}
}

public struct Eviction: Codable, Equatable {
    public var model: String
    public var residency: String?
    public var reason: String
    public var at: Double
    public init(model: String, residency: String? = nil, reason: String, at: Double) {
        self.model = model; self.residency = residency; self.reason = reason; self.at = at
    }
}

/// The last load refused in Fit in free memory.
public struct Refusal: Codable, Equatable {
    public var model: String
    public var message: String
    public var at: Double
    public var need_mb: Double?
    public var free_mb: Double?
    public init(model: String, message: String, at: Double, need_mb: Double? = nil, free_mb: Double? = nil) {
        self.model = model; self.message = message; self.at = at; self.need_mb = need_mb; self.free_mb = free_mb
    }
}

public struct GPUStatus: Codable, Equatable {
    public var chip: String?
    /// Metal GPU family the engine gate keys on ("apple9"); never a chip name.
    public var family: String?
    public init(chip: String? = nil, family: String? = nil) { self.chip = chip; self.family = family }
}

public struct MemoryStatus: Codable, Equatable {
    public var available_mb: Double?
    public var ram_mb: Double?
    /// Σ worker footprints.
    public var workers_mb: Double?
    public init(available_mb: Double? = nil, ram_mb: Double? = nil, workers_mb: Double? = nil) {
        self.available_mb = available_mb; self.ram_mb = ram_mb; self.workers_mb = workers_mb
    }
}

public struct StatusSettings: Codable, Equatable {
    public var manual_idle_minutes: Int?
    public var on_demand_idle_minutes: Int?
    public var allow_swap: Bool?
    public init(_ settings: ResidencySettings) {
        manual_idle_minutes = settings.manualIdleMinutes; on_demand_idle_minutes = settings.onDemandIdleMinutes
        allow_swap = settings.allowSwap
    }
}

/// Written by the app (atomic tmp + rename) after every runtime change, from the workers' pushed status lines.
/// The in-app UI reads the same value in process; the file is for tests, the installer and diagnosis.
public struct WorkerStatus: Codable, Equatable {
    public var schema: Int? = 1
    public var updated: Double = 0
    public var app_pid: Int32?
    public var models: [String: WorkerModelStatus] = [:]
    /// Model id being loaded now.
    public var loading: String?
    public var error: String?
    public var memory: MemoryStatus?
    public var settings: StatusSettings?
    public var launch_set: [String]?
    public var evictions: [Eviction]?
    public var refused: Refusal?
    public var gpu: GPUStatus?
    /// Diagnostic environment switches active in this app or its workers. Empty in normal use.
    public var test_hooks: [String: String]?
    /// The local HTTP API: its version and the loopback port it listens on this launch (nil until it is ready).
    public var api: Int?
    public var api_port: Int?
    /// Per-launch secret a JSON request naming a local file must send (`X-Vella-Token`). Readable only by processes that
    /// can read this file, which excludes sandboxed apps: they cannot make Vella read files outside their sandbox.
    public var api_token: String?
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case schema, updated, app_pid, models, loading, error, memory, settings, launch_set, evictions, refused, gpu, test_hooks, api, api_port, api_token
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try? c.decodeIfPresent(Int.self, forKey: .schema)
        updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
        app_pid = try? c.decodeIfPresent(Int32.self, forKey: .app_pid)
        models = (try? c.decodeIfPresent([String: WorkerModelStatus].self, forKey: .models)) ?? [:]
        loading = try? c.decodeIfPresent(String.self, forKey: .loading)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        memory = try? c.decodeIfPresent(MemoryStatus.self, forKey: .memory)
        settings = try? c.decodeIfPresent(StatusSettings.self, forKey: .settings)
        launch_set = try? c.decodeIfPresent([String].self, forKey: .launch_set)
        evictions = try? c.decodeIfPresent([Eviction].self, forKey: .evictions)
        refused = try? c.decodeIfPresent(Refusal.self, forKey: .refused)
        gpu = try? c.decodeIfPresent(GPUStatus.self, forKey: .gpu)
        test_hooks = try? c.decodeIfPresent([String: String].self, forKey: .test_hooks)
        api = try? c.decodeIfPresent(Int.self, forKey: .api)
        api_port = try? c.decodeIfPresent(Int.self, forKey: .api_port)
        api_token = try? c.decodeIfPresent(String.self, forKey: .api_token)
    }
    /// Atomic: write a unique temporary file beside the target, then rename(2) over it. The file carries the API
    /// token, so every version is owner-only (0600, no inherited ACL entries) from before its first byte is written.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        do { try writeOwnerOnly(data, to: temporary) } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw VellaError.message("Could not update \(url.lastPathComponent).")
        }
    }
    public static func read(_ url: URL) -> WorkerStatus? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(WorkerStatus.self, from: $0) }
    }
}

/// Creates `url` (which must not exist) readable and writable by its owner only, with any ACL entries inherited from
/// the directory removed, verifies that, and only then writes `data`. If the ACL cannot be cleared (including when no
/// empty ACL can be allocated), it throws before writing anything: an inherited entry could still grant others read.
/// `emptyACL` is replaceable for tests.
public func writeOwnerOnly(_ data: Data, to url: URL, emptyACL: () -> acl_t? = { acl_init(0) }) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw VellaError.message("Could not create \(url.lastPathComponent).") }
    defer { close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw VellaError.message("Could not restrict \(url.lastPathComponent).") }
    guard let empty = emptyACL() else { throw VellaError.message("Could not restrict \(url.lastPathComponent).") }
    defer { acl_free(UnsafeMutableRawPointer(empty)) }
    guard acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0 else { throw VellaError.message("Could not restrict \(url.lastPathComponent).") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & 0o077 == 0, info.st_uid == geteuid() else {
        throw VellaError.message("Could not restrict \(url.lastPathComponent).")
    }
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 { if errno == EINTR { continue }; throw VellaError.message("Could not write \(url.lastPathComponent).") }
            offset += written
        }
    }
}

/// Diagnostic switches (and switched-off app features) the app reports in status when set, never hidden.
public let runtimeTestHookNames = EnvironmentSwitch.names(where: \.appReported)
public func activeTestHooks(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    environment.filter { runtimeTestHookNames.contains($0.key) && !$0.value.isEmpty }
}
