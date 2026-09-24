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
        do { try withError { Memory.cacheLimit = cacheBytes } } catch { exit(1) }
        let worker = Worker()
        while let line = readBoundedLine(stdin) {
            if line.count <= maximumLine { alarm(120) }
            let request = line.count <= maximumLine ? try? decodeJSON(line) : nil
            let response = await worker.handle(request)
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
    func cleanup() throws { try withError { Stream.gpu.synchronize(); Memory.clearCache() } }
    func release() throws {
        model = nil; path = nil
        try withError {
            Stream.gpu.synchronize()
            // This process owns every compiled graph. Clear captured weight constants
            // as well as allocator buffers before admitting the next model.
            var cache = mlx_compile_cache_new()
            mlx_detail_compile_cache(&cache)
            defer { mlx_compile_cache_free(cache) }
            mlx_detail_compile_clear_cache(cache)
        }
        try cleanup()
    }
    func load(_ path: URL, architecture: String) async throws -> any STTGenerationModel {
        switch architecture {
        case "parakeet": return try autoreleasepool { try ParakeetModel.fromDirectory(path, preserveCheckpointDTypes: true) }
        case "sensevoice": return try autoreleasepool { try SenseVoiceModel.fromDirectory(path) }
        case "whisper": return try await WhisperModel.fromDirectory(path)
        case "qwen3_asr": return try await Qwen3ASRModel.fromModelDirectory(path)
        case "granite_speech": return try await GraniteSpeechModel.fromDirectory(path)
        default: throw RequestError.invalid
        }
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
            let result = try autoreleasepool { try withError {
                // Python Parakeet.generate defaults its waveform dtype to bfloat16.
                let samples = MLXArray(audio.samples)
                let input = model is ParakeetModel ? samples.asType(.bfloat16) : samples
                let output = model!.generate(audio: input, generationParameters: STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30))
                Stream.gpu.synchronize()
                return output
            } }
            Stream.gpu.synchronize()
            metrics["inferenceSeconds"] = ProcessInfo.processInfo.systemUptime-t
            metrics["peakMLXBytes"] = Memory.peakMemory
            response["text"] = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
