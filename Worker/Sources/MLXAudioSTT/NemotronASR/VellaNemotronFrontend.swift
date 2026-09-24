import Foundation
import MLX
import MLXFFT

// Direct Swift port of mlx-audio 0.5.1 log_mel_spectrogram_frames (MIT).
// Frame extraction applies preemphasis before reflect-padding and computes only
// the requested bounded range; centered constant padding is NOT equivalent.
enum VellaNemotronFrontend {
    static func frames(_ x: MLXArray, config c: NemotronASRPreprocessConfig, start: Int, end: Int) -> MLXArray {
        let count = end - start
        guard count > 0 else { return MLXArray.zeros([1, 0, c.features]) }
        let sampleStart = start * c.hopLength - c.nFft / 2
        let sampleEnd = (end - 1) * c.hopLength - c.nFft / 2 + c.nFft
        let rawStart = max(sampleStart, 0), rawEnd = min(sampleEnd, x.shape[0])
        var raw = x[rawStart..<rawEnd]
        if c.preemph > 0 && raw.shape[0] > 0 {
            let first = rawStart > 0 ? raw[..<1] - Float(c.preemph) * x[(rawStart - 1)..<rawStart] : raw[..<1]
            raw = concatenated([first, raw[1...] - Float(c.preemph) * raw[..<(raw.shape[0] - 1)]])
        }
        let left = max(-sampleStart, 0), right = max(sampleEnd - x.shape[0], 0)
        var pieces: [MLXArray] = []
        if left > 0 {
            let n = min(left, max(0, raw.shape[0] - 1))
            pieces.append(raw[MLXArray(Array((1..<(n + 1)).reversed()).map(Int32.init))])
        }
        pieces.append(raw)
        if right > 0 {
            let start = max(0, raw.shape[0] - right - 1), end = max(0, raw.shape[0] - 1)
            pieces.append(raw[MLXArray(Array((start..<end).reversed()).map(Int32.init))])
        }
        var segment = pieces.count == 1 ? pieces[0] : concatenated(pieces)
        let expected = (count - 1) * c.hopLength + c.nFft
        if segment.shape[0] < expected { segment = concatenated([segment, MLXArray.zeros([expected - segment.shape[0]])]) }
        // Installed streaming checkpoints use symmetric Hann. Admission rejects
        // unsupported frontend variants rather than silently changing windows.
        let values = (0..<c.winLength).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(c.winLength - 1)))) }
        let pad = (c.nFft - c.winLength) / 2
        let window = concatenated([MLXArray.zeros([pad]), MLXArray(values), MLXArray.zeros([c.nFft - c.winLength - pad])])
        let frames = asStrided(segment, [count, c.nFft], strides: [c.hopLength, 1])
        let power = abs(MLXFFT.rfft(frames * window)).square()
        let filters = VellaStreamingDSP.melFilters(sampleRate: c.sampleRate, nFft: c.nFft, nMels: c.features)
        let mel = log(matmul(filters.asType(power.dtype), power.transposed()) + MLXArray(c.logZeroGuardValue, dtype: power.dtype))
        return mel.transposed().expandedDimensions(axis: 0)
    }
}
