import Foundation
import Darwin
import VellaCore

/// A single private, on-demand process. No listening port or shared model service.
@MainActor final class Backend {
    let requestTimeout: TimeInterval
    let idleTimeout: TimeInterval
    private let pythonOverride: URL?
    private let scriptOverride: URL?
    private var process: Process?
    private var retired: [Process] = []
    private var input: FileHandle?
    private var epoch = UUID()
    private var stopGeneration = UUID()
    private var activeCall: UUID?
    private var pending: (UUID, CheckedContinuation<String, Error>)?
    private var buffer = Data()
    private var deadline: DispatchWorkItem?
    private var idle: DispatchWorkItem?
    private var loadedModel = ""
    private var memoryPressure: DispatchSourceMemoryPressure?
    private(set) var lastMetrics: [String: Double] = [:]
    private(set) var ownership = "Vella runtime unloaded"
    var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    init(python: URL? = nil, workerScript: URL? = nil, requestTimeout: TimeInterval = 120, idleTimeout: TimeInterval = 60) {
        self.pythonOverride = python; self.scriptOverride = workerScript
        self.requestTimeout = requestTimeout; self.idleTimeout = idleTimeout
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleMemoryPressure(critical: self.memoryPressure?.data.contains(.critical) == true)
        }
        pressure.resume()
    }
    deinit { memoryPressure?.cancel() }
    func handleMemoryPressure(critical: Bool) {
        guard process != nil else { return }
        if activeCall == nil { retireWorker() }
        else if critical {
            finish(.failure(VellaError.message("macOS reported critical memory pressure. Inference stopped; saved audio is retained. Close other applications or use a smaller model.")))
            retireWorker()
        }
    }
    nonisolated static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella", isDirectory: true)
    static var configURL: URL { support.appendingPathComponent("config.json") }
    func configuration(requiresModel: Bool = true) throws -> Configuration {
        let config: Configuration
        if FileManager.default.fileExists(atPath: Self.configURL.path) {
            config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: Self.configURL))
        } else {
            config = Configuration(executable: Self.support.appendingPathComponent("runtime/bin/python").path, model: "")
        }
        try config.validate(requiresModel: requiresModel)
        return config
    }
    private func pythonURL() throws -> URL {
        let url = try pythonOverride ?? URL(fileURLWithPath: configuration(requiresModel: false).executable)
        guard url.lastPathComponent.hasPrefix("python"), FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VellaError.message("Vella's Python runtime is not ready. Run Vella's installer/setup; no external transcription server is used.")
        }
        return url
    }
    private func ensureWorker(model: String, generation: UUID) async throws {
        try await CalibrationStore.shared.cancelAndWait()
        try checkStartup(generation)
        if process?.isRunning == true, loadedModel == model { return }
        retireWorker()
        try await waitForRetired(generation: generation)
        try checkStartup(generation)
        let python = try pythonURL()
        let script = scriptOverride ?? ModelLibrary.resourceDirectory().appendingPathComponent("inference_worker.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw VellaError.message("Vella's inference worker is missing. Reinstall the app.") }
        let child = Process(), stdout = Pipe(), stdin = Pipe()
        child.executableURL = python; child.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"; env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        child.environment = env; child.standardInput = stdin; child.standardOutput = stdout
        // Third-party diagnostics can contain speech; never persist them.
        child.standardError = FileHandle.nullDevice
        let generation = UUID(); epoch = generation; buffer.removeAll(keepingCapacity: false)
        try child.run()
        process = child; input = stdin.fileHandleForWriting; loadedModel = model; ownership = "Vella private worker"
        Task.detached { [weak self] in
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                await self?.receive(data, generation: generation)
            }
            try? stdout.fileHandleForReading.close()
            await self?.workerEnded(generation: generation)
        }
    }
    func transcribe(_ file: URL, config: Configuration) async throws -> String {
        guard activeCall == nil else { throw VellaError.message("Vella is already processing another segment.") }
        guard !config.model.isEmpty else { throw VellaError.message("Install a model and choose Use first.") }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else {
            throw VellaError.message("Audio exceeds the bounded segment size. Saved audio is retained.")
        }
        let call = UUID(); activeCall = call; idle?.cancel(); idle = nil
        let generation = stopGeneration
        defer { if activeCall == call { activeCall = nil }; scheduleIdleUnload() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await ensureWorker(model: config.model, generation: generation)
            try checkStartup(generation)
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = (call, continuation)
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.pending?.0 == call else { return }
                    self.finish(.failure(URLError(.timedOut))); self.retireWorker()
                }
                deadline = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
                do {
                    var data = try JSONSerialization.data(withJSONObject: ["id": call.uuidString, "audio": file.path, "model": config.model])
                    data.append(10)
                    guard let input else { throw VellaError.message("Vella's worker disconnected.") }
                    try input.write(contentsOf: data)
                } catch { finish(.failure(error)); retireWorker() }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in if self?.activeCall == call { self?.stop() } }
        })
    }
    private func receive(_ data: Data, generation: UUID) {
        guard epoch == generation else { return }
        buffer.append(data)
        guard buffer.count <= 2_000_000 else { failProtocol(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? String, id == pending?.0.uuidString else { failProtocol(); return }
            lastMetrics = (object["metrics"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            if let error = object["error"] as? [String: Any] {
                let code = error["code"] as? String
                if code == "no_speech" { finish(.failure(VellaError.noSpeech)) }
                else {
                    let message = code == "memory" ? "This model needs more available memory. Choose a smaller model; saved audio is retained." : "Local inference failed. Saved audio is retained; try again or choose another model."
                    finish(.failure(VellaError.message(message))); retireWorker(); return
                }
            } else if let text = object["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(trimmed.isEmpty ? .failure(VellaError.noSpeech) : .success(trimmed))
            } else { failProtocol(); return }
        }
    }
    private func failProtocol() {
        finish(.failure(VellaError.message("Vella received an invalid worker response. Saved audio is retained.")))
        retireWorker()
    }
    private func workerEnded(generation: UUID) {
        guard epoch == generation else { return }
        finish(.failure(VellaError.message("Vella's inference worker exited. Saved audio is retained.")))
        retireWorker()
    }
    private func finish(_ result: Result<String, Error>) {
        deadline?.cancel(); deadline = nil
        guard let callback = pending?.1 else { return }
        pending = nil; callback.resume(with: result)
    }
    private func scheduleIdleUnload() {
        idle?.cancel(); idle = nil
        guard activeCall == nil, process?.isRunning == true else { return }
        let generation = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == generation, self.activeCall == nil else { return }
            self.retireWorker()
        }
        idle = task; DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: task)
    }
    private func retireWorker() {
        idle?.cancel(); idle = nil; epoch = UUID()
        try? input?.close(); input = nil
        if let child = process, child.isRunning {
            child.terminate(); retired.append(child)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        retired.removeAll { !$0.isRunning }
        process = nil; loadedModel = ""; buffer.removeAll(keepingCapacity: false); ownership = "Vella runtime unloaded"
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
    func releaseAndWait() async throws { stop(); try await waitForRetired() }
    func shutdown() {
        stop()
        for child in retired where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        retired.removeAll()
    }
    func stop() { stopGeneration = UUID(); finish(.failure(CancellationError())); retireWorker() }
}
