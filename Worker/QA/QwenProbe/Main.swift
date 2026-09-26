// QA only: load a Qwen3-ASR or Whisper checkpoint once, transcribe a list of
// 16 kHz clips exactly as VellaWorker.infer does (maxTokens 1024, 30 s chunks,
// language auto), and print one JSON line per clip with timing, token IDs and
// (VELLA_QWEN_PROFILE=1) the phase split. Not shipped.
//
// VellaQwenProbe --model DIR --list FILE [--repeat N] [--quantize 4|8] [--warmup PATH]
import Foundation
import MLX
import MLXNN
import MLXAudioCore
import MLXAudioSTT

@main struct Probe {
    static func main() async throws {
        Memory.cacheLimit = 64 * 1024 * 1024
        var options: [String: String] = [:]
        var args = Array(CommandLine.arguments.dropFirst())
        while args.count >= 2 { options[args[0]] = args[1]; args.removeFirst(2) }
        guard let modelPath = options["--model"], let list = options["--list"] else {
            FileHandle.standardError.write(Data("usage: VellaQwenProbe --model DIR --list FILE\n".utf8)); exit(2)
        }
        let repeats = Int(options["--repeat"] ?? "1") ?? 1
        let url = URL(fileURLWithPath: modelPath)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("config.json"))) as! [String: Any]
        let t0 = ProcessInfo.processInfo.systemUptime
        let model: any STTGenerationModel
        if config["model_type"] as? String == "whisper" {
            model = try await WhisperModel.fromDirectory(url)
        } else {
            let qwen = try await Qwen3ASRModel.fromModelDirectory(url)
            if let bits = options["--quantize"].flatMap(Int.init) {
                quantize(model: qwen, groupSize: 64, bits: bits) { path, module in
                    !path.hasPrefix("audio_tower") && (module is Linear || module is Embedding)
                }
                eval(qwen); Memory.clearCache()
            }
            model = qwen
        }
        Stream.gpu.synchronize()
        let loadSeconds = ProcessInfo.processInfo.systemUptime - t0
        let files = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let parameters = STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30)
        func run(_ path: String) throws -> (String, Double, Double, [Int]) {
            let (_, audio) = try loadAudioArray(from: URL(fileURLWithPath: path), sampleRate: 16000)
            let samples = audio.dim(0) > 480000 ? audio[0..<480000] : audio
            eval(samples)
            let t = ProcessInfo.processInfo.systemUptime
            let output = model.generate(audio: samples, generationParameters: parameters)
            Stream.gpu.synchronize()
            let tokens = (model as? Qwen3ASRModel)?.lastTokens ?? []
            return (output.text.trimmingCharacters(in: .whitespacesAndNewlines), Double(samples.dim(0)) / 16000,
                    ProcessInfo.processInfo.systemUptime - t, tokens)
        }
        if let warm = options["--warmup"] ?? files.first { _ = try run(warm) }
        Memory.peakMemory = 0
        for r in 0..<repeats {
            for path in files {
                (model as? Qwen3ASRModel)?.profile = .init()
                let (text, audioSeconds, seconds, tokens) = try run(path)
                var line: [String: Any] = ["file": path, "repeat": r, "text": text, "audio_s": audioSeconds, "s": seconds, "tokens": tokens]
                if Qwen3ASRModel.profiling, let p = (model as? Qwen3ASRModel)?.profile {
                    line["profile"] = ["mel": p.mel, "encoder": p.encoder, "prefill": p.prefill, "decode": p.decode,
                                       "decode_wait": p.decodeWait, "prompt": p.prompt, "conv": p.conv, "layers": p.layers, "prompt_tokens": p.promptTokens, "steps": p.decodeSteps]
                }
                let bytes = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                FileHandle.standardOutput.write(bytes + Data([10]))
            }
        }
        let summary: [String: Any] = ["summary": true, "load_s": loadSeconds, "peak_mlx_bytes": Memory.peakMemory, "active_mlx_bytes": Memory.activeMemory]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) + Data([10]))
    }
}
