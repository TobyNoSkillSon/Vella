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
        signal(SIGALRM, SIG_DFL)
        if CommandLine.arguments.dropFirst().first == "calibrate" {
            let status = await CalibrationCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), output: output)
            close(output)
            exit(status)
        }
        do { try withError { Memory.cacheLimit = cacheBytes } } catch { exit(1) }
        #if VELLA_QUALIFICATION
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
                let result = try model.qualificationSnapshot(audio: MLXArray(audio.samples).asType(.bfloat16), directory: URL(fileURLWithPath: destination), referenceMel: reference)
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
        while let line = readBoundedLine(stdin) {
            if line.count <= maximumLine { alarm(120) }
            let request = line.count <= maximumLine ? try? decodeJSON(line) : nil
            var response = await worker.handle(request)
            #if VELLA_QUALIFICATION
            if CommandLine.arguments.dropFirst().first == "probe-retention" { response["retirement"] = worker.qualificationRetirement }
            #endif
            if let data = try? responseBytes(response) {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count-offset)
                        if n <= 0 { exit(1) }; offset += n
                    }
                }
            } else { exit(1) }
            alarm(0)
        }
        try? worker.release(); close(output)
    }

}
final class Worker {
    var model: (any STTGenerationModel)?
    var path: URL?
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
        model = nil; path = nil
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
    func load(_ path: URL, architecture: String) async throws -> any STTGenerationModel {
        trackCompilationCache()
        defer { trackCompilationCache() }
        switch architecture {
        case "parakeet": return try autoreleasepool { try ParakeetModel.fromDirectory(path, preserveCheckpointDTypes: true) }
        case "sensevoice": return try autoreleasepool { try SenseVoiceModel.fromDirectory(path) }
        case "whisper": return try await WhisperModel.fromDirectory(path)
        case "qwen3_asr": return try await Qwen3ASRModel.fromModelDirectory(path)
        case "granite_speech": return try await GraniteSpeechModel.fromDirectory(path)
        default: throw RequestError.invalid
        }
    }
    func infer(_ audio: Audio) throws -> String {
        guard let model else { throw RequestError.invalid }
        return try autoreleasepool { try withError {
            trackCompilationCache()
            let samples = MLXArray(audio.samples)
            let input = model is ParakeetModel ? samples.asType(.bfloat16) : samples
            let output = model.generate(audio: input, generationParameters: STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30))
            Stream.gpu.synchronize()
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } }
    }
    func handle(_ value: Any?) async -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        let request = value as? [String: Any]
        let identifier: Any = validIdentifier(request?["id"]) as Any? ?? NSNull()
        var response: [String: Any] = ["id": identifier]
        var metrics: [String: Any] = [:]
        do {
            let local: URL; let audio: Audio; let architecture: String
            do {
                guard let request, Set(request.keys) == Set(["id", "model", "audio"]), validIdentifier(request["id"]) != nil else { throw RequestError.invalid }
                local = try localPath(request["model"]); audio = try Audio(request["audio"])
                architecture = local != path ? try admit(local) : ""
            } catch { throw RequestError.invalid }
            let cold = local != path
            metrics = ["audioSeconds": audio.seconds, "modelLoaded": cold, "loadSeconds": 0.0,
                       "mlxPeakPhase": cold ? "load_and_first_request" : "warm_request", "allocatorCacheLimitBytes": cacheBytes]
            if cold { try release() }
            Memory.peakMemory = 0
            if cold {
                let t = ProcessInfo.processInfo.systemUptime
                model = try await withError { try await load(local, architecture: architecture) }
                Stream.gpu.synchronize(); path = local
                metrics["loadSeconds"] = ProcessInfo.processInfo.systemUptime-t
                metrics["loadPeakMLXBytes"] = Memory.peakMemory
            }
            let t = ProcessInfo.processInfo.systemUptime
            let text = try infer(audio)
            Stream.gpu.synchronize()
            metrics["inferenceSeconds"] = ProcessInfo.processInfo.systemUptime-t
            metrics["peakMLXBytes"] = Memory.peakMemory
            response["text"] = text
        } catch {
            let text = String(describing: error).lowercased()
            let memory = ["out of memory", "memory allocation", "metal allocation", "insufficient memory"].contains { text.contains($0) }
            let code = error is RequestError ? "invalid" : memory ? "memory" : "inference"
            response["error"] = ["code": code, "message": code == "invalid" ? "Invalid local transcription request." : code == "memory" ? "Insufficient memory for transcription." : "Local transcription failed."]
            if code != "invalid" { try? release() }
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
