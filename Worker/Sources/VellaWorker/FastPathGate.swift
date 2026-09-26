import CryptoKit
import Foundation
import Metal
import MLX
import MLXAudioSTT

enum FastPathNonFinite: Error { case invalid }

/// Load-time qualification of any `FastPathCapable` model's optimized path against stock MLX on this Mac.
/// The test runs in a child process with a deadline, so a kernel hang or GPU fault cannot take down the serving
/// worker. The verdict is persisted per (model files, GPU family, macOS build, worker version, model fast-path
/// revision); failure is sticky for that key — never turn a failed test into a fast run.
enum FastPathGate {
    static let version = "native-kernels-7"
    /// Child exit status when the self-test could not start (not a verdict on the kernels).
    static let inconclusive: Int32 = 3
    /// Child exit status for evidence against the optimized path.
    static let verdictFailed: Int32 = 2
    private static func debug(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"], path.hasPrefix("/") else { return }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
    /// `VELLA_FORCE_STOCK=1` (or the older `VELLA_PARAKEET_FORCE_STOCK`) forces stock MLX for diagnosis and as the
    /// reference for fallback tests.
    static var forcedStock: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK"].contains { key in
            environment[key].map { !$0.isEmpty && $0 != "0" } ?? false
        }
    }

    static func storage() -> URL {
        if let override = ProcessInfo.processInfo.environment["VELLA_WORKER_DATA_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override).appendingPathComponent("FastPath")
        }
        if let support = ProcessInfo.processInfo.environment["VELLA_SUPPORT_DIR"], support.hasPrefix("/") {
            return URL(fileURLWithPath: support).appendingPathComponent("Worker/FastPath")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vella/Worker/FastPath")
    }

    /// Metal feature family the kernels need; a family, never a chip name.
    static var gpuFamily: String {
        let device = MTLCreateSystemDefaultDevice()
        return device?.supportsFamily(.apple9) == true ? "apple9" : device?.supportsFamily(.apple8) == true ? "apple8" : "unsupported"
    }

    static func key(_ path: URL, revision: String) throws -> String {
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
        digest.update(data: Data("\(gpuFamily):\(osBuild):\(version)".utf8))
        if !revision.isEmpty { digest.update(data: Data(":\(revision)".utf8)) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static var osBuild: String {
        var length = 0
        sysctlbyname("kern.osversion", nil, &length, nil, 0)
        var build = [CChar](repeating: 0, count: max(length, 1))
        sysctlbyname("kern.osversion", &build, &length, nil, 0)
        return String(cString: build)
    }

    static func statusURL(_ path: URL, revision: String) throws -> URL { storage().appendingPathComponent(try key(path, revision: revision) + ".json") }
    static func status(_ url: URL) -> String? { record(url)?["status"] }
    private static func record(_ url: URL) -> [String: String]? {
        guard let bytes = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: String] else { return nil }
        return object
    }
    /// Consecutive inconclusive self-tests recorded for this key (0 when none).
    static func inconclusiveCount(_ url: URL) -> Int {
        guard let object = record(url), object["status"] == "inconclusive" else { return 0 }
        return Int(object["count"] ?? "") ?? 0
    }
    /// After this many consecutive inconclusive self-tests for one key, the key is persisted as stock.
    static let inconclusiveLimit = 2
    static func persist(_ value: String, to url: URL, count: Int? = nil) {
        var object = ["status": value, "workerVersion": version]
        if let count { object["count"] = String(count) }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    enum Verdict: Equatable {
        case fast
        case stock(String)
    }

    /// The gate decision for a model of type `type` at `path`, running the child self-test the first time.
    static func qualify(_ path: URL, type: any FastPathCapable.Type) -> Verdict {
        if forcedStock { return .stock("Stock path forced for diagnosis (VELLA_FORCE_STOCK).") }
        guard let url = try? statusURL(path, revision: type.fastPathRevision) else {
            return .stock("The optimized path could not be qualified for these model files.")
        }
        // "inconclusive" is not a verdict: the self-test runs again.
        if let previous = status(url), previous != "inconclusive" {
            return previous == "fast" ? .fast : .stock("The optimized path failed its self-test against stock MLX on this Mac.")
        }
        guard gpuFamily == "apple9" else {
            persist("stock", to: url)
            return .stock("The optimized kernels need Apple GPU family 9; this GPU reports \(gpuFamily).")
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
        let failed = Verdict.stock("The optimized path failed its self-test against stock MLX on this Mac.")
        do { try process.run() } catch { return recordInconclusive(url) }
        if exited.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            persist("stock", to: url)
            return .stock("The optimized path's self-test did not finish within 45 s on this Mac.")
        }
        debug("self-test child exit \(process.terminationStatus) reason \(process.terminationReason.rawValue)")
        // Verdicts are exit 0 (token-exact, finite on every clip) and exit 2 (mismatch, non-finite output or a kernel
        // error). A timeout above is evidence too. Anything else (setup failure, crash, unexplained status) is
        // inconclusive: stock for this load, retried next load, persisted as stock after two in a row.
        guard process.terminationReason == .exit, [0, verdictFailed].contains(process.terminationStatus) else {
            return recordInconclusive(url)
        }
        let success = process.terminationStatus == 0
        persist(success ? "fast" : "stock", to: url)
        // If persistence failed, don't enable a path that won't be tested on restart.
        guard success else { return failed }
        return status(url) == "fast" ? .fast : .stock("The self-test result could not be saved, so the optimized path stays off.")
    }
    private static func recordInconclusive(_ url: URL) -> Verdict {
        let count = inconclusiveCount(url) + 1
        if count >= inconclusiveLimit {
            persist("stock", to: url)
            return .stock("The optimized path's self-test could not complete on this Mac \(count) times in a row; using stock MLX.")
        }
        persist("inconclusive", to: url, count: count)
        return .stock("The optimized path's self-test could not complete on this load; using stock MLX and testing again next load.")
    }

    /// Child process: stock and fast must emit identical, non-empty, finite token IDs on every clip.
    static func runSelfTest(_ model: any FastPathCapable, input: (MLXArray) -> MLXArray) throws -> Bool {
        debug("loaded")
        let names = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_CLIP"].map { [$0] } ?? model.fastPathSelfTestClips
        let component = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_COMPONENT"] ?? "both"
        guard !names.isEmpty else { return false }
        for name in names {
            guard let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : Bundle.module.url(forResource: name, withExtension: "wav") else { return false }
            let audio = try Audio(url.path)
            let samples = input(MLXArray(audio.samples))
            let stock = model.qualificationTokens(audio: samples)
            debug("\(name): stock \(stock.count)")
            guard model.configureFastPath(enabled: true, component: component) else { debug("unsupported fast modules \(component)"); return false }
            let fast = model.qualificationTokens(audio: samples)
            let finite = model.fastPathFinite
            debug("\(name): fast \(fast.count); equal \(stock == fast); first different \(Array(zip(stock, fast)).firstIndex(where: { $0.0 != $0.1 }).map(String.init) ?? "none")")
            _ = model.configureFastPath(enabled: false, component: component)
            guard stock == fast, !stock.isEmpty, finite else { return false }
        }
        return true
    }
}
