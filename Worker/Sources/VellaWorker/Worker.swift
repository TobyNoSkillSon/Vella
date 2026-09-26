import Foundation
import Darwin
import MLX
import Cmlx
import MLXAudioSTT

@main struct Main {
    static func main() async {
        let output = dup(STDOUT_FILENO)
        let sink = open("/dev/null", O_WRONLY)
        guard output >= 0, sink >= 0 else { exit(1) }
        dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO); close(sink)
        guard installOfflineSandbox() else { exit(1) }
        guard FastPathGate.applyDeviceOverride() else { exit(1) }
        signal(SIGALRM, SIG_DFL)
        if CommandLine.arguments.dropFirst().first == "fast-selftest" {
            let values = Array(CommandLine.arguments.dropFirst(2))
            guard values.count == 2, values[0] == "--model", let path = try? localPath(values[1]),
                  let architecture = try? admit(path), Worker.fastPathType(architecture) != nil else { exit(FastPathGate.inconclusive) }
            // Test hook (reported in status): an unexplained child exit, or evidence against the fast path.
            switch ProcessInfo.processInfo.environment["VELLA_TEST_SELFTEST_FAULT"] {
            case "crash": abort()
            case "exit": exit(9)
            case "mismatch": exit(FastPathGate.verdictFailed)
            default: break
            }
            let passed: Bool
            do {
                let worker = Worker()
                // A setup failure says nothing about the kernels: inconclusive, not a sticky verdict.
                guard let model = try? await withError({ try await worker.loadStock(path, architecture: architecture) }),
                      let capable = model as? any FastPathCapable else { exit(FastPathGate.inconclusive) }
                passed = try withError { try FastPathGate.runSelfTest(capable, input: { Worker.input(for: model, $0) }) }
            } catch {
                if let log = ProcessInfo.processInfo.environment["VELLA_KERNEL_DEBUG_LOG"], log.hasPrefix("/") {
                    try? String(describing: error).write(toFile: log, atomically: true, encoding: .utf8)
                }
                passed = false
            }
            exit(passed ? 0 : FastPathGate.verdictFailed)
        }
        if CommandLine.arguments.dropFirst().first == "calibrate" {
            let status = await CalibrationCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), output: output)
            close(output)
            exit(status)
        }
        do { try withError { Memory.cacheLimit = cacheBytes } } catch { exit(1) }
        #if VELLA_QUALIFICATION
        if CommandLine.arguments.dropFirst().first == "describe-model" {
            exit(await DescribeModel.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        if CommandLine.arguments.dropFirst().first == "probe-parakeet" {
            alarm(120)
            do {
                let values = Array(CommandLine.arguments.dropFirst(2))
                guard values.count == 6 || values.count == 8 else { throw RequestError.invalid }
                let options = Dictionary(uniqueKeysWithValues: stride(from: 0, to: values.count, by: 2).map { (values[$0], values[$0+1]) })
                let path = try localPath(options["--model"])
                guard try admit(path) == "parakeet", let destination = options["--output"], destination.hasPrefix("/") else { throw RequestError.invalid }
                let audio = try Audio(options["--audio"])
                let model = try ParakeetModel.fromDirectory(path, preserveCheckpointDTypes: true)
                let reference = try options["--reference"].map { try MLX.loadArrays(url: URL(fileURLWithPath: $0))["mel"] } ?? nil
                let result = try model.qualificationSnapshot(audio: MLXArray(audio.samples).asType(ParakeetModel.inputDType), directory: URL(fileURLWithPath: destination), referenceMel: reference)
                let bytes = try responseBytes(result)
                bytes.withUnsafeBytes { _ = Darwin.write(output, $0.baseAddress, $0.count) }
                exit(0)
            } catch {
                let bytes = try! responseBytes(["error": "Qualification probe failed."])
                bytes.withUnsafeBytes { _ = Darwin.write(output, $0.baseAddress, $0.count) }
                exit(1)
            }
        }
        #endif
        let worker = Worker()
        worker.push = { status in
            guard let data = try? responseBytes(["status": status]), writeAll(output, data) else { exit(1) }
        }
        while let line = readBoundedLine(stdin) {
            // Lab CPU device (VELLA_MLX_DEVICE=cpu, reported in test_hooks): CPU inference is far slower; 1 h deadline.
            if line.count <= maximumLine { alarm(FastPathGate.cpuDevice ? 3600 : 120) }
            let request = line.count <= maximumLine ? try? decodeJSON(line) : nil
            var response = await worker.handle(request)
            #if VELLA_QUALIFICATION
            if CommandLine.arguments.dropFirst().first == "probe-retention" { response["retirement"] = worker.qualificationRetirement }
            #endif
            guard let data = try? responseBytes(response), writeAll(output, data) else { exit(1) }
            alarm(0)
        }
        // stdin EOF: the app is gone or retired this worker. Exit; never outlive the app.
        try? worker.release(); close(output)
    }
}
func writeAll(_ output: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count-offset)
            if n <= 0 { return false }; offset += n
        }
        return true
    }
}

enum InjectedFault: Error { case load, optimized, stock }

/// One worker process serves one model at a time. The app runs one process per loaded model, so unloading is
/// normally the process exiting; `unload` also works in place (load → unload returns MLX memory to baseline).
/// Every change pushes one `{"status": …}` line before its response.
final class Worker {
    var model: (any STTGenerationModel)?
    var path: URL?
    var push: (([String: Any]) -> Void)?
    private var architecture: String?
    private var loadSeconds: Double?
    /// nil = optimized path active; otherwise why the model runs on stock MLX.
    private var stockReason: String? = "No model loaded."
    private var optimizations: [String: Bool] = [:]
    private var gateURL: URL?
    #if VELLA_QUALIFICATION
    var qualificationRetirement: [String: Any] = [:]
    #endif
    // MLX 0.32.2's compile cache is thread_local, not process-global. Async
    // requests can migrate between Swift executor threads. Retain weak handles
    // to every cache actually used, then clear those exact caches on retirement.
    private var compilationCaches: [UInt64: mlx_compile_cache] = [:]
    private func clearCompilationCaches() {
        for cache in compilationCaches.values {
            mlx_detail_compile_clear_cache(cache)
            mlx_compile_cache_free(cache)
        }
        compilationCaches.removeAll()
    }
    private func trackCompilationCache() {
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        guard compilationCaches[threadID] == nil else { return }
        // Bounded even under executor thread churn; no generation is in flight here.
        if compilationCaches.count == 64 { clearCompilationCaches() }
        var cache = mlx_compile_cache_new()
        mlx_detail_compile_cache(&cache)
        compilationCaches[threadID] = cache
    }
    func cleanup() throws { try withError { Stream.gpu.synchronize(); Memory.clearCache() } }
    func release() throws {
        #if VELLA_QUALIFICATION
        let references = qualificationReferences(model)
        let cacheThreads = Array(compilationCaches.keys)
        #endif
        model = nil; path = nil; architecture = nil; loadSeconds = nil; gateURL = nil
        stockReason = "No model loaded."; optimizations = [:]
        try withError {
            Stream.gpu.synchronize()
            STTRuntime.clearModelIndependentCaches()
            clearCompilationCaches()
        }
        try cleanup()
        #if VELLA_QUALIFICATION
        var thread: UInt64 = 0; pthread_threadid_np(nil, &thread)
        qualificationRetirement = ["activeBytes": Memory.activeMemory, "cacheBytes": Memory.cacheMemory, "thread": thread, "capturedCacheThreads": cacheThreads,
            "retained": references.compactMap { name, reference -> [String: Any]? in
                guard let object = reference.value else { return nil }
                return ["name": name, "bytes": (object as? MLXArray)?.nbytes ?? 0]
            }]
        #endif
    }

    /// The model class for an architecture, if it has an optimized path (any `FastPathCapable` model qualifies).
    static func fastPathType(_ architecture: String) -> (any FastPathCapable.Type)? {
        let type: Any.Type
        switch architecture {
        case "parakeet": type = ParakeetModel.self
        case "sensevoice": type = SenseVoiceModel.self
        case "whisper": type = WhisperModel.self
        case "qwen3_asr": type = Qwen3ASRModel.self
        case "granite_speech": type = GraniteSpeechModel.self
        case "stub": type = StubModel.self
        default: return nil
        }
        return type as? any FastPathCapable.Type
    }
    static func input(for model: any STTGenerationModel, _ samples: MLXArray) -> MLXArray {
        model is ParakeetModel ? samples.asType(ParakeetModel.inputDType) : samples
    }
    /// Stock load, no fast path configured.
    func loadStock(_ path: URL, architecture: String) async throws -> any STTGenerationModel {
        if let derived = try DerivedPrecision.resolve(path) {
            guard architecture == "parakeet" else { throw RequestError.invalid }
            return try autoreleasepool { try ParakeetModel.fromDirectory(derived.source, preserveCheckpointDTypes: true, derived: derived) }
        }
        switch architecture {
        case "parakeet": return try autoreleasepool { try ParakeetModel.fromDirectory(path, preserveCheckpointDTypes: true) }
        case "sensevoice": return try autoreleasepool { try SenseVoiceModel.fromDirectory(path) }
        case "whisper": return try await WhisperModel.fromDirectory(path)
        case "qwen3_asr": return try await Qwen3ASRModel.fromModelDirectory(path)
        case "granite_speech": return try await GraniteSpeechModel.fromDirectory(path)
        case "stub" where StubModel.enabled: return StubModel(path)
        default: throw RequestError.invalid
        }
    }
    /// Load, then enable the optimized path only if the gate qualified it for this exact key.
    func load(_ path: URL, architecture: String) async throws -> any STTGenerationModel {
        trackCompilationCache()
        defer { trackCompilationCache() }
        if let fault = ProcessInfo.processInfo.environment["VELLA_TEST_LOAD_FAULT"], !fault.isEmpty, path.path.contains(fault) {
            throw InjectedFault.load
        }
        let type = Self.fastPathType(architecture)
        let verdict = type.map { FastPathGate.qualify(path, type: $0) }
        gateURL = type.flatMap { try? FastPathGate.statusURL(path, revision: $0.fastPathRevision) }
        let loaded = try await loadStock(path, architecture: architecture)
        self.architecture = architecture
        optimizations = [:]
        if let capable = loaded as? any FastPathCapable, let verdict {
            switch verdict {
            case .fast:
                if capable.configureFastPath(enabled: true, component: "both") {
                    stockReason = nil; optimizations = capable.fastPathComponents
                } else {
                    if let gateURL { FastPathGate.persist("stock", to: gateURL, model: path, reason: "optimized path unsupported for this checkpoint") }
                    stockReason = "The optimized path does not support this checkpoint."
                }
            case .stock(let reason):
                stockReason = reason
                optimizations = capable.fastPathComponents.mapValues { _ in false }
            }
        } else {
            stockReason = "No optimized path for this model yet."
        }
        return loaded
    }
    private var optimizedFault: String? { ProcessInfo.processInfo.environment["VELLA_TEST_OPTIMIZED_FAULT"].flatMap { $0.isEmpty ? nil : $0 } }
    private var stockFault: Bool { ProcessInfo.processInfo.environment["VELLA_TEST_STOCK_FAULT"] == "1" }
    private func runStock(_ model: any STTGenerationModel, _ input: MLXArray, _ parameters: STTGenerateParameters) throws -> STTOutput {
        if stockFault { throw InjectedFault.stock }
        return try withError { model.generate(audio: input, generationParameters: parameters) }
    }
    private func runOptimized(_ model: any STTGenerationModel, _ capable: any FastPathCapable, _ input: MLXArray, _ parameters: STTGenerateParameters) throws -> STTOutput {
        if optimizedFault == "throw" { throw InjectedFault.optimized }
        let output = try withError { model.generate(audio: input, generationParameters: parameters) }
        if optimizedFault == "nonfinite" || !capable.fastPathFinite { throw FastPathNonFinite.invalid }
        return output
    }
    /// Runtime fallback: the optimized path throws or returns non-finite values → the whole request reruns on stock.
    /// Stock succeeds → the model stays on stock until it reloads. Stock fails too → the request was at fault:
    /// the optimized path is restored and the stock error returned.
    func infer(_ audio: Audio) throws -> String {
        guard let model else { throw RequestError.invalid }
        return try autoreleasepool { try withError {
            trackCompilationCache()
            let input = Self.input(for: model, MLXArray(audio.samples))
            let parameters = STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30)
            var output: STTOutput
            if stockReason == nil, let capable = model as? any FastPathCapable {
                do { output = try runOptimized(model, capable, input, parameters) }
                catch {
                    let cause = error is FastPathNonFinite ? "returned non-finite values" : "failed"
                    _ = capable.configureFastPath(enabled: false, component: "both")
                    Stream.gpu.synchronize()
                    clearCompilationCaches()
                    trackCompilationCache()
                    do { output = try runStock(model, input, parameters) }
                    catch {
                        if !capable.configureFastPath(enabled: true, component: "both") {
                            stockReason = "The optimized path could not be restored after a failed request."
                        }
                        push?(status("fallback-failed"))
                        throw error
                    }
                    stockReason = "Runtime fallback: the optimized path \(cause) on a request; stock MLX until the model reloads."
                    optimizations = optimizations.mapValues { _ in false }
                    push?(status("fallback"))
                }
            } else {
                output = try runStock(model, input, parameters)
            }
            Stream.gpu.synchronize()
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } }
    }
    static let gpu: [String: Any] = {
        var size = 0
        var chip = "Unknown"
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 { chip = String(cString: bytes) }
        }
        return ["chip": chip, "family": FastPathGate.gpuFamily]
    }()
    func status(_ event: String) -> [String: Any] {
        // Every behaviour-changing or instrumenting env hook, component overrides included.
        let hooks = FastPathGate.reportedEnvironment()
        var memory: [String: Any] = ["mlx_active_mb": Double(Memory.activeMemory) / 1e6, "mlx_cache_mb": Double(Memory.cacheMemory) / 1e6]
        if let footprint = processMemory()["processFootprintBytes"] { memory["footprint_mb"] = Double(footprint) / 1e6 }
        if model is StubModel, let stub = ProcessInfo.processInfo.environment["VELLA_TEST_STUB_FOOTPRINT_MB"].flatMap(Double.init) {
            memory["footprint_mb"] = stub
        }
        var object: [String: Any] = [
            "worker": "dictation", "pid": Int(getpid()), "version": FastPathGate.version, "event": event,
            "model": path?.path ?? NSNull(), "architecture": architecture ?? NSNull(),
            "engine": model == nil ? NSNull() : (stockReason == nil ? "optimized" : "mlx"),
            "engine_reason": model == nil ? NSNull() : (stockReason ?? NSNull()),
            "optimizations": optimizations, "load_s": loadSeconds ?? NSNull(), "memory": memory, "gpu": Self.gpu,
        ]
        if !hooks.isEmpty { object["test_hooks"] = hooks }
        return object
    }

    private func loadIfNeeded(_ local: URL, architecture: String, metrics: inout [String: Any]) async throws {
        guard local != path else { return }
        try release()
        Memory.peakMemory = 0
        let t = ProcessInfo.processInfo.systemUptime
        do {
            model = try await withError { try await load(local, architecture: architecture) }
            Stream.gpu.synchronize(); path = local
        } catch {
            try? release(); push?(status("load-failed")); throw error
        }
        loadSeconds = ProcessInfo.processInfo.systemUptime - t
        metrics["loadSeconds"] = loadSeconds
        metrics["loadPeakMLXBytes"] = Memory.peakMemory
        push?(status("load"))
    }
    private static func failure(_ error: Error) -> [String: Any] {
        let text = String(describing: error).lowercased()
        let memory = ["out of memory", "memory allocation", "metal allocation", "insufficient memory"].contains { text.contains($0) }
        let code = error is RequestError ? "invalid" : memory ? "memory" : "inference"
        return ["code": code, "message": code == "invalid" ? "Invalid local transcription request." : code == "memory" ? "Insufficient memory for transcription." : "Local transcription failed."]
    }

    func handle(_ value: Any?) async -> [String: Any] {
        let request = value as? [String: Any]
        let identifier: Any = validIdentifier(request?["id"]) as Any? ?? NSNull()
        guard let request, validIdentifier(request["id"]) != nil else {
            return ["id": identifier, "error": ["code": "invalid", "message": "Invalid local transcription request."]]
        }
        guard let op = request["op"] else { return await transcribe(request, identifier: identifier) }
        let keys = Set(request.keys)
        switch op as? String {
        case "load":
            guard keys == ["id", "op", "model"], let local = try? localPath(request["model"]),
                  let architecture = try? (local == path ? self.architecture ?? admit(local) : admit(local)) else { break }
            var metrics: [String: Any] = [:]
            do {
                if local == path { push?(status("load")) }
                else { try await loadIfNeeded(local, architecture: architecture, metrics: &metrics) }
                try cleanup()
                return ["id": identifier, "loaded": true, "metrics": metrics]
            } catch {
                var failure = Self.failure(error)
                if failure["code"] as? String == "inference" { failure = ["code": "load", "message": "The model failed to load."] }
                return ["id": identifier, "error": failure]
            }
        case "unload":
            guard keys == ["id", "op"] else { break }
            try? release()
            push?(status("unload"))
            return ["id": identifier, "unloaded": true]
        case "status":
            guard keys == ["id", "op"] else { break }
            push?(status("status"))
            return ["id": identifier, "ok": true]
        case "trim":
            guard keys == ["id", "op"] else { break }
            try? cleanup()
            push?(status("trim"))
            return ["id": identifier, "ok": true]
        default: break
        }
        return ["id": identifier, "error": ["code": "invalid", "message": "Invalid local transcription request."]]
    }

    private func transcribe(_ request: [String: Any], identifier: Any) async -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        var response: [String: Any] = ["id": identifier]
        var metrics: [String: Any] = [:]
        var keepModel = false
        do {
            let local: URL; let audio: Audio; let architecture: String
            do {
                guard Set(request.keys) == Set(["id", "model", "audio"]) else { throw RequestError.invalid }
                local = try localPath(request["model"]); audio = try Audio(request["audio"])
                architecture = local != path ? try admit(local) : ""
            } catch { throw RequestError.invalid }
            let cold = local != path
            metrics = ["audioSeconds": audio.seconds, "modelLoaded": cold, "loadSeconds": 0.0,
                       "mlxPeakPhase": cold ? "load_and_first_request" : "warm_request", "allocatorCacheLimitBytes": cacheBytes]
            if cold { try await loadIfNeeded(local, architecture: architecture, metrics: &metrics) } else { Memory.peakMemory = 0 }
            let t = ProcessInfo.processInfo.systemUptime
            do { response["text"] = try infer(audio) }
            catch {
                // Both paths failed on this request: the model itself is intact (restored optimized path).
                keepModel = stockReason == nil
                throw error
            }
            Stream.gpu.synchronize()
            metrics["inferenceSeconds"] = ProcessInfo.processInfo.systemUptime-t
            metrics["peakMLXBytes"] = Memory.peakMemory
        } catch {
            let failure = Self.failure(error)
            response["error"] = failure
            if failure["code"] as? String != "invalid" && !keepModel, model != nil { try? release(); push?(status("unload")) }
        }
        let t = ProcessInfo.processInfo.systemUptime
        do { try cleanup() } catch {
            model = nil; path = nil
            return ["id": identifier, "error": ["code": "memory", "message": "Insufficient memory for transcription."]]
        }
        if response["text"] != nil {
            metrics["cleanupSeconds"] = ProcessInfo.processInfo.systemUptime-t
            metrics["requestSeconds"] = ProcessInfo.processInfo.systemUptime-start
            metrics["activeMLXBytes"] = Memory.activeMemory; metrics["cacheMLXBytes"] = Memory.cacheMemory
            for (key, value) in processMemory() { metrics[key] = value }
            response["metrics"] = metrics
        }
        return response
    }
}
