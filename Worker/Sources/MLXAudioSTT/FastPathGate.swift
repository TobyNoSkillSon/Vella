import CryptoKit
import Foundation
import Metal
import MLX

public enum FastPathGateError: Error { case invalid }

/// Load-time qualification of any `FastPathCapable` model's optimized path against stock MLX on this Mac.
/// The test runs in a child process with a deadline, so a kernel hang or GPU fault cannot take down the serving
/// worker. The verdict is persisted per (model files, GPU family, macOS build, worker version, model fast-path
/// revision); failure is sticky for that key — never turn a failed test into a fast run.
/// Two stages (lab/notes/GATE-REVISION.md): exact components must reproduce stock's tokens, or the whole model runs
/// stock; each inexact (tolerant) component is then tested within its tolerance on top of them, and a failure there
/// disables only that component: the verdict is "fast" without it.
/// Shared by both workers (dictation `VellaWorker`, streaming `VellaStreamingWorker`); each worker supplies its own
/// `fast-selftest --model <dir>` child entry point.
public enum FastPathGate {
    /// Bumped to 8 with the component configuration in the key: a verdict persisted earlier may have
    /// been qualified under a diagnostic component override, so every model requalifies once.
    /// 9: two-stage gate with tolerance self-tests for inexact components (GATE-REVISION.md).
    /// 10: Parakeet NAX GEMMs on by default; Qwen3-ASR's BF16 audio encoder off by default.
    public static let version = "native-kernels-10"
    /// Child exit status when the self-test could not start (not a verdict on the kernels).
    public static let inconclusive: Int32 = 3
    /// Child exit status for evidence against the optimized path.
    public static let verdictFailed: Int32 = 2
    /// Child exit status: the exact components passed, some tolerant ones failed; the child names them (and why) in
    /// the file `VELLA_SELFTEST_RESULT` points to, as a JSON object component → reason.
    public static let componentsFailed: Int32 = 4
    /// Parent → child only: where the child writes the failed tolerant components.
    public static let resultVariable = "VELLA_SELFTEST_RESULT"
    /// Tolerance self-test of inexact components: at most this many word edits against stock in total over the clips.
    public static let maxTolerantWordEdits = 1
    /// Word-level Levenshtein distance.
    public static func wordEdits(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
    public static func debug(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"], path.hasPrefix("/") else { return }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
    /// The user's selection, set by the app for every worker it launches (`VELLA_RECIPE`, lab/notes/models-table-ROUND.md):
    /// `standard` = stock MLX (the VELLA_FORCE_STOCK path); `optimized_exact` = only the components whose output equals
    /// stock's (every inexact component off: `FastPathCapable.fastPathTolerantComponents`, Whisper's checkpoint-dtype
    /// encoder, Nemotron's fused layer); `optimized_fast` or unset = today's default (exact + gate-passing inexact).
    /// The two-stage self-test and the runtime stock fallback apply to every recipe.
    public enum Recipe: String { case standard, optimized_exact, optimized_fast }
    public static var recipe: Recipe {
        ProcessInfo.processInfo.environment["VELLA_RECIPE"].flatMap(Recipe.init(rawValue:)) ?? .optimized_fast
    }
    /// Optimized · Exact: inexact components stay off.
    public static var exactOnly: Bool { recipe == .optimized_exact }
    /// `VELLA_FORCE_STOCK=1` (or the older `VELLA_PARAKEET_FORCE_STOCK`) forces stock MLX for diagnosis and as the
    /// reference for fallback tests; the Standard recipe runs the same path.
    public static var forcedStock: Bool {
        let environment = ProcessInfo.processInfo.environment
        // The CPU device (lab smokes) never runs the custom Metal kernels.
        return cpuDevice || recipe == .standard || ["VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK"].contains { key in
            environment[key].map { !$0.isEmpty && $0 != "0" } ?? false
        }
    }
    /// Why the stock path runs when it is forced: the Standard selection, or a diagnosis switch.
    public static var forcedStockReason: String {
        recipe == .standard ? "Standard selected: stock MLX." : "Stock path forced for diagnosis (VELLA_FORCE_STOCK)."
    }
    /// Lab/test only: `VELLA_MLX_DEVICE=cpu` runs every MLX op on the CPU device (correctness smokes while the GPU is
    /// taken). Reported in the worker status `test_hooks`; forces stock (no custom Metal kernels).
    public static var cpuDevice: Bool { ProcessInfo.processInfo.environment["VELLA_MLX_DEVICE"] == "cpu" }
    /// Call once at worker start, before any MLX work (the global default stream is fixed at first use). Fails
    /// closed: returns false when the CPU device was requested but the default device is not the CPU.
    public static func applyDeviceOverride() -> Bool {
        guard cpuDevice else { return true }
        // `.init(.cpu)`, not the static `.cpu`: the static value realises the global streams on the GPU first.
        Device.setDefault(device: Device(.cpu))
        return Device.defaultDevice().deviceType == .cpu
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

    /// Environment switches that change which optimized components run or what they compute (diagnosis/A-B only).
    /// The effective set is part of the gate key, so a verdict qualified under an override is never reused for
    /// production defaults, and the self-test child (which inherits them) tests exactly what the worker will run.
    public static let componentSwitches = ["VELLA_PARAKEET_FAST", "VELLA_PARAKEET_FP32_FRONTEND", "VELLA_PARAKEET_NAX",
                                             "VELLA_QWEN_HOST_LENGTHS", "VELLA_QWEN_PREFILL_HEAD", "VELLA_QWEN_REFERENCE_LENGTHS",
                                             "VELLA_TEST_TOLERANT_FAULT",
                                             "VELLA_WHISPER_FUSED"]
    public static let componentSwitchPrefixes = ["VELLA_NEMO_"]
    /// "" for production defaults; otherwise the sorted `KEY=value` list of set switches.
    public static func componentConfiguration(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment.filter { key, value in
            !value.isEmpty && (componentSwitches.contains(key) || componentSwitchPrefixes.contains { key.hasPrefix($0) })
        }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    /// Every release env hook that changes behaviour or adds instrumentation, for the worker status `test_hooks`.
    /// The user's selection, set by the app for every worker (`recipe`): reported as the status's `recipe`, never in
    /// `test_hooks` (it is not a diagnosis switch).
    public static let selectionSwitches = ["VELLA_RECIPE"]
    public static let reportedSwitches = componentSwitches + ["VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK", "VELLA_WORKER_DATA_DIR",
        "VELLA_SUPPORT_DIR", "VELLA_KERNEL_DEBUG_LOG", "VELLA_KERNEL_DIAGNOSTIC_COMPONENT", "VELLA_KERNEL_DIAGNOSTIC_CLIP",
        "VELLA_PARAKEET_PROFILE", "VELLA_QWEN_PROFILE", "VELLA_QWEN_ENC_BF16", "VELLA_WHISPER_PROFILE", "VELLA_WHISPER_ENC_F16", "VELLA_STREAM_PROFILE",
        "VELLA_STUB_MODELS", "VELLA_TEST_LOAD_FAULT", "VELLA_TEST_OPTIMIZED_FAULT", "VELLA_TEST_STOCK_FAULT", "VELLA_TEST_STUB_FOOTPRINT_MB",
        "VELLA_TEST_SELFTEST_FAULT", "VELLA_TEST_DECODER_NONFINITE", "VELLA_TEST_ENCODER_NONFINITE", "VELLA_MLX_DEVICE",
        "VELLA_SELFTEST_RESULT", "VELLA_WHISPER_SEED"]
    public static func reportedEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { key, value in
            !value.isEmpty && (reportedSwitches.contains(key) || componentSwitchPrefixes.contains { key.hasPrefix($0) })
        }
    }

    public static func key(_ path: URL, revision: String) throws -> String {
        var digest = SHA256()
        // A locally derived precision: its recipe plus its source's files (one key per derived precision).
        var files = path
        if let derived = try DerivedPrecision.resolve(path) { digest.update(data: Data(derived.canonical.utf8)); files = derived.source }
        let entries = try FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: [.isRegularFileKey])
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
        let components = componentConfiguration()
        if !components.isEmpty { digest.update(data: Data(":components=\(components)".utf8)) }
        // Optimized · Exact runs other components (no inexact ones): its own verdict, never the Fast one's.
        if exactOnly { digest.update(data: Data(":recipe=exact".utf8)) }
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
    /// Tolerant components a persisted "fast" verdict leaves off, with why (`disabled.<component>` keys).
    public static func disabledComponents(_ url: URL) -> [String: String] {
        let prefix = "disabled."
        return Dictionary(uniqueKeysWithValues: (record(url) ?? [:]).compactMap { key, value in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), value) : nil
        })
    }
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
    /// `model` and `reason` are for `vella diagnose` only (the model folder's name, never its path; why it is stock);
    /// the key alone decides reuse.
    public static func persist(_ value: String, to url: URL, count: Int? = nil, model: URL? = nil, reason: String? = nil,
                               disabled: [String: String] = [:]) {
        var object = ["status": value, "workerVersion": version, "gpuFamily": gpuFamily, "osBuild": osBuild,
                      "date": ISO8601DateFormatter().string(from: Date())]
        for (component, why) in disabled { object["disabled." + component] = why }
        if let count { object["count"] = String(count) }
        if let model { object["model"] = model.lastPathComponent }
        if let reason { object["reason"] = reason }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public enum Verdict: Equatable {
        /// Optimized; `disabled` names tolerant components whose own self-test failed (component → why).
        case fast(disabled: [String: String])
        case stock(String)
    }
    /// The persisted reason of a partial verdict, e.g. "optimized without nax_gemm (self-test: word edits 3 > 1)".
    public static func partialReason(_ disabled: [String: String]) -> String {
        "optimized without " + disabled.keys.sorted().map { "\($0) (\(disabled[$0] ?? "self-test failed"))" }.joined(separator: ", ")
    }

    /// The gate decision for a model of type `type` at `path`, running the child self-test the first time.
    public static func qualify(_ path: URL, type: any FastPathCapable.Type) -> Verdict {
        qualify(path, revision: type.fastPathRevision)
    }
    /// `requiredFamily` nil: the optimized path uses no GPU-family-specific kernels (stock MLX ops only).
    public static func qualify(_ path: URL, revision: String, requiredFamily: String? = "apple9") -> Verdict {
        if forcedStock { return .stock(forcedStockReason) }
        guard let url = try? statusURL(path, revision: revision) else {
            return .stock("The optimized path could not be qualified for these model files.")
        }
        // "inconclusive" is not a verdict: the self-test runs again.
        if let previous = status(url), previous != "inconclusive" {
            return previous == "fast" ? .fast(disabled: disabledComponents(url))
                                      : .stock("The optimized path failed its self-test against stock MLX on this Mac.")
        }
        if let requiredFamily, gpuFamily != requiredFamily {
            persist("stock", to: url, model: path, reason: "GPU family \(gpuFamily), needs \(requiredFamily)")
            return .stock("The optimized kernels need Apple GPU family 9; this GPU reports \(gpuFamily).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["fast-selftest", "--model", path.path]
        // QA-only instrumentation and runtime-fallback fault injection cannot weaken the production qualification.
        var environment = ProcessInfo.processInfo.environment.filter {
            !["VELLA_KERNEL_DIAGNOSTIC_COMPONENT", "VELLA_KERNEL_DIAGNOSTIC_CLIP", "VELLA_TEST_DECODER_NONFINITE",
              "VELLA_TEST_ENCODER_NONFINITE", resultVariable].contains($0.key)
        }
        // Beside the verdicts (never *.json, so `vella diagnose` does not read it as one); removed once read.
        let result = url.deletingPathExtension().appendingPathExtension("selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: result)
        defer { try? FileManager.default.removeItem(at: result) }
        environment[resultVariable] = result.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let failed = Verdict.stock("The optimized path failed its self-test against stock MLX on this Mac.")
        do { try process.run() } catch { return recordInconclusive(url, model: path) }
        if exited.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            persist("stock", to: url, model: path, reason: "self-test timed out (45 s)")
            return .stock("The optimized path's self-test did not finish within 45 s on this Mac.")
        }
        debug("self-test child exit \(process.terminationStatus) reason \(process.terminationReason.rawValue)")
        // Verdicts are exit 0 (exact components token-exact, tolerant ones within tolerance, finite on every clip),
        // exit 2 (an exact component mismatched, non-finite output or a kernel error) and exit 4 (exact components
        // passed; the tolerant components named in the result file failed and stay off). A timeout above is evidence
        // too. Anything else (setup failure, crash, unexplained status, an unreadable result) is inconclusive: stock
        // for this load, retried next load, persisted as stock after two in a row.
        guard process.terminationReason == .exit, [0, verdictFailed, componentsFailed].contains(process.terminationStatus) else {
            return recordInconclusive(url, model: path)
        }
        if process.terminationStatus == componentsFailed {
            guard let bytes = try? Data(contentsOf: result),
                  let disabled = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: String], !disabled.isEmpty else {
                return recordInconclusive(url, model: path)
            }
            persist("fast", to: url, model: path, reason: partialReason(disabled), disabled: disabled)
            guard status(url) == "fast" else { return .stock("The self-test result could not be saved, so the optimized path stays off.") }
            return .fast(disabled: disabled)
        }
        let success = process.terminationStatus == 0
        persist(success ? "fast" : "stock", to: url, model: path, reason: success ? nil : "self-test: optimized output differs from stock MLX")
        // If persistence failed, don't enable a path that won't be tested on restart.
        guard success else { return failed }
        return status(url) == "fast" ? .fast(disabled: [:]) : .stock("The self-test result could not be saved, so the optimized path stays off.")
    }
    private static func recordInconclusive(_ url: URL, model: URL) -> Verdict {
        let count = inconclusiveCount(url) + 1
        if count >= inconclusiveLimit {
            persist("stock", to: url, model: model, reason: "self-test could not complete \(count) times in a row")
            return .stock("The optimized path's self-test could not complete on this Mac \(count) times in a row; using stock MLX.")
        }
        persist("inconclusive", to: url, count: count, model: model, reason: "self-test could not complete")
        return .stock("The optimized path's self-test could not complete on this load; using stock MLX and testing again next load.")
    }
}
