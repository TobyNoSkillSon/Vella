// Python-compatible streaming numerics; dump() is a QA-only entry point.
import Foundation
import MLX
import MLXNN
public enum VellaNemotronNumerics {
    public static func referencePositionTable(dModel: Int, maxLen: Int = 5000) -> MLXArray {
        let positions = MLX.arange(maxLen - 1, -maxLen, step: -1, dtype: .int32).expandedDimensions(axis: 1).asType(.float32)
        let channels = MLX.arange(0, dModel, step: 2, dtype: .float32)
        let divisor = MLX.exp(channels * Float(-(log(10000.0) / Double(dModel))))
        let angles = positions * divisor
        return MLX.stacked([MLX.sin(angles), MLX.cos(angles)], axis: -1).reshaped([1, 2 * maxLen - 1, dModel])
    }
    public static func useReferencePositionTable(_ model: NemotronASRModel) {
        model.encoder.posEnc.pe = referencePositionTable(dModel: model.encoderConfig.dModel, maxLen: model.encoder.posEnc.maxLen)
        eval(model.encoder.posEnc.pe)
    }
    /// The frontend keeps Float32 mel (Python parity), so the encoder, prompt and joint
    /// already run in Float32 and MLX promoted their BF16 weights on every call.
    /// Converting those weights once at load (lossless) gives bit-identical output
    /// without the per-op conversions. The prediction network stays BF16: its
    /// embedding feeds a BF16 x BF16 LSTM matmul, which Float32 weights would change.
    public static func convertFloat32Weights(_ model: NemotronASRModel) {
        let converted = model.parameters().flattened().map { key, value -> (String, MLXArray) in
            (key, !key.hasPrefix("decoder.") && value.dtype == .bfloat16 ? value.asType(.float32) : value)
        }
        model.update(parameters: ModuleParameters.unflattened(Dictionary(uniqueKeysWithValues: converted)))
        eval(model)
    }
    /// Undo `convertFloat32Weights` (Float32 -> BF16 is exact for values that came from BF16):
    /// the stock weights, for the runtime fallback, without reloading.
    public static func restoreBF16Weights(_ model: NemotronASRModel) {
        let restored = model.parameters().flattened().map { key, value -> (String, MLXArray) in
            (key, value.dtype == .float32 ? value.asType(.bfloat16) : value)
        }
        model.update(parameters: ModuleParameters.unflattened(Dictionary(uniqueKeysWithValues: restored)))
        eval(model)
        Memory.clearCache()
    }
    /// Build the fused conformer layer from the loaded (and possibly converted) weights.
    /// Returns false when this checkpoint's shapes are not supported (the unfused path stays).
    @discardableResult
    public static func prepareFusedEncoder(_ model: NemotronASRModel) -> Bool {
        model.fusedEncoder = VellaNemotronFusedEncoder(model.encoder)
        return model.fusedEncoder != nil
    }
    public static func dropFusedEncoder(_ model: NemotronASRModel) {
        model.fusedEncoder = nil
    }
    /// Self-test tolerance check for the fused layer: streams `audio` through the chunk encoder twice
    /// (unfused K/V-cache path, then fused), both in 4-frame chunks from a fresh state, and returns the
    /// relative RMS deviation ||fused - unfused|| / ||unfused|| and the max deviation max |Δ| / max |unfused|
    /// over every encoder output frame (non-finite → .infinity), or nil when the fused layer is not prepared.
    public static func fusedEncoderDeviation(_ model: NemotronASRModel, audio: [Float]) -> (rms: Float, max: Float)? {
        guard model.fusedEncoder != nil else { return nil }
        let c = model.preprocessConfig
        let mel = VellaNemotronFrontend.frames(MLXArray(audio), config: c, start: 0, end: audio.count / c.hopLength + 1)
        func run(fused: Bool) -> MLXArray {
            let state = NemotronASRStreamEncoderState(layers: model.encoder.layers.count)
            state.usePositionCache = true; state.useKeyValueCache = true; state.useFusedLayer = fused
            var out: [MLXArray] = []
            model.streamEncodeChunks(mel, language: model.defaultLanguage, limit: mel.shape[1], preserveInputDType: true,
                                     chunkFrames: 4, flushTail: true, state: state) { out.append($0); eval($0) }
            return concatenated(out, axis: 1).asType(.float32)
        }
        let reference = run(fused: false), fused = run(fused: true)
        guard reference.shape == fused.shape else { return (.infinity, .infinity) }
        let delta = fused - reference
        let values = MLX.stacked([MLX.sqrt((delta * delta).sum() / (reference * reference).sum()),
                                  abs(delta).max() / abs(reference).max()]).asArray(Float.self)
        return (values[0].isFinite ? values[0] : .infinity, values[1].isFinite ? values[1] : .infinity)
    }
    public static func dump(configURL: URL, pcmURL: URL, lengthsURL: URL, output: URL) throws {
        let config = try JSONDecoder().decode(NemotronASRConfig.self, from: Data(contentsOf: configURL))
        let bytes = try Data(contentsOf: pcmURL)
        let audio: [Float] = bytes.withUnsafeBytes { p in stride(from: 0, to: p.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) } }
        let lengths = try JSONDecoder().decode([Int].self, from: Data(contentsOf: lengthsURL))
        let c = config.preprocessor
        var buffer: [Float] = [], total = 0, base = 0, next = 0, offset = 0
        var mels: [MLXArray] = []
        for size in lengths + [0] {
            let final = size == 0
            buffer += audio[offset..<(offset + size)]; offset += size; total += size
            let edge = total - c.nFft / 2
            let end = final ? total / c.hopLength + 1 : edge >= 0 ? edge / c.hopLength + 1 : 0
            if end > next {
                let mel = VellaNemotronFrontend.frames(MLXArray(buffer), config: c, start: next - base / c.hopLength, end: end - base / c.hopLength)
                eval(mel); mels.append(mel); next = end
                let keep = max(0, next - (c.nFft / 2 + c.hopLength) / c.hopLength) * c.hopLength
                if keep > base { buffer.removeFirst(keep - base); base = keep }
            }
        }
        try MLX.save(array: concatenated(mels, axis: 1), url: output.appendingPathComponent("swift-mel.npy"))
        let old = NemoRelPositionalEncoding(dModel: config.encoder.dModel)
        try MLX.save(array: old.pe, url: output.appendingPathComponent("swift-position-cpu.npy"))
        try MLX.save(array: referencePositionTable(dModel: config.encoder.dModel), url: output.appendingPathComponent("swift-position-mlx.npy"))
    }
}
