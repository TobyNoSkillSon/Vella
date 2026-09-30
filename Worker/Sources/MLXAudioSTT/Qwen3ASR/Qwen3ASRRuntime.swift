import Foundation
import MLX
import VellaWire

/// Qwen3 ASR (1.7B, 0.6B).
public enum Qwen3ASRRuntime: DictationModelRuntime {
    public static let architecture = Architecture.qwen3ASR
    public static var gateRevision: String { Qwen3ASRModel.fastPathRevision }
    public static let requiredGPUFamily: String? = "apple9"
    public static func loadStock(_ directory: URL, derived: DerivedPrecision?) async throws -> any STTGenerationModel {
        if let derived { return try await Qwen3ASRModel.fromModelDirectory(derived.source, derived: derived) }
        return try await Qwen3ASRModel.fromModelDirectory(directory)
    }
    public static func input(_ samples: MLXArray) -> MLXArray { samples }
}
