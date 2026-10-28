import VellaWire

/// Nemotron 3.5 Transcribe 30B-A4B: an offline speech language model for Dictation (the text arrives once the segment
/// is encoded). Runtime: Worker/Sources/MLXAudioSTT/NemotronTranscribe. Its tiers are three downloads (NVIDIA's bf16 and
/// Vella's mixed int8 and int4), each gated by this Mac's memory (MemoryFit.swift). No local calibration: Vella never
/// loads a 21–70 GB model by itself. An offline speech language model gains from context: recordings are cut at a
/// pause only after 20 s, as for Whisper. No separately qualified fast path (the worker's `hasFastPath` is false): Fast
/// and Exact run the same recipe, so the switch is pinned to Fast.
public enum NemotronTranscribeDescriptor {
    public static let descriptor = ModelDescriptor(
        architecture: .nemotronTranscribe, mode: .dictation, preferredSegmentSeconds: 20,
        calibratable: false, catalogFamilies: ["nemotron-3.5-transcribe"], hasFastPath: false)
}
