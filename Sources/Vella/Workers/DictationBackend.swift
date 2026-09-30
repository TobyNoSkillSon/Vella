import Foundation
import Darwin
import VellaCore
import VellaWire

extension Backend {
    /// A model the worker could not load. For a catalog model that is almost always its files (a truncated or damaged
    /// download): trying again cannot help, getting it again does.
    nonisolated static func loadFailed(_ name: String) -> String {
        "\(name) failed to load: its files may be damaged. Delete it in Models\u{2026} and Get it again."
    }
}

/// The dictation worker exited while a request was in flight (crash, jetsam, kill). The request's audio is intact;
/// `SessionTranscriber` retries that segment once on a fresh worker.
struct WorkerExited: LocalizedError {
    var errorDescription: String? { "Vella's inference worker exited. Saved audio is retained." }
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
    /// The worker acknowledged `load`. Until then the slot exists but must not take a request.
    var loaded = false
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
    private var activeLane: Lane?
    private var activeSlot: DictationSlot?
    /// Who asked for a transcription. Dictation has priority: it waits for an in-flight API segment instead of failing,
    /// and API work starts a segment only when no dictation is active (`APITranscriber`).
    enum Lane { case dictation, api }
    /// A transcription request is in flight.
    var isBusy: Bool { activeCall != nil }
    /// An API request never loads a model inside the request lane, where a dictation would wait for the whole load:
    /// `transcribe` on `.api` throws this when its model is not loaded and ready, and the caller loads it with
    /// `preload` (outside the lane) first.
    struct ModelNotReady: Error {}
    /// This model's worker has these files loaded and can take a request now, without a load.
    func isReady(_ ref: ModelRef) -> Bool {
        guard let slot = slots[ref.id] else { return false }
        return slot.loaded && !slot.retiring && slot.process.isRunning && slot.ref.path == ref.path && slot.ref.recipe == ref.recipe
    }
    private var lastSlot: String?
    private(set) var lastMetrics: [String: Double] = [:]
    private(set) var ownership = "Vella runtime unloaded"
    /// The worker that served the latest request (tests, diagnostics).
    var processID: Int32? { lastSlot.flatMap { slots[$0]?.pid } ?? slots.values.lazy.compactMap(\.pid).first }
    var loadedModelIDs: [String] { Array(slots.keys) }
    init(helper: URL? = nil, requestTimeout: TimeInterval = 120, runtime: Runtime? = nil) {
        self.helperOverride = helper
        self.requestTimeout = requestTimeout
        self.runtime = runtime ?? .shared
    }
    /// Called by the runtime's memory-pressure source (one policy for both modes). Never stops an in-flight request,
    /// load or live stream (the models serving them are pinned). Warning: idle dictation workers drop their MLX caches.
    /// Critical: unload idle, unpinned models of either mode (on-demand first, keeping the first manual one), then
    /// idle survivors drop their caches.
    func handleMemoryPressure(critical: Bool) {
        Task {
            if critical { await runtime.shed() }
            for slot in Array(slots.values) where slot.pending == nil && !slot.retiring {
                _ = try? await send(slot, ["op": "trim"], timeout: 5)
            }
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

    func transcribe(_ file: URL, config: Configuration, lane: Lane = .dictation) async throws -> String {
        if activeCall != nil, lane == .dictation, activeLane == .api {
            // One API segment (≤ 25 s of audio) is in flight: wait for it rather than fail the dictation.
            let until = ProcessInfo.processInfo.systemUptime + requestTimeout + 5
            while activeCall != nil, ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        guard activeCall == nil else { throw VellaError.message("Vella is already processing another segment.") }
        guard !config.model.isEmpty else { throw VellaError.message("Install a model and choose Use first.") }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else {
            throw VellaError.message("Audio exceeds the bounded segment size. Saved audio is retained.")
        }
        let call = UUID(); activeCall = call; activeLane = lane
        let generation = stopGeneration
        defer { if activeCall == call { activeCall = nil; activeLane = nil; activeSlot = nil } }
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                try await CalibrationStore.shared.cancelAndWait()
                try checkStartup(generation)
                let ref = runtime.resolve(config.model, mode: .dictation)
                if lane == .api, !isReady(ref) { throw ModelNotReady() }
                let slot = try await ensureSlot(ref, residency: runtime.residencyForRequest(ref), generation: generation)
                try checkStartup(generation)
                try Task.checkCancellation()
                runtime.pin(ref.id); defer { runtime.unpin(ref.id) }
                activeSlot = slot; lastSlot = ref.id
                let object = try await send(slot, ["audio": file.path, "model": slot.ref.path], timeout: requestTimeout)
                lastMetrics = (object["metrics"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
                if let error = object["error"] as? [String: Any] {
                    retire(slot)
                    throw VellaError.message(
                        error["code"] as? String == "memory"
                            ? "This model needs more available memory. Choose a smaller model; saved audio is retained."
                            : "Local inference failed. Saved audio is retained; try again or choose another model.")
                }
                guard let text = object["text"] as? String else {
                    failProtocol(slot); throw VellaError.message("Vella received an invalid worker response. Saved audio is retained.")
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            onCancel: { [weak self] in
                Task { @MainActor in if self?.activeCall == call { self?.stop() } }
            })
    }

    /// A family's residency at one moment: its loaded model and class, its launch-set entry, and the count of the
    /// user's changes to it so far.
    struct FamilyResidency {
        let id: String
        let loaded: ModelRef?
        let residency: ResidencyClass?
        let launchEntry: ModelRef?
        let userChanges: Int
    }
    func residency(of id: String) -> FamilyResidency {
        FamilyResidency(
            id: id, loaded: runtime.loadedRef(id), residency: runtime.loadedResidency(id),
            launchEntry: runtime.settings.launchSet.first { $0.id == id }, userChanges: runtime.userChangeCount(id))
    }
    /// After `used`, another precision of a family, served a request in place of what `before` recorded (one worker
    /// per family): reload the recorded precision if it was loaded, else unload `used`, and put the launch-set entry
    /// back. Nothing is loaded that was not loaded before. A failed reload keeps `used` and reports the error in status.
    /// Only while the family is as the user left it: once they loaded, reloaded, unloaded or deleted it since `before`,
    /// or `unchanged` (their selection) no longer holds, nothing is put back, before the reload or after it.
    func restore(_ before: FamilyResidency, after used: String, while unchanged: () -> Bool = { true }) async {
        guard runtime.userChangeCount(before.id) == before.userChanges, unchanged() else { return }
        if let now = runtime.loadedRef(before.id), now.path == used {
            if let loaded = before.loaded {
                if loaded.path != used { try? await preload(loaded, residency: before.residency ?? .onDemand) }
            } else {
                await unloadSlot(before.id)
                runtime.removed(before.id)
            }
        }
        guard runtime.userChangeCount(before.id) == before.userChanges, unchanged() else { return }
        runtime.restoreLaunchEntry(before.id, to: before.launchEntry)
    }

    /// Menu Load / launch set / Reload. Returns once the worker reported the model loaded (and status was written).
    func preload(_ ref: ModelRef, residency: ResidencyClass) async throws {
        guard activeCall == nil else { throw VellaError.message("Finish the current transcription before loading a model.") }
        let generation = stopGeneration
        _ = try await ensureSlot(ref, residency: residency, generation: generation)
    }

    private func ensureSlot(_ ref: ModelRef, residency: ResidencyClass, generation: UUID) async throws -> DictationSlot {
        if let slot = slots[ref.id], slot.process.isRunning, !slot.retiring {
            // Same files and recipe: nothing to do. Another Standard/Exact/Fast recipe is a reload (a new worker).
            if slot.ref.path == ref.path, slot.ref.recipe == ref.recipe {
                if !slot.loaded { try await awaitLoaded(slot, generation: generation) }
                return slot
            }
            return try await reload(slot, to: ref, residency: residency, generation: generation)
        }
        try await waitForRetired(generation: generation)
        try checkStartup(generation)
        try await runtime.admit(ref)
        try checkStartup(generation)
        return try await launch(ref, residency: residency, generation: generation)
    }
    /// A request (or another Load) that finds its model still loading (a manual Load or the launch set started it)
    /// waits for that load instead of failing with "already processing another segment". A failed load fails it.
    private func awaitLoaded(_ slot: DictationSlot, generation: UUID) async throws {
        let until = ProcessInfo.processInfo.systemUptime + requestTimeout + 5
        while !slot.loaded {
            try checkStartup(generation)
            guard !slot.retiring, slot.process.isRunning else {
                throw VellaError.message("\(slot.ref.displayName) did not finish loading. Saved audio is retained; try again.")
            }
            guard ProcessInfo.processInfo.systemUptime < until else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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
        child.environment = WorkerProcess.environment(recipe: ref.recipe); child.standardInput = stdin; child.standardOutput = stdout
        // Third-party diagnostics can contain speech; never persist them.
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            throw VellaError.message("Vella's native dictation helper could not start. Reinstall the app; saved audio is retained. (\(error.localizedDescription))")
        }
        let slot = DictationSlot(ref: ref, process: child, input: stdin.fileHandleForWriting)
        slots[ref.id] = slot; lastSlot = ref.id; ownership = "Vella private worker"
        WorkerProcess.forward(
            stdout.fileHandleForReading, to: { [weak self] data in await self?.receive(data, slot: slot) },
            ended: { [weak self] in await self?.ended(slot) })
        runtime.beginLoading(ref.id)
        do {
            try checkStartup(generation)
            let reply = try await send(slot, ["op": "load", "model": ref.path], timeout: requestTimeout)
            if let error = reply["error"] as? [String: Any] {
                throw VellaError.message(
                    error["code"] as? String == "memory"
                        ? "\(ref.displayName) needs more available memory than macOS could give. Saved audio is retained; choose a smaller model."
                        : Self.loadFailed(ref.displayName) + " Saved audio is retained.")
            }
        } catch {
            retire(slot)
            runtime.loadFailed(ref.id, message: (error as? VellaError)?.localizedDescription ?? "\(ref.displayName) did not load.")
            throw error
        }
        slot.loaded = true
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
                runtime.update(slot.ref.id, worker: HelperStatus(json: status)); continue
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
        let busy = activeSlot === slot
        let pid = slot.process.processIdentifier
        let runtime = self.runtime, id = slot.ref.id, process = slot.process
        // The waiting request resumes only after this main-actor turn, so the dead worker is fully forgotten (runtime
        // entry included) before its automatic retry can register a replacement for the same model; a late removal
        // must never unregister that replacement.
        finish(slot, .failure(WorkerExited()))
        retire(slot, notify: busy)
        Task { @MainActor [weak self] in
            let until = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(nanoseconds: 20_000_000) }
            let status = process.isRunning ? -1 : process.terminationStatus
            let reason = process.isRunning ? Process.TerminationReason.exit : process.terminationReason
            runtime.log("\(id): worker pid \(pid) exited (\(reason == .uncaughtSignal ? "signal" : "code") \(status))")
            let summary = workerExitSummary(status: status, reason: reason, logTail: logTail(runtime.logURL))
            // An idle crash follows the restart policy, unless a replacement already took over this model.
            if !busy, self?.slots[id] == nil { runtime.crashed(id, message: summary) }
        }
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
