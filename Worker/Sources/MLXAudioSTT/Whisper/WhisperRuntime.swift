import Foundation
import MLX
import VellaWire

/// Whisper (large-v3, large-v3 turbo).
public enum WhisperRuntime: DictationModelRuntime {
    public static let architecture = Architecture.whisper
    /// Two revisions: the checkpoint-dtype model (Fast) or not (Optimized · Exact).
    public static var gateRevision: String { WhisperModel.fastPathRevision }
    public static let requiredGPUFamily: String? = "apple9"
    public static func loadStock(_ directory: URL, derived: DerivedPrecision?) async throws -> any STTGenerationModel {
        if let derived { return try await WhisperModel.fromDirectory(derived.source, derived: derived) }
        return try await WhisperModel.fromDirectory(directory)
    }
    public static func input(_ samples: MLXArray) -> MLXArray { samples }
}
