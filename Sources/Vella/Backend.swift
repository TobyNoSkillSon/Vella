import Foundation
import Darwin
import VellaCore

/// Residency, memory admission and status for every loaded model, across the dictation and streaming workers.
/// Each loaded model is one private worker process; unloading a model ends its process. The app is the single
/// writer of `worker-status.json` (atomic tmp + rename, synchronously on every change), from the status lines the
/// workers push on stdout. Idle unloads are exact per-model timers, not a polling tick.
@MainActor final class Runtime: ObservableObject {
    static let shared = Runtime()
    let support: URL
    let environment: [String: String]
    let minuteSeconds: Double
    var probe: MemoryProbe
    @Published private(set) var status = WorkerStatus()
    private(set) var settings: ResidencySettings
    /// Maps a model path to its catalog identity (family id, precision, measured memory). Wired by the app's model
    /// library; without it a path is identified by its folder name.
    var resolver: ((String, RecognitionMode) -> ModelRef?)?
    weak var dictation: Backend?
    weak var streaming: StreamingBackend?
    var statusURL: URL { support.appendingPathComponent("worker-status.json") }
    var configURL: URL { support.appendingPathComponent("config.json") }

    private struct Entry {
        var ref: ModelRef
        var residency: ResidencyClass
        var lastUsed: Double
        var worker: [String: Any]
        var unload: @MainActor () async -> Void
        var timer: DispatchWorkItem?
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var pinned: [String: Int] = [:]
    private var pendingWorker: [String: [String: Any]] = [:]
    private var evictions: [Eviction] = []
    private var refused: Refusal?
    private var loading: String?
    private var error: String?
    private var gpu: GPUStatus?
    private var workerHooks: [String: String] = [:]
    private var restarts: [String: Int] = [:]

    init(support: URL = Backend.support, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.support = support; self.environment = environment
        probe = MemoryProbe(environment: environment)
        minuteSeconds = environment["VELLA_TEST_MINUTE_SECONDS"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 60
        let config = (try? Data(contentsOf: support.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        settings = config?.residency ?? ResidencySettings()
    }

    /// App launch: publish an empty status (no stale models), keep config.json's residency explicit, then load the
    /// launch set (manual loads only; empty on a fresh install, so nothing loads or downloads).
    func start(loadLaunchSet: Bool = true) {
        try? FileManager.default.removeItem(at: statusURL)
        if !FileManager.default.fileExists(atPath: configURL.path) { persistSettings() }
        writeStatus()
        guard loadLaunchSet, !settings.launchSet.isEmpty else { return }
        Task { await self.loadLaunchSet() }
    }
    func loadLaunchSet() async {
        for ref in settings.launchSet where entries[ref.id] == nil {
            guard FileManager.default.fileExists(atPath: ref.path) else {
                error = "\(ref.displayName) is in the launch set but its files are missing. Get it again or unload it."; writeStatus(); continue
            }
            do { try await load(ref) } catch { /* recorded in status (refused / error) */ }
        }
    }

    // MARK: Identity

    func resolve(_ path: String, mode: RecognitionMode) -> ModelRef {
        if let ref = resolver?(path, mode) { return ref }
        if let ref = settings.launchSet.first(where: { $0.path == path }) { return ref }
        if let entry = entries.values.first(where: { $0.ref.path == path }) { return entry.ref }
        return ModelRef(id: URL(fileURLWithPath: path).lastPathComponent, path: path, mode: mode, diskBytes: Self.folderBytes(path))
    }
    nonisolated static func folderBytes(_ path: String) -> Int64? {
        guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
    func isLoaded(_ id: String) -> Bool { entries[id] != nil }
    func loadedRef(_ id: String) -> ModelRef? { entries[id]?.ref }
    /// A request on this model that loads it: manual if it is in the launch set, else on demand.
    func residencyForRequest(_ ref: ModelRef) -> ResidencyClass {
        entries[ref.id]?.residency ?? (settings.launchSet.contains { $0.id == ref.id } ? .manual : .onDemand)
    }

    // MARK: UI actions

    /// Menu Load (or launch set): manual residency, joins the launch set. Reload when the family is loaded at another
    /// precision.
    func load(_ ref: ModelRef) async throws {
        switch ref.mode {
        case .dictation:
            guard let dictation else { throw VellaError.message("Vella's dictation runtime is not running.") }
            try await dictation.preload(ref, residency: .manual)
        case .streaming:
            guard let streaming else { throw VellaError.message("Vella's streaming runtime is not running.") }
            try await streaming.preload(ref, residency: .manual)
        }
        promote(ref.id)
    }
    /// Menu Unload: the model leaves memory and, once its worker has exited, the launch set.
    func unload(_ id: String) async {
        if let entry = entries[id] { await entry.unload() }
        settings.leave(id); persistSettings(); writeStatus()
    }
    /// Before Delete: same as Unload.
    func forget(_ id: String) async { await unload(id) }
    func setKeepHot(manual: Int? = nil, onDemand: Int? = nil) {
        if let manual, KeepHot.choices.contains(manual) { settings.manualIdleMinutes = manual }
        if let onDemand, KeepHot.choices.contains(onDemand) { settings.onDemandIdleMinutes = onDemand }
        persistSettings()
        for id in order { schedule(id) }
        writeStatus()
    }
    func setAllowSwap(_ allow: Bool) {
        settings.allowSwap = allow
        if allow { refused = nil }
        persistSettings(); writeStatus()
    }

    // MARK: Admission

    private func reclaimMB(_ entry: Entry) -> Double {
        if let footprint = (entry.worker["memory"] as? [String: Any])?["footprint_mb"] as? Double, footprint > 0 { return footprint }
        return memoryEstimateMB(entry.ref)
    }
    private var loadedReclaimMB: Double { entries.values.reduce(0) { $0 + reclaimMB($1) } }
    /// What unloading this loaded model would free (used as a reload credit).
    func reclaim(_ id: String) -> Double { entries[id].map(reclaimMB) ?? 0 }
    /// Fit in free memory: admit `ref`, unloading idle models first when needed (on-demand LRU first, never a busy
    /// one or one in `together`), or throw the refusal with the numbers and working remedies. Nothing is unloaded
    /// when unloading everything possible would still not fit. Allow swap admits everything.
    func admit(_ ref: ModelRef, credit: Double = 0, together: [String] = []) async throws {
        func infos() -> [LoadedModelInfo] {
            order.compactMap { id in
                guard let entry = entries[id], id != ref.id, (pinned[id] ?? 0) == 0 else { return nil }
                return LoadedModelInfo(id: id, name: entry.ref.displayName, residency: entry.residency, lastUsed: entry.lastUsed, reclaimMB: reclaimMB(entry))
            }
        }
        let names = together.map { entries[$0]?.ref.displayName ?? $0 }
        var decision = planAdmission(ref, loaded: infos(), rawAvailableMB: probe.rawAvailableMB(loadedMB: loadedReclaimMB),
                                     credit: credit, together: together, allowSwap: settings.allowSwap)
        if case .admit(let victims, let need, let free) = decision, !victims.isEmpty {
            for victim in victims {
                await evict(victim, reason: "memory: made room for \(ref.displayWithPrecision) (needs ~\(gigabytes(need)) GB; ~\(gigabytes(free)) GB was free without swapping)")
            }
            // Re-check against the probe: estimates are not measurements.
            decision = planAdmission(ref, loaded: infos(), rawAvailableMB: probe.rawAvailableMB(loadedMB: loadedReclaimMB),
                                     credit: credit, together: together, allowSwap: settings.allowSwap)
            if case .admit(let more, _, _) = decision, !more.isEmpty {
                decision = .refuse(message: refusalMessage(ref, needMB: need, freeMB: free, loaded: infos().map(\.name), together: names), needMB: need, freeMB: free)
            }
        }
        if case .refuse(let message, let need, let free) = decision {
            refused = Refusal(model: ref.id, message: message, at: Date().timeIntervalSince1970, need_mb: need, free_mb: free)
            writeStatus()
            throw VellaError.message(message)
        }
    }

    // MARK: Worker lifecycle (called by the backends)

    func beginLoading(_ id: String) { loading = id; writeStatus() }
    func loadFailed(_ id: String, message: String) { if loading == id { loading = nil }; error = message; pendingWorker[id] = nil; writeStatus() }
    func register(_ ref: ModelRef, residency: ResidencyClass, unload: @escaping @MainActor () async -> Void) {
        let now = Date().timeIntervalSince1970
        let previous = entries[ref.id]
        entries[ref.id] = Entry(ref: ref, residency: previous?.residency == .manual ? .manual : residency, lastUsed: now,
                                worker: pendingWorker.removeValue(forKey: ref.id) ?? previous?.worker ?? [:], unload: unload, timer: previous?.timer)
        if !order.contains(ref.id) { order.append(ref.id) }
        if loading == ref.id { loading = nil }
        refused = nil; error = nil; restarts[ref.id] = 0
        if entries[ref.id]?.residency == .manual { settings.join(ref); persistSettings() }
        schedule(ref.id)
        writeStatus()
    }
    /// A status line pushed by the model's worker.
    func update(_ id: String, worker: [String: Any]) {
        if let chip = (worker["gpu"] as? [String: Any]).map({ GPUStatus(chip: $0["chip"] as? String, family: $0["family"] as? String) }) { gpu = chip }
        if let hooks = worker["test_hooks"] as? [String: String] { workerHooks.merge(hooks) { $1 } }
        if entries[id] != nil { entries[id]!.worker = worker } else { pendingWorker[id] = worker }
        writeStatus()
    }
    func promote(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.residency = .manual; entries[id] = entry
        settings.join(entry.ref); persistSettings(); schedule(id); writeStatus()
    }
    func pin(_ id: String) { pinned[id, default: 0] += 1 }
    func unpin(_ id: String) {
        pinned[id] = max(0, (pinned[id] ?? 1) - 1)
        touch(id)
    }
    func touch(_ id: String) {
        guard entries[id] != nil else { return }
        entries[id]!.lastUsed = Date().timeIntervalSince1970
        schedule(id); writeStatus()
    }
    /// The worker is gone (unloaded, evicted, retired or crashed).
    func removed(_ id: String) {
        entries[id]?.timer?.cancel()
        entries[id] = nil; order.removeAll { $0 == id }; pinned[id] = nil; pendingWorker[id] = nil
        if loading == id { loading = nil }
        writeStatus()
    }
    /// Unexpected exit. A manual model restarts after 2, 4, then 6 s; after three failures it stays unloaded and the
    /// error is shown. On-demand models load again on the next request.
    func crashed(_ id: String, message: String) {
        let entry = entries[id]
        removed(id)
        error = message; writeStatus()
        guard let entry, entry.residency == .manual else { return }
        let attempt = restarts[id, default: 0]
        guard attempt < 3 else { return }
        restarts[id] = attempt + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(2 * (attempt + 1))) { [weak self] in
            guard let self, self.entries[id] == nil, self.settings.launchSet.contains(where: { $0.id == id }) else { return }
            Task { try? await self.load(entry.ref) }
        }
    }
    func evict(_ id: String, reason: String) async {
        guard let entry = entries[id] else { return }
        evictions.append(Eviction(model: id, residency: entry.residency.rawValue, reason: reason, at: Date().timeIntervalSince1970))
        evictions = Array(evictions.suffix(20))
        await entry.unload()
        removed(id)
    }
    /// Critical memory pressure: keep the first manual model (else the first loaded), unload the rest except busy ones.
    func shed() async {
        let infos = order.compactMap { id in entries[id].map { LoadedModelInfo(id: id, residency: $0.residency, lastUsed: $0.lastUsed, reclaimMB: reclaimMB($0)) } }
        let busy = Set(pinned.filter { $0.value > 0 }.keys)
        for id in shedVictims(infos, order: order, pinned: busy) {
            await evict(id, reason: "memory pressure (kern.memorystatus_level \(Int(MemoryProbe.levelPercent()))%)")
        }
    }
    private func schedule(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.timer?.cancel(); entry.timer = nil
        if let deadline = unloadDeadline(lastUsed: entry.lastUsed, residency: entry.residency, settings: settings, minuteSeconds: minuteSeconds) {
            let minutes = settings.idleMinutes(entry.residency), residency = entry.residency
            let work = DispatchWorkItem { [weak self] in
                guard let self, let current = self.entries[id] else { return }
                if (self.pinned[id] ?? 0) > 0 || Date().timeIntervalSince1970 + 0.001 < deadline || current.residency != residency { self.schedule(id); return }
                Task { await self.evict(id, reason: "idle: unused for \(minutes) min (\(residency == .manual ? "manually loaded" : "loaded on demand"))") }
            }
            entry.timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - Date().timeIntervalSince1970), execute: work)
        }
        entries[id] = entry
    }

    // MARK: Persistence

    private func persistSettings() {
        var config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration(model: "")
        config.residency = settings
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: configURL, options: .atomic) }
    }
    func writeStatus() {
        var next = WorkerStatus()
        next.updated = Date().timeIntervalSince1970
        next.app_pid = getpid()
        for (id, entry) in entries {
            var model = WorkerModelStatus()
            model.mode = entry.ref.mode; model.precision = entry.ref.precision; model.path = entry.ref.path; model.name = entry.ref.name
            model.pid = (entry.worker["pid"] as? NSNumber).map { Int32(truncating: $0) }
            model.engine = entry.worker["engine"] as? String
            model.engine_reason = entry.worker["engine_reason"] as? String
            model.optimizations = entry.worker["optimizations"] as? [String: Bool]
            model.residency = entry.residency.rawValue
            model.keep_hot_min = settings.idleMinutes(entry.residency)
            model.last_used = entry.lastUsed
            model.unloads_at = unloadDeadline(lastUsed: entry.lastUsed, residency: entry.residency, settings: settings, minuteSeconds: minuteSeconds)
            model.load_s = entry.worker["load_s"] as? Double
            model.memory_mb = (entry.worker["memory"] as? [String: Any])?["footprint_mb"] as? Double
            next.models[id] = model
        }
        next.loading = loading
        next.error = error
        next.memory = MemoryStatus(available_mb: probe.availableMB(loadedMB: loadedReclaimMB), ram_mb: probe.totalMB,
                                   workers_mb: entries.values.compactMap { ($0.worker["memory"] as? [String: Any])?["footprint_mb"] as? Double }.reduce(0, +))
        next.settings = StatusSettings(settings)
        next.launch_set = settings.launchSet.map(\.id)
        next.evictions = evictions
        next.refused = refused
        next.gpu = gpu
        next.test_hooks = activeTestHooks(environment).merging(workerHooks) { $1 }
        status = next
        try? next.write(to: statusURL)
    }
}

/// One private worker process for one loaded dictation model. One request in flight at a time.
@MainActor final class DictationSlot {
    let ref: ModelRef
    let process: Process
    let input: FileHandle
    var buffer = Data()
    var pending: (UUID, CheckedContinuation<[String: Any], Error>)?
    var deadline: DispatchWorkItem?
    var retiring = false
    init(ref: ModelRef, process: Process, input: FileHandle) { self.ref = ref; self.process = process; self.input = input }
    var pid: Int32? { process.isRunning ? process.processIdentifier : nil }
}

/// Private, offline dictation workers: one process per loaded model, no listening port or shared model service.
@MainActor final class Backend {
    let requestTimeout: TimeInterval
    let runtime: Runtime
    private let helperOverride: URL?
    private var slots: [String: DictationSlot] = [:]
    private var retired: [Process] = []
    private var stopGeneration = UUID()
    private var activeCall: UUID?
    private var activeSlot: DictationSlot?
    private var lastSlot: String?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private(set) var lastMetrics: [String: Double] = [:]
    private(set) var ownership = "Vella runtime unloaded"
    /// The worker that served the latest request (tests, diagnostics).
    var processID: Int32? { lastSlot.flatMap { slots[$0]?.pid } ?? slots.values.lazy.compactMap(\.pid).first }
    var loadedModelIDs: [String] { Array(slots.keys) }
    init(helper: URL? = nil, requestTimeout: TimeInterval = 120, runtime: Runtime? = nil) {
        self.helperOverride = helper
        self.requestTimeout = requestTimeout
        self.runtime = runtime ?? .shared
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleMemoryPressure(critical: self.memoryPressure?.data.contains(.critical) == true)
        }
        pressure.resume()
    }
    deinit { memoryPressure?.cancel() }
    /// Warning: drop MLX caches in idle workers. Critical: stop an in-flight request (its audio stays saved) and shed
    /// all but the first manual model.
    func handleMemoryPressure(critical: Bool) {
        guard !slots.isEmpty else { return }
        if critical {
            for slot in Array(slots.values) where slot.pending != nil {
                finish(slot, .failure(VellaError.message("macOS reported critical memory pressure. Inference stopped; saved audio is retained. Close other applications or use a smaller model.")))
                retire(slot)
            }
            Task { await runtime.shed() }
        } else {
            for slot in slots.values where slot.pending == nil { Task { _ = try? await self.send(slot, ["op": "trim"], timeout: 5) } }
        }
    }
    /// Honors `VELLA_SUPPORT_DIR` (isolated test and QA runs; reported in status).
    nonisolated static let support: URL = {
        if let override = ProcessInfo.processInfo.environment["VELLA_SUPPORT_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella", isDirectory: true)
    }()
    static var configURL: URL { support.appendingPathComponent("config.json") }
    func configuration(requiresModel: Bool = true) throws -> Configuration {
        let url = runtime.configURL
        let config: Configuration
        if FileManager.default.fileExists(atPath: url.path) {
            config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        } else {
            config = Configuration(model: "")
        }
        try config.validate(requiresModel: requiresModel)
        return config
    }
    func workerURL() throws -> URL { try NativeHelper.executable("VellaWorker", override: helperOverride) }

    // MARK: Requests

    func transcribe(_ file: URL, config: Configuration) async throws -> String {
        guard activeCall == nil else { throw VellaError.message("Vella is already processing another segment.") }
        guard !config.model.isEmpty else { throw VellaError.message("Install a model and choose Use first.") }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else {
            throw VellaError.message("Audio exceeds the bounded segment size. Saved audio is retained.")
        }
        let call = UUID(); activeCall = call
        let generation = stopGeneration
        defer { if activeCall == call { activeCall = nil; activeSlot = nil } }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await CalibrationStore.shared.cancelAndWait()
            try checkStartup(generation)
            let ref = runtime.resolve(config.model, mode: .dictation)
            let slot = try await ensureSlot(ref, residency: runtime.residencyForRequest(ref), generation: generation)
            try checkStartup(generation)
            try Task.checkCancellation()
            runtime.pin(ref.id); defer { runtime.unpin(ref.id) }
            activeSlot = slot; lastSlot = ref.id
            let object = try await send(slot, ["audio": file.path, "model": slot.ref.path], timeout: requestTimeout)
            lastMetrics = (object["metrics"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            if let error = object["error"] as? [String: Any] {
                if error["code"] as? String == "no_speech" { return "" } // Legacy worker: empty recognition is success.
                retire(slot)
                throw VellaError.message(error["code"] as? String == "memory"
                    ? "This model needs more available memory. Choose a smaller model; saved audio is retained."
                    : "Local inference failed. Saved audio is retained; try again or choose another model.")
            }
            guard let text = object["text"] as? String else { failProtocol(slot); throw VellaError.message("Vella received an invalid worker response. Saved audio is retained.") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }, onCancel: { [weak self] in
            Task { @MainActor in if self?.activeCall == call { self?.stop() } }
        })
    }

    /// Menu Load / launch set / Reload. Returns once the worker reported the model loaded (and status was written).
    func preload(_ ref: ModelRef, residency: ResidencyClass) async throws {
        guard activeCall == nil else { throw VellaError.message("Finish the current transcription before loading a model.") }
        let generation = stopGeneration
        _ = try await ensureSlot(ref, residency: residency, generation: generation)
    }

    private func ensureSlot(_ ref: ModelRef, residency: ResidencyClass, generation: UUID) async throws -> DictationSlot {
        if let slot = slots[ref.id], slot.process.isRunning, !slot.retiring {
            if slot.ref.path == ref.path { return slot }
            return try await reload(slot, to: ref, residency: residency, generation: generation)
        }
        try await waitForRetired(generation: generation)
        try checkStartup(generation)
        try await runtime.admit(ref)
        try checkStartup(generation)
        return try await launch(ref, residency: residency, generation: generation)
    }
    /// Another precision of a loaded family: admit with the loaded one's memory credited, refuse before unloading
    /// anything, and put the working model back if the new one fails to load.
    private func reload(_ old: DictationSlot, to ref: ModelRef, residency: ResidencyClass, generation: UUID) async throws -> DictationSlot {
        let previous = old.ref
        let previousResidency = runtime.residencyForRequest(previous)
        try await runtime.admit(ref, credit: runtime.reclaim(previous.id))
        await unloadSlot(previous.id)
        do {
            try await waitForRetired(generation: generation)
            try checkStartup(generation)
            return try await launch(ref, residency: previousResidency == .manual ? .manual : residency, generation: generation)
        } catch {
            if let restored = try? await launch(previous, residency: previousResidency, generation: stopGeneration) { _ = restored }
            throw error
        }
    }
    private func launch(_ ref: ModelRef, residency: ResidencyClass, generation: UUID) async throws -> DictationSlot {
        let helper = try workerURL()
        let child = Process(), stdout = Pipe(), stdin = Pipe()
        child.executableURL = helper
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        child.environment = env; child.standardInput = stdin; child.standardOutput = stdout
        // Third-party diagnostics can contain speech; never persist them.
        child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { throw VellaError.message("Vella's native dictation helper could not start. Reinstall the app; saved audio is retained. (\(error.localizedDescription))") }
        let slot = DictationSlot(ref: ref, process: child, input: stdin.fileHandleForWriting)
        slots[ref.id] = slot; lastSlot = ref.id; ownership = "Vella private worker"
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                await self?.receive(data, slot: slot)
            }
            try? reader.close()
            await self?.ended(slot)
        }
        runtime.beginLoading(ref.id)
        do {
            try checkStartup(generation)
            let reply = try await send(slot, ["op": "load", "model": ref.path], timeout: requestTimeout)
            // A legacy worker answers the load line like a transcription; "no_speech" is its success.
            if let error = reply["error"] as? [String: Any], error["code"] as? String != "no_speech" {
                throw VellaError.message(error["code"] as? String == "memory"
                    ? "\(ref.displayName) needs more available memory than macOS could give. Saved audio is retained; choose a smaller model."
                    : "\(ref.displayName) failed to load. Saved audio is retained; try again or choose another model.")
            }
        } catch {
            retire(slot)
            runtime.loadFailed(ref.id, message: (error as? VellaError)?.localizedDescription ?? "\(ref.displayName) did not load.")
            throw error
        }
        runtime.register(ref, residency: residency) { [weak self] in await self?.unloadSlot(ref.id) }
        return slot
    }
    /// Unload one model: its worker exits (memory returns to the system) and the runtime forgets it.
    func unloadSlot(_ id: String) async {
        guard let slot = slots[id] else { runtime.removed(id); return }
        retire(slot)
        let until = ProcessInfo.processInfo.systemUptime + 3
        while slot.process.isRunning, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: Transport

    private func send(_ slot: DictationSlot, _ fields: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard slot.pending == nil else { throw VellaError.message("Vella is already processing another segment.") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            slot.pending = (id, continuation)
            let work = DispatchWorkItem { [weak self, weak slot] in
                guard let self, let slot, slot.pending?.0 == id else { return }
                self.finish(slot, .failure(URLError(.timedOut))); self.retire(slot)
            }
            slot.deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            do {
                var request = fields; request["id"] = id.uuidString
                var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
                guard slot.process.isRunning, !slot.retiring else { throw VellaError.message("Vella's worker disconnected.") }
                try slot.input.write(contentsOf: data)
            } catch { finish(slot, .failure(error)); retire(slot) }
        }
    }
    private func receive(_ data: Data, slot: DictationSlot) {
        guard slots[slot.ref.id] === slot, !slot.retiring else { return }
        slot.buffer.append(data)
        guard slot.buffer.count <= 2_000_000 else { failProtocol(slot); return }
        while let newline = slot.buffer.firstIndex(of: 10) {
            let line = slot.buffer.prefix(upTo: newline); slot.buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { failProtocol(slot); return }
            if object["id"] == nil, let status = object["status"] as? [String: Any] {
                runtime.update(slot.ref.id, worker: status); continue
            }
            guard let id = object["id"] as? String, id == slot.pending?.0.uuidString else { failProtocol(slot); return }
            finish(slot, .success(object))
        }
    }
    private func failProtocol(_ slot: DictationSlot) {
        finish(slot, .failure(VellaError.message("Vella received an invalid worker response. Saved audio is retained.")))
        retire(slot)
    }
    private func ended(_ slot: DictationSlot) {
        guard slots[slot.ref.id] === slot, !slot.retiring else { return }
        finish(slot, .failure(VellaError.message("Vella's inference worker exited. Saved audio is retained.")))
        let busy = activeSlot === slot
        retire(slot, notify: false)
        let code = slot.process.isRunning ? "" : " (code \(slot.process.terminationStatus))"
        if busy { runtime.removed(slot.ref.id) }
        else { runtime.crashed(slot.ref.id, message: "\(slot.ref.displayName)'s worker exited\(code). It loads again when needed.") }
    }
    private func finish(_ slot: DictationSlot, _ result: Result<[String: Any], Error>) {
        slot.deadline?.cancel(); slot.deadline = nil
        guard let callback = slot.pending?.1 else { return }
        slot.pending = nil; callback.resume(with: result)
    }
    /// Close stdin (the worker exits on EOF), SIGTERM, then SIGKILL after 2 s.
    private func retire(_ slot: DictationSlot, notify: Bool = true) {
        guard !slot.retiring else { return }
        slot.retiring = true
        finish(slot, .failure(CancellationError()))
        try? slot.input.close()
        if slots[slot.ref.id] === slot { slots[slot.ref.id] = nil }
        if activeSlot === slot { activeSlot = nil }
        let child = slot.process
        if child.isRunning {
            child.terminate(); retired.append(child)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        retired.removeAll { !$0.isRunning }
        slot.buffer.removeAll(keepingCapacity: false)
        if slots.isEmpty { ownership = "Vella runtime unloaded" }
        if notify { runtime.removed(slot.ref.id) }
    }
    private func checkStartup(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard stopGeneration == generation else { throw CancellationError() }
    }
    private func waitForRetired(generation: UUID? = nil) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while retired.contains(where: { $0.isRunning }) {
            try Task.checkCancellation()
            if let generation { try checkStartup(generation) }
            guard ProcessInfo.processInfo.systemUptime < until else { throw VellaError.message("The previous Vella worker has not exited. Try again.") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        retired.removeAll()
    }
    /// Unload every dictation model and wait for the workers to exit (calibration needs the GPU to itself).
    func releaseAndWait() async throws {
        stop()
        for slot in Array(slots.values) { retire(slot) }
        try await waitForRetired()
    }
    func shutdown() {
        stop()
        for slot in Array(slots.values) { retire(slot) }
        for child in retired where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        retired.removeAll()
    }
    /// Stop the in-flight request or load (its worker is ended; saved audio stays). Idle hot models stay loaded.
    func stop() {
        stopGeneration = UUID()
        for slot in Array(slots.values) where slot.pending != nil { retire(slot) }
    }
}
