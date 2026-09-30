import Foundation

/// Every model family Vella runs, by checkpoint architecture.
public enum ModelRegistry {
    public static let all: [ModelDescriptor] = [ParakeetDescriptor.descriptor, Qwen3ASRDescriptor.descriptor,
                                                WhisperDescriptor.descriptor, NemotronDescriptor.descriptor]
    public static func descriptor(architecture: String?) -> ModelDescriptor? {
        all.first { $0.architecture == architecture }
    }
    /// The architectures a mode's worker runs.
    public static func architectures(_ mode: RecognitionMode) -> [String] { all.filter { $0.mode == mode }.map(\.architecture) }
}
