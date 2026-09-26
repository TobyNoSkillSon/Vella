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
