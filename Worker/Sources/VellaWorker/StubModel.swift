import Foundation
import MLX
import MLXAudioSTT
import VellaWire

/// Test-only model (`VELLA_STUB_MODELS=1`, reported in status): a folder with config.json `{"model_type": "stub"}`
/// and any `.safetensors` file loads without weights. Text is `stub:<folder name> <seconds>s`. It has an "optimized"
/// path that is identical to stock, so the gate, the runtime fallback and the fault hooks run through the same worker
/// code as real models without the GPU.
final class StubModel: STTGenerationModel, FastPathCapable {
    static var enabled: Bool { ProcessInfo.processInfo.environment["VELLA_STUB_MODELS"] == "1" }
    let name: String
    private(set) var fast = false
    init(_ path: URL) { name = path.lastPathComponent }
    var defaultGenerationParameters: STTGenerateParameters { STTGenerateParameters(maxTokens: 1, verbose: false) }
    func generate(audio: MLXArray, generationParameters: STTGenerateParameters) -> STTOutput {
        STTOutput(text: "stub:\(name) \(String(format: "%.1f", Double(audio.size) / 16000))s")
    }
    func configureFastPath(enabled: Bool, component: String) -> Bool { fast = enabled; return enabled }
    /// Two-stage gate test hook (`VELLA_TEST_TOLERANT_FAULT`, part of the gate key): the stub gains a tolerant
    /// component `stub_tolerant` whose output differs from stock by one word per clip (`edit`, within tolerance),
    /// by two (`edits`, over it) or is non-finite (`nonfinite`).
    static var tolerantFault: String? { ProcessInfo.processInfo.environment["VELLA_TEST_TOLERANT_FAULT"].flatMap { $0.isEmpty ? nil : $0 } }
    var disabled: Set<String> = []
    var fastPathDisabledComponents: Set<String> {
        get { disabled }
        set { disabled = newValue }
    }
    var fastPathTolerantComponents: [String] { Self.tolerantFault == nil ? [] : ["stub_tolerant"] }
    private var tolerantActive: Bool { fast && Self.tolerantFault != nil && !disabled.contains("stub_tolerant") }
    var fastPathFinite: Bool { !(tolerantActive && Self.tolerantFault == "nonfinite") }
    func qualificationTokens(audio: MLXArray) -> [Int] {
        guard tolerantActive else { return [1, 2, 3] }
        return Self.tolerantFault == "edits" ? [1, 7, 8] : [1, 2, 7]
    }
    var fastPathComponents: [String: Bool] {
        Self.tolerantFault == nil ? ["stub": true] : ["stub": true, "stub_tolerant": tolerantActive]
    }
    var fastPathSelfTestClips: [String] { ["clip-a"] }
    static var fastPathRevision: String { "stub-1" }
}

/// The stub's runtime (test hook; only while `VELLA_STUB_MODELS=1`).
enum StubRuntime: DictationModelRuntime {
    static let architecture = Architecture.stub
    static var gateRevision: String { StubModel.fastPathRevision }
    static let requiredGPUFamily: String? = "apple9"
    static func loadStock(_ directory: URL, derived: DerivedPrecision?) async throws -> any STTGenerationModel {
        guard derived == nil, StubModel.enabled else { throw ModelRuntimeError.unsupported }
        return StubModel(directory)
    }
    static func input(_ samples: MLXArray) -> MLXArray { samples }
}
