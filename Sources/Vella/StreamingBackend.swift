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
@MainActor final class StreamingBackend {
    private struct Reply: Decodable {
        let id: UUID
        let frames: Int?
        let committed: String?
        let partial: String?
        let done: Bool?
        let error: String?
        let incomplete: Bool?
    }
    private let python: URL?
    private let script: URL?
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
    var hasUnrecognizedAudio: Bool { incomplete }
    private var pressure: DispatchSourceMemoryPressure?
    private(set) var frames = 0
    private(set) var committed = ""
    private(set) var partial = ""
    var text: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }
    var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    var onUpdate: (() throws -> Void)?
    // Fixed-size worker deltas: the live path never rescans all earlier speech.
    var onEvent: ((String, String, Bool) throws -> Void)?
    init(python: URL? = nil, script: URL? = nil, timeout: TimeInterval = 120) {
        self.python = python; self.script = script; self.timeout = timeout
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        pressure = source
        source.setEventHandler { [weak self] in
            self?.fail(VellaError.message("macOS reported critical memory pressure. Streaming stopped; saved audio is retained."))
        }
        source.resume()
    }
    deinit { pressure?.cancel(); if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    func start(config: Configuration) async throws {
        stop(); resetTranscript(); let generation = epoch
        try await waitForRetired()
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard config.mode == .streaming, !config.model.isEmpty else { throw VellaError.message("Choose a dedicated streaming model first.") }
        let executable = python ?? URL(fileURLWithPath: config.executable)
        guard executable.lastPathComponent.hasPrefix("python"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw VellaError.message("Vella's Python runtime is unavailable. Repair the runtime setup.")
        }
        let child = Process(), stdout = Pipe(), stdin = Pipe()
        child.executableURL = executable
        child.arguments = [(script ?? ModelLibrary.resourceDirectory().appendingPathComponent("streaming_worker.py")).path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"; env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        child.environment = env; child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        frames = 0; committed = ""; partial = ""; buffer.removeAll(); receivedDone = false
        try child.run(); process = child; input = stdin.fileHandleForWriting
        Task.detached { [weak self] in
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                await self?.receive(data, generation: generation)
            }
            try? stdout.fileHandleForReading.close()
            await self?.ended(generation: generation)
        }
        _ = try await exchange(["op": "start", "model": config.model])
    }
    func feed(_ pcm: Data) async throws {
        guard !pcm.isEmpty, pcm.count <= 6400, pcm.count % 4 == 0 else { throw VellaError.message("Invalid streaming audio packet.") }
        frames += pcm.count / 4
        _ = try await exchange(["op": "audio", "pcm": pcm.base64EncodedString()])
    }
    func finish(expectedFrames: Int) async throws -> String {
        let generation = epoch
        defer { if epoch == generation { stop() } }
        guard frames == expectedFrames else { throw VellaError.message("Streaming did not receive all saved audio. Audio is retained; automatic replay is disabled.") }
        let result = try await exchange(["op": "finish"])
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard result.done == true, partial.isEmpty else { throw VellaError.message("Streaming did not finalize all words. Saved audio is retained.") }
        guard !incomplete else { throw VellaError.unrecognizedAudio }
        let text = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VellaError.noSpeech }
        return text
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
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line), reply.id == pending?.0 else {
                fail(VellaError.message("Invalid streaming response. Saved audio is retained.")); return
            }
            if let error = reply.error { fail(VellaError.message(error)); return }
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
        // resumes. Keep its epoch until finish() consumes that reply.
        if receivedDone && pending == nil { return }
        fail(VellaError.message("Streaming worker exited. Saved audio is retained."))
    }
    private func fail(_ error: Error) { resolve(.failure(error)); retire() }
    private func retire() {
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
    func stop() { resolve(.failure(CancellationError())); retire() }
    func resetTranscript() { frames = 0; committed = ""; partial = ""; incomplete = false }
    func releaseAndWait() async throws { stop(); try await waitForRetired() }
    func shutdown() {
        stop()
        for child in retired where child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        retired.removeAll()
    }
}
