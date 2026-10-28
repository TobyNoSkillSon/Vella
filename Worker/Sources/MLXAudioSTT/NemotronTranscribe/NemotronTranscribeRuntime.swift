import Foundation
import MLX
import VellaWire

/// Nemotron 3.5 Transcribe 30B-A4B (BF16, int8 and int4 mixes): offline dictation, a whole recording at a time.
public enum NemotronTranscribeRuntime: DictationModelRuntime {
    public static let architecture = Architecture.nemotronTranscribe
    public static let gateRevision = "nemotron-transcribe-1"
    public static let requiredGPUFamily: String? = nil
    /// No self-test child: qualifying would load a second 21–68 GB copy. Its MTP decoder is part of the model's
    /// decoding (drafts are verified by the main model), not a separately qualified kernel path.
    public static let hasFastPath = false
    public static func loadStock(_ directory: URL, derived: DerivedPrecision?) async throws -> any STTGenerationModel {
        // Every tier is its own checkpoint; nothing is derived on the Mac.
        guard derived == nil else { throw ModelRuntimeError.unsupported }
        return try await NemotronTranscribeModel.fromModelDirectory(directory)
    }
    public static func input(_ samples: MLXArray) -> MLXArray { samples }
}
