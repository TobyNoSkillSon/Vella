import Foundation
import Darwin
import MLXAudioSTT
import VellaWorkerSupport
import VellaWire

let maximumLine = 16 * 1024
let cacheBytes = 64 * 1024 * 1024

func admit(_ path: URL) throws -> Architecture {
    // A locally derived precision: admit its float source; only architectures with a derivation path.
    guard let derived = try DerivedPrecision.resolve(path) else { return try admitCheckpoint(path) }
    let architecture = try admitCheckpoint(derived.source)
    let source = try jsonObject(derived.source.appendingPathComponent("config.json"))
    guard [.parakeet, .whisper, .qwen3ASR, .nemotronTranscribe].contains(architecture), !pythonTruthy(source["quantization"]),
        !pythonTruthy(source["quantization_config"])
    else { throw RequestError.invalid }
    return architecture
}
func admitCheckpoint(_ path: URL) throws -> Architecture {
    let config = try jsonObject(path.appendingPathComponent("config.json"))
    if let value = config["model_type"], !(value is NSNull), !(value is String) { throw RequestError.invalid }
    var architecture = config["model_type"] as? String
    // NeMo transducer checkpoints carry no model_type (the catalog's MLX Parakeet); only TDT ones load.
    if architecture == nil, config["target"] as? String == "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel" { architecture = "parakeet" }
    // Nemotron 3.5 Transcribe: Vella's MLX tiers say so; NVIDIA's BF16 original is a NeMo SpeechLM with that class.
    if architecture == "nemo_speechlm", (config["architectures"] as? [String])?.contains("Nemotron3_5TranscribeForConditionalGeneration") == true {
        architecture = "nemotron_transcribe"
    }
    if architecture == "nemotron_transcribe" {
        guard (config["llm_config"] as? [String: Any])?["model_type"] as? String == "nemotron_h",
            (config["prompt_format"] as? String ?? "nemotron3p5") == "nemotron3p5"
        else { throw RequestError.invalid }
    }
    let stub = StubModel.enabled && architecture == "stub" // Test hook, reported in status.
    guard let name = architecture, stub || ["parakeet", "qwen3_asr", "whisper", "nemotron_transcribe"].contains(name),
        let architecture = Architecture(rawValue: name)
    else { throw RequestError.invalid }
    let rawQuant = pythonTruthy(config["quantization"]) ? config["quantization"] : pythonTruthy(config["quantization_config"]) ? config["quantization_config"] : [:]
    guard let quant = rawQuant as? [String: Any] else { throw RequestError.invalid }
    if let bits = quant["bits"], !(bits is NSNull) {
        guard let n = bits as? NSNumber else { throw RequestError.invalid }
        // Never below 4 bits (the catalog's quantized precisions are 4- and 8-bit).
        guard n == 4 || n == 8 else { throw RequestError.invalid }
    }
    for name in ["config.json", "tokenizer_config.json"] {
        let url = path.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            let object = try jsonObject(url)
            if pythonTruthy(object["auto_map"]) { throw RequestError.invalid }
        }
    }
    guard let entries = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil) else { throw RequestError.invalid }
    for case let file as URL in entries where file.pathExtension == "py" { throw RequestError.invalid }
    guard try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).contains(where: { $0.pathExtension == "safetensors" }) else {
        throw RequestError.invalid
    }
    return architecture
}
