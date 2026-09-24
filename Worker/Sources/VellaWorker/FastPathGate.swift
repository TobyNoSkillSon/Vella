import CryptoKit
import Foundation
import Metal
import MLX
import MLXAudioSTT

enum FastPathNonFinite: Error { case invalid }

/// Failure is sticky for this precise model/runtime key; never turn a failed test into a fast run.
enum FastPathGate {
    static let version = "native-kernels-4"
    private static func debug(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"], path.hasPrefix("/") else { return }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
    static var forcedStock: Bool {
        guard let value = ProcessInfo.processInfo.environment["VELLA_PARAKEET_FORCE_STOCK"] else { return false }
        return !value.isEmpty && value != "0"
    }

    static func storage() -> URL {
        if let override = ProcessInfo.processInfo.environment["VELLA_WORKER_DATA_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override).appendingPathComponent("FastPath")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vella/Worker/FastPath")
    }

    static func key(_ path: URL) throws -> String {
        var digest = SHA256()
        let entries = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { ["json", "safetensors"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard entries.contains(where: { $0.pathExtension == "safetensors" }) else { throw RequestError.invalid }
        for file in entries {
            digest.update(data: Data(file.lastPathComponent.utf8))
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        }
        let device = MTLCreateSystemDefaultDevice()
        var buildLength = 0
        sysctlbyname("kern.osversion", nil, &buildLength, nil, 0)
        var build = [CChar](repeating: 0, count: max(buildLength, 1))
        sysctlbyname("kern.osversion", &build, &buildLength, nil, 0)
        let gpu = device?.supportsFamily(.apple9) == true ? "apple9" : device?.supportsFamily(.apple8) == true ? "apple8" : "unsupported"
        digest.update(data: Data("\(gpu):\(String(cString: build)):\(version)".utf8))
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func statusURL(_ path: URL) throws -> URL { storage().appendingPathComponent(try key(path) + ".json") }
    static func status(_ url: URL) -> String? {
        guard let bytes = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: String] else { return nil }
        return object["status"]
    }
    static func persist(_ value: String, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["status": value, "workerVersion": version]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func qualify(_ path: URL) -> (Bool, URL?) {
        guard !forcedStock, let url = try? statusURL(path) else { return (false, nil) }
        if let previous = status(url) { return (previous == "fast", url) }
        guard MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) == true else {
            persist("stock", to: url)
            return (false, url)
        }
        // Q4's packed joint/embedding and FP32 recurrent weights are not supported
        // by the bf16 decoder kernel. Avoid loading it a second time in the probe.
        if let config = try? jsonObject(path.appendingPathComponent("config.json")),
           let quantization = config["quantization"] as? [String: Any], quantization["bits"] != nil {
            persist("stock", to: url)
            return (false, url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["fast-selftest", "--model", path.path]
        // QA-only instrumentation cannot weaken the production qualification.
        process.environment = ProcessInfo.processInfo.environment.filter {
            $0.key != "VELLA_KERNEL_DIAGNOSTIC_COMPONENT" && $0.key != "VELLA_KERNEL_DIAGNOSTIC_CLIP"
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { persist("stock", to: url); return (false, url) }
        if exited.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            persist("stock", to: url)
            return (false, url)
        }
        let success = process.terminationStatus == 0
        persist(success ? "fast" : "stock", to: url)
        // If persistence failed, don't enable a path that won't be tested on restart.
        return (success && status(url) == "fast", url)
    }

    static func runSelfTest(_ path: URL) throws -> Bool {
        let model = try ParakeetModel.fromDirectory(path, preserveCheckpointDTypes: true)
        debug("loaded")
        let names = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_CLIP"].map { [$0] } ?? ["clip-a", "clip-b"]
        let component = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_COMPONENT"] ?? "both"
        for name in names {
            guard let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : Bundle.module.url(forResource: name, withExtension: "wav") else { return false }
            let audio = try Audio(url.path)
            let input = MLXArray(audio.samples).asType(.bfloat16)
            let stock = model.qualificationTokens(audio: input)
            debug("\(name): stock \(stock.count)")
            guard model.configureFastPath(enabled: true, component: component) else { debug("unsupported fast modules \(component)"); return false }
            let fast = model.qualificationTokens(audio: input)
            let finite = model.fastPathFinite
            debug("\(name): fast \(fast.count); equal \(stock == fast); first different \(Array(zip(stock, fast)).firstIndex(where: { $0.0 != $0.1 }).map(String.init) ?? "none")")
            model.configureFastPath(enabled: false)
            guard stock == fast, !stock.isEmpty, finite else { return false }
        }
        return true
    }
}
