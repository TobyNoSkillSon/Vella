import Foundation

/// NeMo transducer checkpoints carry no `model_type`; this target loads as Parakeet (TDT). Mirrors the worker's
/// `admitCheckpoint`.
public let parakeetNemoTargets: Set<String> = ["nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"]
/// NVIDIA's own Nemotron 3.5 Transcribe release (the bf16 download, NeMo layout) declares `nemo_speechlm`; an imported
/// MLX export declares `nemotron_transcribe`. Mirrors the worker's admission.
public let nemotronTranscribeNemoClasses: Set<String> = ["Nemotron3_5TranscribeForConditionalGeneration"]
/// The architecture a checkpoint's config.json declares: `model_type`, else "parakeet" for a NeMo transducer target.
public func checkpointArchitecture(_ config: [String: Any]?) -> String? {
    if let type = config?["model_type"] as? String {
        if type == "nemo_speechlm", let classes = config?["architectures"] as? [String], !nemotronTranscribeNemoClasses.isDisjoint(with: classes) {
            return "nemotron_transcribe"
        }
        return type
    }
    return (config?["target"] as? String).flatMap { parakeetNemoTargets.contains($0) ? "parakeet" : nil }
}
