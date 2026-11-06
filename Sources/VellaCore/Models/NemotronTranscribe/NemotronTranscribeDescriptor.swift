import VellaWire

/// Nemotron 3.5 Transcribe 30B-A4B: an offline speech language model for Dictation (the text arrives once the segment
/// is encoded). Runtime: Worker/Sources/MLXAudioSTT/NemotronTranscribe. Get downloads NVIDIA's bf16 release; int8 and int4
/// are made from it at load like every family's, with this architecture's mix applied by the worker's loader. Each tier
/// is gated by this Mac's memory (MemoryFit.swift). No local calibration: Vella never loads a 21–70 GB model by itself. An offline speech language model gains from context: recordings are cut at a
/// pause only after 20 s, as for Whisper. Fast decodes with the multi-token-prediction head (draft and verify), which can
/// differ from plain greedy decoding on near-tie tokens; Exact turns it off.
public enum NemotronTranscribeDescriptor {
    public static let descriptor = ModelDescriptor(
        architecture: .nemotronTranscribe, mode: .dictation, preferredSegmentSeconds: 20,
        calibratable: false, catalogFamilies: ["nemotron-3.5-transcribe"],
        switchHelp: "Here Exact decodes one token at a time; Fast drafts and verifies several, about 1.25× faster, differing only on near ties")
}
