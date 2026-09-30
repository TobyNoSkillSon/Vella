import Foundation
import VellaWire

/// Every model family Vella runs, by checkpoint architecture.
public enum ModelRegistry {
    public static let all: [ModelDescriptor] = [ParakeetDescriptor.descriptor, Qwen3ASRDescriptor.descriptor,
                                                WhisperDescriptor.descriptor, NemotronDescriptor.descriptor]
    public static func descriptor(_ architecture: Architecture) -> ModelDescriptor? { all.first { $0.architecture == architecture } }
    /// The descriptor for an architecture name as config.json spells it (nil for anything Vella does not run).
    public static func descriptor(architecture: String?) -> ModelDescriptor? { architecture.flatMap(Architecture.init(rawValue:)).flatMap(descriptor) }
    /// The architectures a mode's worker runs.
    public static func architectures(_ mode: RecognitionMode) -> [Architecture] { all.filter { $0.mode == mode }.map(\.architecture) }
}
