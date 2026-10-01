import Foundation
import Darwin
import VellaCore
import VellaWire

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
        var worker: HelperStatus?
        var unload: @MainActor () async -> Void
        var timer: DispatchWorkItem?
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var pinned: [String: Int] = [:]
    private var pendingWorker: [String: HelperStatus] = [:]
    private var evictions: [Eviction] = []
    private var refused: Refusal?
    private var loading: String?
    private var error: String?
    private var gpu: GPUStatus?
    private var workerHooks: [String: String] = [:]
    private var restarts: [String: RestartPolicy] = [:]
    private var registrations: [String: UUID] = [:]
    /// A restarted worker counts as recovered (restart budget reset) once it stays up this long or serves a request.
    var stableSeconds: Double = 60
    /// App-written lifecycle lines only (exits, restarts). Worker output is never persisted: it can contain speech.
    var logURL: URL { support.appendingPathComponent("worker.log") }
    func log(_ line: String) {
        let url = logURL
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }

    init(support: URL = Backend.support, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.support = support; self.environment = environment
        probe = MemoryProbe(environment: environment)
        minuteSeconds = environment["VELLA_TEST_MINUTE_SECONDS"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 60
        let config = (try? Data(contentsOf: support.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        settings = config?.residency ?? ResidencySettings()
        // One memory-pressure policy for both modes.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleMemoryPressure(critical: self.memoryPressure?.data.contains(.critical) == true)
        }
        pressure.resume()
    }
    deinit { memoryPressure?.cancel() }
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// macOS memory pressure, for the loaded models of both modes. Critical: unload idle, unpinned models (on-demand
    /// first, keeping the first manual one); warning and critical: idle dictation workers drop their MLX caches.
    /// Pinned models are never unloaded: an in-flight dictation request, a load, or a live stream continues.
    func handleMemoryPressure(critical: Bool) {
        if let dictation { dictation.handleMemoryPressure(critical: critical) } else if critical { Task { await shed() } }
    }

    /// App launch: publish an empty status (no stale models), keep config.json's residency explicit, then load the
    /// launch set (manual loads only; empty on a fresh install, so nothing loads or downloads).
    func start(loadLaunchSet: Bool = true) {
        // Orphaned workers from an earlier app instance (parent pid 1), matched by executable path, never command line.
        if let bundle = Bundle.main.executableURL?.deletingLastPathComponent() {
            _ = StraySweep.sweep(executables: ["VellaWorker", "VellaStreamingWorker", "VellaModelTool"].map { bundle.appendingPathComponent($0) }) { _ in }
        }
        try? FileManager.default.removeItem(at: statusURL)
        if !FileManager.default.fileExists(atPath: configURL.path) { persistSettings() }
        writeStatus()
        guard loadLaunchSet, !settings.launchSet.isEmpty else { return }
        Task { await self.loadLaunchSet() }
    }
    func loadLaunchSet() async {
        for stored in settings.launchSet where entries[stored.id] == nil {
            // The same resolution as Load and on-demand dictation: the catalog's current recipe and files.
            guard let ref = launchRef(stored) else {
                error = "\(stored.displayName) in the launch set no longer matches the catalog's recipe at \(stored.precision). Load it again in Models."
                writeStatus(); continue
            }
            guard FileManager.default.fileExists(atPath: ref.path) else {
                error = "\(ref.displayName) is in the launch set but its files are missing. Get it again or unload it."; writeStatus(); continue
            }
            do { try await load(ref) } catch { /* recorded in status (refused / error) */  }
        }
    }
    /// A launch-set entry as on-demand dictation resolves its path; nil when it names a catalog precision its files no
    /// longer run (e.g. an imported uniform checkpoint recorded for a tier that is now a mixed recipe).
    func launchRef(_ stored: ModelRef) -> ModelRef? {
        guard let resolver else { return stored }
        if let ref = resolver(stored.path, stored.mode) { return ref }
        return stored.precision.isEmpty ? stored : nil
    }

    // MARK: Identity

    func resolve(_ path: String, mode: RecognitionMode) -> ModelRef {
        if let ref = resolver?(path, mode) { return ref }
        // Without a catalog identity, a recorded launch-set entry names it only when it claims no catalog precision.
        if let ref = settings.launchSet.first(where: { $0.path == path && (resolver == nil || $0.precision.isEmpty) }) { return ref }
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
    func loadedResidency(_ id: String) -> ResidencyClass? { entries[id]?.residency }
    /// Puts a family's launch-set entry back as it was (`nil`: none), after another precision of it was loaded
    /// temporarily and registration replaced the entry.
    func restoreLaunchEntry(_ id: String, to ref: ModelRef?) {
        let before = settings.launchSet
        if let ref { settings.join(ref) } else { settings.leave(id) }
        if settings.launchSet != before { persistSettings() }
        writeStatus()
    }
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
        userChanged(id); defer { userChanged(id) }
        if let entry = entries[id] { await entry.unload() }
        settings.leave(id); persistSettings(); writeStatus()
    }
    /// Before Delete: unload the model only if these exact files are the loaded ones, and return once its worker has
    /// exited. The launch set is left alone until the deletion succeeded (`deleted(path:)`). Returns what was loaded.
    func unloadForDeletion(_ id: String, path: String) async -> (ref: ModelRef, residency: ResidencyClass)? {
        guard let entry = entries[id], sameFiles(entry.ref.path, path) else { return nil }
        await entry.unload()
        removed(id)
        return (entry.ref, entry.residency)
    }
    /// After a successful Delete: drop the launch-set entry for exactly these files, whether the model was loaded or
    /// already evicted; an entry for another precision of the family is kept.
    func deleted(path: String) {
        let before = settings.launchSet.count
        settings.launchSet.removeAll { sameFiles($0.path, path) }
        if settings.launchSet.count != before { persistSettings() }
        writeStatus()
    }
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
        if let footprint = entry.worker?.memory?.footprintMB, footprint > 0 { return footprint }
        return memoryEstimateMB(entry.ref)
    }
    private var loadedReclaimMB: Double { entries.values.reduce(0) { $0 + reclaimMB($1) } }
    /// What unloading this loaded model would free (used as a reload credit).
    func reclaim(_ id: String) -> Double { entries[id].map(reclaimMB) ?? 0 }
    /// Fit in free memory: admit `ref`, unloading idle models first when needed (on-demand LRU first, never a busy
    /// one or one in `together`), or throw the refusal with the numbers and working remedies. Nothing is unloaded
    /// when unloading everything possible would still not fit. Allow swap admits everything.
    /// `replacing`: a loaded model this load replaces (the one streaming model, whichever family or precision). The
    /// caller unloads it only after admission, so its memory is credited and it is never chosen as a victim.
    func admit(_ ref: ModelRef, credit: Double = 0, together: [String] = [], replacing: String? = nil) async throws {
        let credit = credit + (replacing.flatMap { entries[$0] }.map(reclaimMB) ?? 0)
        func infos() -> [LoadedModelInfo] {
            order.compactMap { id in
                guard let entry = entries[id], id != ref.id, id != replacing, (pinned[id] ?? 0) == 0 else { return nil }
                return LoadedModelInfo(id: id, name: entry.ref.displayName, residency: entry.residency, lastUsed: entry.lastUsed, reclaimMB: reclaimMB(entry))
            }
        }
        let names = together.map { entries[$0]?.ref.displayName ?? $0 }
        var decision = planAdmission(
            ref, loaded: infos(), rawAvailableMB: probe.rawAvailableMB(loadedMB: loadedReclaimMB),
            credit: credit, together: together, allowSwap: settings.allowSwap)
        if case .admit(let victims, let need, let free) = decision, !victims.isEmpty {
            for victim in victims {
                await evict(victim, reason: "memory: made room for \(ref.displayWithPrecision) (needs ~\(gigabytes(need)) GB; ~\(gigabytes(free)) GB was free without swapping)")
            }
            // Re-check against the probe: estimates are not measurements.
            decision = planAdmission(
                ref, loaded: infos(), rawAvailableMB: probe.rawAvailableMB(loadedMB: loadedReclaimMB),
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
        entries[ref.id] = Entry(
            ref: ref, residency: previous?.residency == .manual ? .manual : residency, lastUsed: now,
            worker: pendingWorker.removeValue(forKey: ref.id) ?? previous?.worker, unload: unload, timer: previous?.timer)
        if !order.contains(ref.id) { order.append(ref.id) }
        if loading == ref.id { loading = nil }
        refused = nil; error = nil
        let registration = UUID(); registrations[ref.id] = registration
        DispatchQueue.main.asyncAfter(deadline: .now() + stableSeconds) { [weak self] in
            guard let self, self.registrations[ref.id] == registration, self.entries[ref.id] != nil else { return }
            self.restarts[ref.id]?.reset()
        }
        if entries[ref.id]?.residency == .manual { settings.join(ref); persistSettings() }
        schedule(ref.id)
        writeStatus()
    }
    /// A status line pushed by the model's worker.
    func update(_ id: String, worker: HelperStatus) {
        if let chip = worker.gpu.map({ GPUStatus(chip: $0.chip, family: $0.family) }) { gpu = chip }
        workerHooks.merge(worker.testHooks) { $1 }
        if entries[id] != nil { entries[id]?.worker = worker } else { pendingWorker[id] = worker }
        writeStatus()
    }
    func promote(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.residency = .manual; entries[id] = entry
        settings.join(entry.ref); persistSettings(); schedule(id); writeStatus()
    }
    /// A pinned model has no idle timer: it cannot idle out while it serves, and an expired deadline must
    /// not re-arm itself every run-loop pass. Unpin re-arms from the new last use.
    func pin(_ id: String) {
        pinned[id, default: 0] += 1
        entries[id]?.timer?.cancel(); entries[id]?.timer = nil
    }
    /// Idle-timer callbacks that ran (tests: no churn while pinned).
    private(set) var idleTimerFirings = 0
    func unpin(_ id: String) {
        pinned[id] = max(0, (pinned[id] ?? 1) - 1)
        touch(id)
    }
    /// Keeps a model out of eviction (and its idle timer paused) without counting as a use: the dictation model while
    /// an API job loads and runs another model. `unshield` re-arms the timer from the unchanged last use.
    func shield(_ id: String) {
        pinned[id, default: 0] += 1
        entries[id]?.timer?.cancel(); entries[id]?.timer = nil
    }
    func unshield(_ id: String) {
        pinned[id] = max(0, (pinned[id] ?? 1) - 1)
        schedule(id)
    }
    /// Load-then-select transactions in flight (the table's Load/Reload). Until one ends, the loaded precision and
    /// config.json's selection may disagree, so API work waits instead of acting on either.
    private(set) var selectionsInFlight = 0
    func beginSelection() { selectionsInFlight += 1 }
    func endSelection() { selectionsInFlight = max(0, selectionsInFlight - 1) }
    /// Per family, how many of the user's own changes to it (Load, Reload, Unload, Delete) have begun or ended. Work
    /// that temporarily replaced a family's precision compares this count with the one it recorded first, and puts
    /// nothing back once the user changed the family in the meantime: the user's later choice wins.
    private var userChanges: [String: Int] = [:]
    func userChanged(_ id: String) { userChanges[id, default: 0] &+= 1 }
    func userChangeCount(_ id: String) -> Int { userChanges[id] ?? 0 }
    /// The API's loopback port once it listens (published in the status file with the API version).
    var apiPort: Int? { didSet { writeStatus() } }
    var apiToken: String?
    func touch(_ id: String) {
        guard entries[id] != nil else { return }
        restarts[id]?.reset() // served a request: recovered
        entries[id]?.lastUsed = Date().timeIntervalSince1970
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
        error = message; writeStatus() // the exit line itself was logged by the backend; the summary goes to status only
        guard let entry, entry.residency == .manual else { return }
        var policy = restarts[id] ?? RestartPolicy()
        guard let delay = policy.nextDelay() else {
            restarts[id] = policy
            error = message + " Stopped restarting \(entry.ref.displayName) after \(RestartPolicy.delays.count) attempts; Load it again in Models…"
            log("\(id): stopped restarting after \(RestartPolicy.delays.count) attempts")
            writeStatus(); return
        }
        restarts[id] = policy
        log("\(id): restarting in \(Int(delay)) s (attempt \(policy.failures))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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
        if (pinned[id] ?? 0) == 0,
            let deadline = unloadDeadline(lastUsed: entry.lastUsed, residency: entry.residency, settings: settings, minuteSeconds: minuteSeconds)
        {
            let minutes = settings.idleMinutes(entry.residency), residency = entry.residency
            let work = DispatchWorkItem { [weak self] in
                guard let self, let current = self.entries[id] else { return }
                self.idleTimerFirings += 1
                if (self.pinned[id] ?? 0) > 0 { return } // unpin re-arms from the new last use
                if Date().timeIntervalSince1970 + 0.001 < deadline || current.residency != residency { self.schedule(id); return }
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
            model.pid = entry.worker?.pid.map { Int32(truncatingIfNeeded: $0) }
            model.engine = entry.worker?.engine
            model.engine_reason = entry.worker?.engineReason
            model.optimizations = entry.worker?.optimizations
            model.residency = entry.residency.rawValue
            model.keep_hot_min = settings.idleMinutes(entry.residency)
            model.last_used = entry.lastUsed
            model.unloads_at = unloadDeadline(lastUsed: entry.lastUsed, residency: entry.residency, settings: settings, minuteSeconds: minuteSeconds)
            model.load_s = entry.worker?.loadSeconds
            model.memory_mb = entry.worker?.memory?.footprintMB
            model.worker_version = entry.worker?.version
            model.selection = entry.ref.selection
            next.models[id] = model
        }
        next.loading = loading
        next.error = error
        next.memory = MemoryStatus(
            available_mb: probe.availableMB(loadedMB: loadedReclaimMB), ram_mb: probe.totalMB,
            workers_mb: entries.values.compactMap { $0.worker?.memory?.footprintMB }.reduce(0, +))
        next.settings = StatusSettings(settings)
        next.launch_set = settings.launchSet.map(\.id)
        next.evictions = evictions
        next.refused = refused
        next.gpu = gpu
        next.test_hooks = activeTestHooks(environment).merging(workerHooks) { $1 }
        if let apiPort { next.api = vellaAPIVersion; next.api_port = apiPort; next.api_token = apiToken }
        status = next
        try? next.write(to: statusURL)
    }
}
