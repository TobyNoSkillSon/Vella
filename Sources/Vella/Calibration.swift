import Foundation
import CryptoKit
import IOKit
import Darwin

/// Local speed in audio seconds per processing second; never a catalog accuracy score.
@MainActor final class CalibrationStore {
    static let shared = CalibrationStore()
    static func speed(modelPath: String) -> Double? { shared.speed(modelPath: modelPath) }
    static func observe(modelPath: String, audioSeconds: Double, processingSeconds: Double) {
        shared.observe(modelPath: modelPath, audioSeconds: audioSeconds, processingSeconds: processingSeconds)
    }

    struct Record: Codable {
        let identity: String
        let modelKey: String
        let deviceKey: String
        let runtimeKey: String
        let sampleKey: String
        let measuredAt: Date
        let speed: Double
        let source: String
        let measurement: Measurement?
        init(identity: String, measuredAt: Date, speed: Double, source: String, measurement: Measurement?) {
            self.identity = identity; self.measuredAt = measuredAt; self.speed = speed
            self.source = source; self.measurement = measurement
            let keys = identity.components(separatedBy: ":")
            modelKey = keys.first ?? identity
            deviceKey = keys.count == 4 ? keys[1] : identity
            runtimeKey = keys.count == 4 ? keys[2] : identity
            sampleKey = keys.count == 4 ? keys[3] : identity
        }
    }
    struct Measurement: Codable {
        let audioSeconds: Double
        let loadSeconds: Double
        let firstRequestSeconds: Double
        let warmSeconds: [Double]
        let speed: Double
        let sampleSHA256: String
        let mlxVersion: String
        let mlxAudioVersion: String
        let parameters: [String: Parameter]
        enum Parameter: Codable { // Preserve the worker's exact supported generation settings.
            case number(Double), bool(Bool)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .number(try c.decode(Double.self)) }
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self { case .number(let n): try c.encode(n); case .bool(let b): try c.encode(b) }
            }
        }
        var valid: Bool {
            let times = [loadSeconds, firstRequestSeconds] + warmSeconds
            guard audioSeconds >= 3, audioSeconds <= 15, warmSeconds.count == 2,
                  times.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 120 }),
                  speed.isFinite, speed > 0, sampleSHA256 == CalibrationStore.sampleHash,
                  !mlxVersion.isEmpty, !mlxAudioVersion.isEmpty else { return false }
            return abs(speed - audioSeconds / ((warmSeconds[0] + warmSeconds[1]) / 2)) < 0.00001
        }
    }
    nonisolated static let sampleHash = "e36af54bcd25cbbb9c1adba8ff28bc7a4001a91f6bfdbc3360df9efd395bafa2"
    let directory: URL
    let resources: URL
    private let python: () -> URL?
    private let identityOverride: ((String) -> String?)?
    private let now: () -> Date
    private var process: Process?
    private var job: UUID?
    private var stopReason: String?
    var isRunning: Bool { job != nil }

    init(directory: URL? = nil, resources: URL? = nil, python: (() -> URL?)? = nil,
         identity: ((String) -> String?)? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory ?? Backend.support.appendingPathComponent("Calibrations")
        self.resources = resources ?? ModelLibrary.resourceDirectory()
        self.python = python ?? {
            guard let config = try? Backend().configuration(requiresModel: false) else { return nil }
            let python = URL(fileURLWithPath: config.executable)
            return python.lastPathComponent.hasPrefix("python") ? python : nil
        }
        identityOverride = identity; self.now = now
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func file(for path: String, observed: Bool = false) -> URL { directory.appendingPathComponent(Self.hash(Data(URL(fileURLWithPath: path).standardizedFileURL.path.utf8)) + (observed ? ".observed.json" : ".json")) }

    /// Stat identity avoids reading GB of weights on the main actor. Includes inode, size,
    /// nanosecond mtime/ctime and resolved path; JSON contents pin architecture/quantization.
    static func stamp(_ url: URL, contents: Bool = true) throws -> String {
        let resolved = url.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(resolved.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var value = "\(url.path)|\(resolved.path)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        if contents, ["json", "py", "txt"].contains(url.pathExtension), info.st_size <= 1_000_000 {
            value += "|" + hash(try Data(contentsOf: resolved))
        }
        return value
    }
    func identity(modelPath: String) -> String? {
        if let identityOverride { return identityOverride(modelPath) }
        do {
            guard let python = python(), FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
            let model = URL(fileURLWithPath: modelPath).standardizedFileURL
            guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: model.appendingPathComponent("config.json"))) as? [String: Any],
                  config["auto_map"] == nil else { return nil }
            let architecture = config["model_type"] as? String ?? ((config["target"] as? String == "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel") ? "parakeet" : "")
            guard ["whisper", "qwen3_asr", "parakeet", "sensevoice", "granite_speech"].contains(architecture) else { return nil }
            let files = try FileManager.default.contentsOfDirectory(at: model, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
            guard files.contains(where: { $0.pathExtension == "safetensors" }), files.count < 1024 else { return nil }
            var parts = [try Self.stamp(model.appendingPathComponent("config.json"))]
            for file in files { parts.append(try Self.stamp(file)) }
            let modelKey = Self.hash(Data(parts.joined(separator: "\n").utf8))
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
            let deviceKey = Self.hash(Data([uuid, ModelLibrary.processor, String(ProcessInfo.processInfo.physicalMemory), ProcessInfo.processInfo.operatingSystemVersionString].joined(separator: "|").utf8))
            parts = [try Self.stamp(python)]
            let lib = python.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
            let versions = try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("python") }
            guard !versions.isEmpty else { return nil }
            var runtimeFiles: [URL] = []
            for version in versions {
                let site = version.appendingPathComponent("site-packages")
                for entry in try FileManager.default.contentsOfDirectory(at: site, includingPropertiesForKeys: nil) {
                    let name = entry.lastPathComponent
                    if name.hasSuffix(".dist-info") {
                        runtimeFiles.append(entry.appendingPathComponent("METADATA"))
                        runtimeFiles.append(entry.appendingPathComponent("RECORD"))
                    } else if ["mlx", "mlx_audio", "transformers", "tokenizers", "safetensors"].contains(name) {
                        guard let enumerator = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: nil) else { return nil }
                        for case let file as URL in enumerator where ["py", "so", "dylib"].contains(file.pathExtension) {
                            runtimeFiles.append(file)
                            if runtimeFiles.count > 12000 { return nil }
                        }
                    }
                }
            }
            guard runtimeFiles.contains(where: { $0.path.contains("/mlx_audio/") }) else { return nil }
            for file in runtimeFiles.sorted(by: { $0.path < $1.path }) { parts.append(try Self.stamp(file, contents: false)) }
            let runtimeKey = Self.hash(Data(parts.joined(separator: "\n").utf8))
            parts = ["vella-calibration-v1"]
            for name in ["calibration_worker.py", "benchmark_worker.py", "Calibration/manifest.json", "Calibration/speech.wav", "Calibration/text.txt"] {
                parts.append(Self.hash(try Data(contentsOf: resources.appendingPathComponent(name))))
            }
            let sampleKey = Self.hash(Data(parts.joined(separator: "\n").utf8))
            return [modelKey, deviceKey, runtimeKey, sampleKey].joined(separator: ":")
        } catch { return nil }
    }
    func speed(modelPath: String) -> Double? {
        // Missing calibration is the common first-run case; avoid walking the runtime then.
        guard [false, true].contains(where: { FileManager.default.fileExists(atPath: file(for: modelPath, observed: $0).path) }) else { return nil }
        guard let identity = identity(modelPath: modelPath) else { return nil }
        return speed(modelPath: modelPath, identity: identity)
    }
    private func speed(modelPath: String, identity: String) -> Double? {
        for observed in [true, false] {
            guard let data = try? Data(contentsOf: file(for: modelPath, observed: observed)), data.count < 32_768,
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.identity == identity,
                  now().timeIntervalSince(record.measuredAt) >= 0, now().timeIntervalSince(record.measuredAt) < 30 * 86400,
                  record.speed.isFinite, record.speed > 0,
                  (observed && record.source == "observation") || (!observed && record.source == "sample-warm-v2" && record.measurement?.valid == true && record.measurement?.speed == record.speed) else { continue }
            return record.speed
        }
        return nil
    }
    private func save(_ record: Record, path: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(for: path, observed: record.source == "observation"), options: .atomic)
    }
    /// Parent supplies completed inference timings only. No audio or text is retained.
    func observe(modelPath: String, audioSeconds: Double, processingSeconds: Double) {
        guard audioSeconds.isFinite, processingSeconds.isFinite, audioSeconds >= 1,
              processingSeconds >= 0.01, audioSeconds <= 86400, processingSeconds <= 86400,
              let identity = identity(modelPath: modelPath) else { return }
        let measured = audioSeconds / processingSeconds
        // A bounded moving estimate; observations stay separate from catalog measurements.
        let blended = speed(modelPath: modelPath, identity: identity).map { $0 * 0.75 + measured * 0.25 } ?? measured
        try? save(Record(identity: identity, measuredAt: now(), speed: blended, source: "observation", measurement: nil), path: modelPath)
    }
    func cancelAndWait() async throws {
        let child = process
        cancel()
        let until = ProcessInfo.processInfo.systemUptime + 3
        while child?.isRunning == true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < until else { throw CocoaError(.userCancelled) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func shutdown() {
        cancel()
        if let child = process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
    func cancel() {
        stopReason = "Calibration cancelled. Installed weights are ready to use."
        terminate()
    }
    private func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    /// Separate subprocess; completion fires only after exit. Never changes selection.
    @discardableResult func calibrate(modelPath: String, timeout: Double = 120,
        status: @escaping (String) -> Void, completion: @escaping (String?) -> Void) -> Bool {
        guard timeout.isFinite, timeout > 0, !isRunning, speed(modelPath: modelPath) == nil,
              let identity = identity(modelPath: modelPath), let python = python() else { return false }
        let token = UUID(), child = Process(), pipe = Pipe()
        child.executableURL = python
        child.arguments = [resources.appendingPathComponent("calibration_worker.py").path, "--model", modelPath, "--sample", resources.appendingPathComponent("Calibration").path]
        var env = ProcessInfo.processInfo.environment
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "PYTHONUNBUFFERED", "PYTHONDONTWRITEBYTECODE"] { env[key] = "1" }
        child.environment = env; child.standardOutput = pipe; child.standardError = pipe
        do { try child.run() } catch { completion("Installed. Calibration could not start: \(error.localizedDescription)"); return false }
        job = token; process = child; stopReason = nil
        status("Installed. Calibrating local speed…")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(120, max(0.01, timeout)) * 1_000_000_000))
            guard let self, self.job == token else { return }
            self.stopReason = "Calibration timed out. Installed weights are ready to use."; self.terminate()
        }
        Task.detached { [weak self] in
            var buffer = Data(), result: Measurement?, failure: String?
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 65_536 { buffer.removeAll(); failure = "Oversized calibration response"; continue }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: end)); buffer.removeSubrange(...end)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if object["event"] as? String == "progress", let message = object["message"] as? String {
                        await MainActor.run { status(message) }
                    } else if object["event"] as? String == "result", let value = object["result"],
                              let bytes = try? JSONSerialization.data(withJSONObject: value) {
                        result = try? JSONDecoder().decode(Measurement.self, from: bytes)
                    } else if object["event"] as? String == "error" { failure = "Calibration failed. Installed weights are ready to use." }
                }
            }
            child.waitUntilExit()
            let outcome = result, error = failure
            guard let owner = self else { return }
            await MainActor.run {
                guard owner.job == token else { return }
                owner.job = nil; owner.process = nil
                var reason = owner.stopReason ?? error
                if reason == nil {
                    if child.terminationStatus == 0, let outcome, outcome.valid, owner.identity(modelPath: modelPath) == identity {
                        do { try owner.save(Record(identity: identity, measuredAt: owner.now(), speed: outcome.speed, source: "sample-warm-v2", measurement: outcome), path: modelPath) }
                        catch { reason = "Installed. Calibration could not be saved." }
                    } else { reason = "Calibration unavailable. Installed weights are ready to use." }
                }
                completion(reason)
            }
        }
        return true
    }
}
