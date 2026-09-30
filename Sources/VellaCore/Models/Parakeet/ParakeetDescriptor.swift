/// Parakeet v3 and v3 Ultra (NeMo TDT). Runtime: Worker/Sources/MLXAudioSTT/Parakeet.
public enum ParakeetDescriptor {
    public static let descriptor = ModelDescriptor(architecture: "parakeet", mode: .dictation, preferredSegmentSeconds: nil,
                                                   calibratable: true, catalogFamilies: ["parakeet-v3", "parakeet-v3-ultra"])
}
