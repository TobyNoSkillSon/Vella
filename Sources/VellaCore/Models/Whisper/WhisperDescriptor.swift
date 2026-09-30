import VellaWire

/// Whisper large-v3 and large-v3 turbo. Runtime: Worker/Sources/MLXAudioSTT/Whisper.
/// Whisper was trained on 30-s windows and hallucinates on short, cut-up input: recordings are cut at a pause only
/// after 20 s.
public enum WhisperDescriptor {
    public static let descriptor = ModelDescriptor(architecture: .whisper, mode: .dictation, preferredSegmentSeconds: 20,
                                                   calibratable: true, catalogFamilies: ["whisper-large-v3", "whisper-large-v3-turbo"])
}
