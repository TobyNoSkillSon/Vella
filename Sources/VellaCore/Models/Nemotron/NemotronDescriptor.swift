import VellaWire

/// Nemotron 3.5 streaming (the Streaming mode's model). Runtime: Worker/Sources/MLXAudioSTT/NemotronASR.
public enum NemotronDescriptor {
    public static let descriptor = ModelDescriptor(
        architecture: .nemotronASR, mode: .streaming, preferredSegmentSeconds: nil,
        calibratable: false, catalogFamilies: ["nemotron-3.5-streaming-0.6b"])
}
