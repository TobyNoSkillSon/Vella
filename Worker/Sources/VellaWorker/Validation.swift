import Foundation
import Darwin
import MLXAudioSTT
import VellaWorkerSupport

let maximumLine = 16 * 1024
let cacheBytes = 64 * 1024 * 1024

func admit(_ path: URL) throws -> String {
    // A locally derived precision: admit its float source; only architectures with a derivation path.
    guard let derived = try DerivedPrecision.resolve(path) else { return try admitCheckpoint(path) }
    let architecture = try admitCheckpoint(derived.source)
    let source = try jsonObject(derived.source.appendingPathComponent("config.json"))
    guard ["parakeet", "whisper", "qwen3_asr"].contains(architecture), !pythonTruthy(source["quantization"]),
          !pythonTruthy(source["quantization_config"]) else { throw RequestError.invalid }
    return architecture
}
func admitCheckpoint(_ path: URL) throws -> String {
    let config = try jsonObject(path.appendingPathComponent("config.json"))
    if let value = config["model_type"], !(value is NSNull), !(value is String) { throw RequestError.invalid }
    var architecture = config["model_type"] as? String
    // NeMo transducer checkpoints carry no model_type (the catalog's MLX Parakeet); only TDT ones load.
    if architecture == nil, config["target"] as? String == "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel" { architecture = "parakeet" }
    let stub = StubModel.enabled && architecture == "stub" // Test hook, reported in status.
    guard let architecture, stub || ["parakeet", "qwen3_asr", "whisper"].contains(architecture) else { throw RequestError.invalid }
    let rawQuant = pythonTruthy(config["quantization"]) ? config["quantization"] :
        pythonTruthy(config["quantization_config"]) ? config["quantization_config"] : [:]
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
    guard try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).contains(where: { $0.pathExtension == "safetensors" }) else { throw RequestError.invalid }
    return architecture
}
