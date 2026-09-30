/// A checkpoint architecture: config.json's `model_type`, or `parakeet` for the NeMo TDT target. The raw values are
/// what config files, the worker status and the catalog spell.
public enum Architecture: String, Codable, CaseIterable, Sendable {
    case parakeet
    case qwen3ASR = "qwen3_asr"
    case whisper
    case nemotronASR = "nemotron_asr"
    /// Test models (`VELLA_STUB_MODELS=1` only).
    case stub
}
