import Foundation
import Darwin
import VellaCore

/// Capture never waits for inference. Overflow is an explicit recoverable failure,
/// not a dropped frame: the independent PCM journal remains authoritative.
final class StreamingPCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var closed = false
    private var failed = false
    private var frames = 0
    let capacity: Int
    init(capacity: Int = 2 * 1024 * 1024) { self.capacity = capacity }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !failed else { return }
        guard data.count % 4 == 0, bytes.count + data.count <= capacity else {
            failed = true; bytes.removeAll(); return
        }
        frames += data.count / 4; bytes.append(data)
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func abort() { lock.lock(); closed = true; failed = true; bytes.removeAll(); lock.unlock() }
    var totalFrames: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var isDrained: Bool { lock.lock(); defer { lock.unlock() }; return closed && bytes.isEmpty && !failed }
    func take() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw VellaError.message("Streaming could not keep up. Saved audio is retained; retry it after finishing.") }
        guard bytes.count >= 6400 || (closed && !bytes.isEmpty) else { return nil }
        let count = min(6400, bytes.count), result = Data(bytes.prefix(min(6400, bytes.count)))
        bytes.removeFirst(count); return result
    }
}

/// One owned, offline, stateful worker. Each request is acknowledged before the
/// next frame is sent. UUIDs, frame accounting and deadlines fail closed.
/// After a clean finish the worker keeps its model loaded for the next session (Keep Hot);
/// any failure ends the process.
@MainActor final class StreamingBackend {
    private struct Reply: Decodable {
        let id: UUID
        let frames: Int?
        let committed: String?
        let partial: String?
        let done: Bool?
        let error: String?
        let incomplete: Bool?
        let loaded: Bool?
    }
    private let helperOverride: URL?
    let runtime: Runtime
    /// The model the running worker holds, once loaded.
    private(set) var hotRef: ModelRef?
    private var sessionActive = false
    private let timeout: TimeInterval
    private var process: Process?
    private var retired: [Process] = []
    private var input: FileHandle?
    private var epoch = UUID()
    private var buffer = Data()
    private var pending: (UUID, CheckedContinuation<Reply, Error>)?
    private var deadline: DispatchWorkItem?
    private var receivedDone = false
    private var incomplete = false
    var hasIncompleteExecution: Bool { incomplete }
    private(set) var frames = 0
    private(set) var committed = ""
    private(set) var partial = ""
    var text: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }
    var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    var onUpdate: (() throws -> Void)?
    // Fixed-size worker deltas: the live path never rescans all earlier speech.
    var onEvent: ((String, String, Bool) throws -> Void)?
    init(helper: URL? = nil, timeout: TimeInterval = 120, runtime: Runtime? = nil) {
        // Memory pressure is the runtime's single policy: a live stream is pinned and never stopped;
        // an idle hot streaming model is shed like any other idle model.
        self.helperOverride = helper; self.timeout = timeout; self.runtime = runtime ?? .shared
    }
    deinit { if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    /// Bumped by stop(), releaseAndWait() and shutdown(): a start/preload that began before it must not go on to
    /// launch or register a worker.
    private var cancelToken = UUID()
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard cancelToken == token else { throw CancellationError() }
    }
    func start(config: Configuration) async throws {
        if sessionActive || pending != nil || hotRef == nil { stop() }
        resetTranscript(); receivedDone = false
        let token = cancelToken
        guard config.mode == .streaming, !config.model.isEmpty else { throw VellaError.message("Choose a dedicated streaming model first.") }
        let ref = runtime.resolve(config.model, mode: .streaming)
        try await ensureLoaded(ref, residency: runtime.residencyForRequest(ref), token: token)
        try check(token)
        sessionActive = true
        runtime.pin(ref.id)
        _ = try await exchange(["op": "start", "model": ref.path])
    }
    /// Menu Load / launch set: load the streaming model without starting a session.
    func preload(_ ref: ModelRef, residency: ResidencyClass) async throws {
        guard !sessionActive, pending == nil else { throw VellaError.message("Finish streaming before loading another streaming model.") }
        try await ensureLoaded(ref, residency: residency, token: cancelToken)
    }
    /// The one path that makes `ref` the hot streaming model, for start and preload alike. One streaming
    /// model at a time: admission first (the model it replaces is credited, never chosen as a victim), then the old
    /// child is retired and awaited, then a new child is launched under a fresh epoch and asked to `load`. A reply,
    /// status line or EOF from an earlier child carries an old epoch and is ignored.
    private func ensureLoaded(_ ref: ModelRef, residency: ResidencyClass, token: UUID) async throws {
        if hotRef?.path == ref.path, loadingRef == nil, process?.isRunning == true { return }
        let previous = process?.isRunning == true && loadingRef == nil ? hotRef : nil
        let previousResidency = previous.map { runtime.residencyForRequest($0) } ?? .onDemand
        try await waitForRetired()
        try check(token)
        // Refused → nothing was unloaded.
        try await runtime.admit(ref, replacing: previous?.id)
        try check(token)
        if process != nil || loadingRef != nil || hotRef != nil { retire() }
        do {
            try await waitForRetired()
            try check(token)
            try launch(ref, residency: residency)
            _ = try await exchange(["op": "load", "model": ref.path])
            try check(token)
        } catch {
            // The new model failed to load: put the working one back with its residency (as dictation's reload does).
            // Never after a stop/release/shutdown, including one that arrives while the restore waits or loads:
            // cancellation is re-checked after every suspension, and a worker restored across a
            // cancellation is retired again.
            if let previous, !(error is CancellationError), cancelToken == token {
                do {
                    try await waitForRetired()
                    try check(token)
                    try launch(previous, residency: previousResidency)
                    _ = try await exchange(["op": "load", "model": previous.path])
                    try check(token)
                } catch is CancellationError {
                    if process != nil || loadingRef != nil || hotRef != nil { retire() }
                    try? await waitForRetired()
                } catch { runtime.log("\(previous.id): could not restore the streaming model after a failed load") }
            }
            throw error
        }
    }
    /// Start a worker for `ref`. The caller has retired any previous child; this one gets its own epoch.
    private func launch(_ ref: ModelRef, residency: ResidencyClass) throws {
        guard process == nil else { throw VellaError.message("Previous streaming worker has not exited. Try again.") }
        let executable = try workerURL()
        let child = Process(), stdout = Pipe(), stdin = Pipe()
        child.executableURL = executable
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        child.environment = env; child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        frames = 0; committed = ""; partial = ""; buffer.removeAll(); receivedDone = false
        do { try child.run() }
        catch { throw VellaError.message("Vella's native streaming helper could not start. Reinstall the app; saved audio is retained. (\(error.localizedDescription))") }
        let generation = UUID()
        epoch = generation
        process = child; input = stdin.fileHandleForWriting
        Task.detached { [weak self] in
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                await self?.receive(data, generation: generation)
            }
            try? stdout.fileHandleForReading.close()
            await self?.ended(generation: generation)
        }
        loadingRef = ref; loadingResidency = residency
        runtime.beginLoading(ref.id)
    }
    private var loadingRef: ModelRef?
    private var loadingResidency = ResidencyClass.onDemand
    /// The first acknowledged `start`/`load` means the model is loaded.
    private func confirmLoaded() {
        guard let ref = loadingRef else { return }
        loadingRef = nil; hotRef = ref
        runtime.register(ref, residency: loadingResidency) { [weak self] in await self?.unloadHot(ref.id) }
    }
    /// The runtime's unload for model `id`; a no-op when this backend has since moved on to another model.
    func unloadHot(_ id: String? = nil) async {
        guard process != nil, id == nil || hotRef?.id == id || loadingRef?.id == id else { return }
        retire()
        try? await waitForRetired()
    }
    func workerURL() throws -> URL { try NativeHelper.executable("VellaStreamingWorker", override: helperOverride) }
    func feed(_ pcm: Data) async throws {
        guard !pcm.isEmpty, pcm.count <= 6400, pcm.count % 4 == 0 else { throw VellaError.message("Invalid streaming audio packet.") }
        frames += pcm.count / 4
        _ = try await exchange(["op": "audio", "pcm": pcm.base64EncodedString()])
    }
    func finish(expectedFrames: Int) async throws -> String {
        let generation = epoch
        do {
            let text = try await finishSession(expectedFrames: expectedFrames, generation: generation)
            // Clean finish: the worker stays up with the model loaded.
            if epoch == generation { endSession() }
            return text
        } catch {
            if epoch == generation { stop() }
            throw error
        }
    }
    private func endSession() {
        guard sessionActive else { return }
        // The terminal reply is consumed: from now on an EOF is an idle hot worker dying.
        sessionActive = false; receivedDone = false
        if let id = hotRef?.id { runtime.unpin(id) }
    }
    private func finishSession(expectedFrames: Int, generation: UUID) async throws -> String {
        guard frames == expectedFrames else { throw VellaError.message("Streaming did not receive all saved audio. Audio is retained; automatic replay is disabled.") }
        let result = try await exchange(["op": "finish"])
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard result.done == true, partial.isEmpty else { throw VellaError.message("Streaming did not finalize all words. Saved audio is retained.") }
        // Retain fail-closed handling for explicit legacy protocol failures,
        // never infer failure from successful empty model output.
        guard !incomplete else { throw VellaError.message("Streaming worker reported an incomplete result. Saved audio is retained.") }
        return committed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func exchange(_ fields: [String: Any]) async throws -> Reply {
        guard pending == nil else { throw VellaError.message("A streaming request is already in progress.") }
        let id = UUID(), generation = epoch
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation)
                let work = DispatchWorkItem { [weak self] in
                    guard self?.pending?.0 == id else { return }; self?.fail(URLError(.timedOut))
                }
                deadline = work; DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
                do {
                    guard let input, process?.isRunning == true else { throw VellaError.message("Streaming worker disconnected. Saved audio is retained.") }
                    var request = fields; request["id"] = id.uuidString
                    var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
                    try input.write(contentsOf: data)
                } catch { fail(error) }
            }
        }, onCancel: { [weak self] in Task { @MainActor in if self?.epoch == generation { self?.stop() } } })
    }
    private func receive(_ data: Data, generation: UUID) {
        guard epoch == generation else { return }
        buffer.append(data)
        guard buffer.count <= 65_536 else { fail(VellaError.message("Streaming response exceeded its safety limit.")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] == nil,
               let status = object["status"] as? [String: Any] {
                if let id = (loadingRef ?? hotRef)?.id { runtime.update(id, worker: status) }
                continue
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line), reply.id == pending?.0 else {
                fail(VellaError.message("Invalid streaming response. Saved audio is retained.")); return
            }
            if let error = reply.error {
                if let ref = loadingRef { loadingRef = nil; runtime.loadFailed(ref.id, message: "\(ref.displayName) failed to load.") }
                fail(VellaError.message(error)); return
            }
            confirmLoaded()
            guard reply.frames == frames else { fail(VellaError.message("Streaming audio acknowledgement mismatch. Saved audio is retained.")); return }
            let next = (reply.committed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let newPartial = reply.partial ?? ""
            let changed = !next.isEmpty || partial != newPartial
            let newlyIncomplete = !incomplete && reply.incomplete == true
            if !next.isEmpty { committed += (committed.isEmpty ? "" : " ") + next }
            partial = newPartial
            if reply.done == true { receivedDone = true }
            incomplete = incomplete || reply.incomplete == true
            do {
                if changed || newlyIncomplete { try onEvent?(next, newPartial, incomplete) }
                if changed { try onUpdate?() }
            }
            catch { fail(error); return }
            resolve(.success(reply))
        }
    }
    private func resolve(_ result: Result<Reply, Error>) {
        deadline?.cancel(); deadline = nil
        let callback = pending?.1; pending = nil; callback?.resume(with: result)
    }
    private func ended(generation: UUID) {
        guard epoch == generation else { return }
        // A valid terminal reply may be followed by EOF before its awaiting Task
        // resumes. Keep its epoch until finish() consumes that reply. Only that short window counts: once finish()
        // has consumed the reply (the session ended), an EOF is an idle hot worker exiting and follows the restart
        // policy below.
        if receivedDone && pending == nil && sessionActive {
            // Legacy worker that exits after finish: the result stands, the model is no longer hot.
            let id = hotRef?.id; hotRef = nil; process = nil
            if let id { runtime.removed(id) }
            return
        }
        if !sessionActive, pending == nil, let ref = hotRef {
            hotRef = nil; process = nil
            runtime.log("\(ref.id): streaming worker exited while idle")
            runtime.crashed(ref.id, message: "\(ref.displayName)'s streaming worker exited. It loads again when needed.")
            return
        }
        fail(VellaError.message("Streaming worker exited. Saved audio is retained."))
    }
    private func fail(_ error: Error) { resolve(.failure(error)); retire() }
    private func retire() {
        if let ref = loadingRef { loadingRef = nil; runtime.loadFailed(ref.id, message: "\(ref.displayName) did not finish loading.") }
        if sessionActive, let id = hotRef?.id { runtime.unpin(id) }
        sessionActive = false
        if let id = hotRef?.id { hotRef = nil; runtime.removed(id) }
        epoch = UUID(); try? input?.close(); input = nil; buffer.removeAll()
        if let child = process, child.isRunning {
            child.terminate(); retired.append(child)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        process = nil; retired.removeAll { !$0.isRunning }
    }
    private func waitForRetired() async throws {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while retired.contains(where: { $0.isRunning }) {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < until else { throw VellaError.message("Previous streaming worker has not exited. Try again.") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        retired.removeAll()
    }
    /// Abort the current session or load (the worker ends; saved audio stays). An idle hot model stays loaded.
    func stop() {
        cancelToken = UUID()
        let busy = sessionActive || pending != nil || loadingRef != nil
        resolve(.failure(CancellationError()))
        if busy || hotRef == nil { retire() }
    }
    func resetTranscript() { frames = 0; committed = ""; partial = ""; incomplete = false }
    func releaseAndWait() async throws { cancelToken = UUID(); resolve(.failure(CancellationError())); retire(); try await waitForRetired() }
    func shutdown() {
        cancelToken = UUID()
        resolve(.failure(CancellationError())); retire()
        for child in retired where child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        retired.removeAll()
    }
}
