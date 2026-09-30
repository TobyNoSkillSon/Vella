import Foundation
import MLX
import VellaWire

/// Parakeet TDT (Parakeet v3, v3 Ultra).
public enum ParakeetRuntime: DictationModelRuntime {
    public static let architecture = Architecture.parakeet
    public static var gateRevision: String { ParakeetModel.fastPathRevision }
    public static let requiredGPUFamily: String? = "apple9"
    public static func loadStock(_ directory: URL, derived: DerivedPrecision?) async throws -> any STTGenerationModel {
        if let derived { return try autoreleasepool { try ParakeetModel.fromDirectory(derived.source, preserveCheckpointDTypes: true, derived: derived) } }
        return try autoreleasepool { try ParakeetModel.fromDirectory(directory, preserveCheckpointDTypes: true) }
    }
    /// The log-mel is computed in the input's dtype (BF16).
    public static func input(_ samples: MLXArray) -> MLXArray { samples.asType(ParakeetModel.inputDType) }
}
