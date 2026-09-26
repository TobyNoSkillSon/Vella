import Foundation
import MLX
import MLXAudioSTT

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
    func generateStream(audio: MLXArray, generationParameters: STTGenerateParameters) -> AsyncThrowingStream<STTGeneration, Error> {
        let output = generate(audio: audio, generationParameters: generationParameters)
        return AsyncThrowingStream { continuation in continuation.yield(.result(output)); continuation.finish() }
    }
    func configureFastPath(enabled: Bool, component: String) -> Bool { fast = enabled; return enabled }
    var fastPathFinite: Bool { true }
    func qualificationTokens(audio: MLXArray) -> [Int] { [1, 2, 3] }
    var fastPathComponents: [String: Bool] { ["stub": true] }
    var fastPathSelfTestClips: [String] { ["clip-a"] }
    static var fastPathRevision: String { "stub-1" }
}
