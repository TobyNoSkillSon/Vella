import Foundation
import MLX
import VellaWire

/// How a helper sees a model family: its architecture, its gate identity and, for dictation, how to load it on the
/// stock path. Each model's folder (Parakeet/, Qwen3ASR/, Whisper/, NemotronASR/) has one conforming runtime;
/// `ModelRuntimeRegistry` maps an architecture to it. Adding a model: its runtime folder here, one registry line, its
/// descriptor in the app (VellaCore/Models) and its families in Resources/models.json.
public protocol SpeechModelRuntime {
    static var architecture: Architecture { get }
    /// The model's fast-path revision in the gate key (bumped when its kernels, components or self-test change).
    static var gateRevision: String { get }
    /// The Metal family the optimized path needs; nil when it uses stock MLX ops only.
    static var requiredGPUFamily: String? { get }
}

/// A dictation model (a whole segment in, text out).
public protocol DictationModelRuntime: SpeechModelRuntime {
    /// Loads the stock model, no fast path configured. `derived`: a precision made at load from `directory`'s source.
    static func loadStock(_ directory: URL, derived: DerivedPrecision?) async throws -> any STTGenerationModel
    /// The model's input from 16-kHz mono Float32 samples.
    static func input(_ samples: MLXArray) -> MLXArray
}

/// A streaming model (the streaming helper builds its session; see VellaStreamingWorker).
public protocol StreamingModelRuntime: SpeechModelRuntime {}

public enum ModelRuntimeError: Error { case unsupported }

/// Every model runtime, by architecture.
public enum ModelRuntimeRegistry {
    public static let dictation: [any DictationModelRuntime.Type] = [ParakeetRuntime.self, Qwen3ASRRuntime.self, WhisperRuntime.self]
    public static let streaming: [any StreamingModelRuntime.Type] = [NemotronRuntime.self]
    public static func dictation(_ architecture: Architecture) -> (any DictationModelRuntime.Type)? {
        dictation.first { $0.architecture == architecture }
    }
    public static func streaming(_ architecture: Architecture) -> (any StreamingModelRuntime.Type)? {
        streaming.first { $0.architecture == architecture }
    }
}
