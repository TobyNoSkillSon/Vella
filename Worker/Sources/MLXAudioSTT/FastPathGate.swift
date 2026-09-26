import CryptoKit
import Foundation
import Metal
import MLX

public enum FastPathGateError: Error { case invalid }

/// Load-time qualification of any `FastPathCapable` model's optimized path against stock MLX on this Mac.
/// The test runs in a child process with a deadline, so a kernel hang or GPU fault cannot take down the serving
/// worker. The verdict is persisted per (model files, GPU family, macOS build, worker version, model fast-path
/// revision); failure is sticky for that key — never turn a failed test into a fast run.
/// Shared by both workers (dictation `VellaWorker`, streaming `VellaStreamingWorker`); each worker supplies its own
/// `fast-selftest --model <dir>` child entry point.
public enum FastPathGate {
    public static let version = "native-kernels-7"
    /// Child exit status when the self-test could not start (not a verdict on the kernels).
    public static let inconclusive: Int32 = 3
    /// Child exit status for evidence against the optimized path.
    public static let verdictFailed: Int32 = 2
    public static func debug(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"], path.hasPrefix("/") else { return }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
    /// `VELLA_FORCE_STOCK=1` (or the older `VELLA_PARAKEET_FORCE_STOCK`) forces stock MLX for diagnosis and as the
    /// reference for fallback tests.
    public static var forcedStock: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK"].contains { key in
            environment[key].map { !$0.isEmpty && $0 != "0" } ?? false
        }
    }

    public static func storage() -> URL {
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
    public static var gpuFamily: String {
        let device = MTLCreateSystemDefaultDevice()
        return device?.supportsFamily(.apple9) == true ? "apple9" : device?.supportsFamily(.apple8) == true ? "apple8" : "unsupported"
    }

    public static func key(_ path: URL, revision: String) throws -> String {
        var digest = SHA256()
        let entries = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { ["json", "safetensors"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard entries.contains(where: { $0.pathExtension == "safetensors" }) else { throw FastPathGateError.invalid }
        for file in entries {
            digest.update(data: Data(file.lastPathComponent.utf8))
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            // Each read returns an autoreleased NSData. On a Swift concurrency thread nothing drains them until the
            // task ends, so without a pool per chunk hashing a 1.25 GB checkpoint kept 1.26 GB of heap alive (twice
            // per load: qualify + gateURL), measured with footprint(1) on M5 Max, 26 Sep 2026.
            while try autoreleasepool(invoking: {
                guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
                digest.update(data: chunk)
                return true
            }) {}
        }
        digest.update(data: Data("\(gpuFamily):\(osBuild):\(version)".utf8))
        if !revision.isEmpty { digest.update(data: Data(":\(revision)".utf8)) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static var osBuild: String {
        var length = 0
        sysctlbyname("kern.osversion", nil, &length, nil, 0)
        var build = [CChar](repeating: 0, count: max(length, 1))
        sysctlbyname("kern.osversion", &build, &length, nil, 0)
        return String(cString: build)
    }

    public static func statusURL(_ path: URL, revision: String) throws -> URL { storage().appendingPathComponent(try key(path, revision: revision) + ".json") }
    public static func status(_ url: URL) -> String? { record(url)?["status"] }
    private static func record(_ url: URL) -> [String: String]? {
        guard let bytes = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: String] else { return nil }
        return object
    }
    /// Consecutive inconclusive self-tests recorded for this key (0 when none).
    public static func inconclusiveCount(_ url: URL) -> Int {
        guard let object = record(url), object["status"] == "inconclusive" else { return 0 }
        return Int(object["count"] ?? "") ?? 0
    }
    /// After this many consecutive inconclusive self-tests for one key, the key is persisted as stock.
    public static let inconclusiveLimit = 2
    public static func persist(_ value: String, to url: URL, count: Int? = nil) {
        var object = ["status": value, "workerVersion": version]
        if let count { object["count"] = String(count) }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public enum Verdict: Equatable {
        case fast
        case stock(String)
    }

    /// The gate decision for a model of type `type` at `path`, running the child self-test the first time.
    public static func qualify(_ path: URL, type: any FastPathCapable.Type) -> Verdict {
        qualify(path, revision: type.fastPathRevision)
    }
    /// `requiredFamily` nil: the optimized path uses no GPU-family-specific kernels (stock MLX ops only).
    public static func qualify(_ path: URL, revision: String, requiredFamily: String? = "apple9") -> Verdict {
        if forcedStock { return .stock("Stock path forced for diagnosis (VELLA_FORCE_STOCK).") }
        guard let url = try? statusURL(path, revision: revision) else {
            return .stock("The optimized path could not be qualified for these model files.")
        }
        // "inconclusive" is not a verdict: the self-test runs again.
        if let previous = status(url), previous != "inconclusive" {
            return previous == "fast" ? .fast : .stock("The optimized path failed its self-test against stock MLX on this Mac.")
        }
        if let requiredFamily, gpuFamily != requiredFamily {
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
}
