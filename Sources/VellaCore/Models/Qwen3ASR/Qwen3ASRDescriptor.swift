import VellaWire

/// Qwen3 ASR 1.7B and 0.6B. Runtime: Worker/Sources/MLXAudioSTT/Qwen3ASR.
public enum Qwen3ASRDescriptor {
    public static let descriptor = ModelDescriptor(
        architecture: .qwen3ASR, mode: .dictation, preferredSegmentSeconds: nil,
        calibratable: true, catalogFamilies: ["qwen3-asr-1.7b", "qwen3-asr-0.6b"])
}
