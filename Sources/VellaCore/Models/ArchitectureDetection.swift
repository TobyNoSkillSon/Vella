import Foundation

/// NeMo transducer checkpoints carry no `model_type`; this target loads as Parakeet (TDT). Mirrors the worker's
/// `admitCheckpoint`.
public let parakeetNemoTargets: Set<String> = ["nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"]
/// The architecture a checkpoint's config.json declares: `model_type`, else "parakeet" for a NeMo transducer target.
public func checkpointArchitecture(_ config: [String: Any]?) -> String? {
    if let type = config?["model_type"] as? String { return type }
    return (config?["target"] as? String).flatMap { parakeetNemoTargets.contains($0) ? "parakeet" : nil }
}
