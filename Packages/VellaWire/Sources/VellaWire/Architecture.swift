/// A checkpoint architecture: config.json's `model_type`, or `parakeet` for the NeMo TDT target. The raw values are
/// what config files, the worker status and the catalog spell.
public enum Architecture: String, Codable, CaseIterable, Sendable {
    case parakeet
    case qwen3ASR = "qwen3_asr"
    case whisper
    case nemotronASR = "nemotron_asr"
    /// Nemotron 3.5 Transcribe 30B-A4B: offline speech LLM (speech + speaker encoders, Nemotron-H decoder).
    case nemotronTranscribe = "nemotron_transcribe"
    /// Test models (`VELLA_STUB_MODELS=1` only).
    case stub
}
