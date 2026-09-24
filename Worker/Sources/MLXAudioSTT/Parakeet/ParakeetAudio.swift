import Foundation
import MLX
import MLXAudioCore

enum ParakeetAudio {
    static func logMelSpectrogram(
        _ audio: MLXArray,
        config: ParakeetPreprocessConfig,
        capture: ((String, MLXArray) -> Void)? = nil
    ) -> MLXArray {
        let originalDType = audio.dtype
        var x = audio
        capture?("waveform", audio)

        if config.padTo > 0 && x.shape[0] < config.padTo {
            let padLength = config.padTo - x.shape[0]
            let paddedTail = MLXArray(Array(repeating: config.padValue, count: padLength))
            x = MLX.concatenated([x, paddedTail], axis: 0)
        }

        if config.preemph > 0 && x.shape[0] > 1 {
            let first = x[0..<1]
            let rest = x[1...] - Float(config.preemph) * x[..<(x.shape[0] - 1)]
            x = MLX.concatenated([first, rest], axis: 0)
        }

        capture?("preemphasis", x)
        let window = makeWindow(name: config.window, winLength: config.winLength, fftLength: config.nFft)
        capture?("window", window)
        let stftOutput = stft(
            audio: x,
            window: window,
            nFft: config.nFft,
            hopLength: config.hopLength,
            padMode: .constant
        )

        capture?("stft_abs", MLX.abs(stftOutput))
        let power = MLX.abs(stftOutput).square().asType(originalDType)
        capture?("power", power)
        // Match mlx-audio 0.5.1's MLX filter construction and matrix orientation.
        // CPU Float loops and transposing this GEMM change BF16 rounding near token ties.
        let filters = referenceMelFilters(sampleRate: config.sampleRate, nFft: config.nFft, nMels: config.features)
        capture?("filters", filters)
        var mel = MLX.matmul(filters.asType(power.dtype), power.transposed())
        capture?("mel_linear", mel)
        mel = MLX.log(mel + MLXArray(config.logZeroGuardValue, dtype: mel.dtype))

        capture?("mel_log", mel)
        let normalized: MLXArray
        if config.normalize == "per_feature" {
            let mean = MLX.mean(mel, axis: 1, keepDims: true)
            let denominator = max(mel.dim(1) - 1, 1)
            capture?("difference", mel - mean)
            let deviations = MLX.pow(mel - mean, 2)
            let varianceSum = MLX.sum(deviations, axis: 1, keepDims: true)
            let variance = varianceSum / Float(denominator)
            capture?("deviations", deviations); capture?("variance_sum", varianceSum)
            capture?("denominator", MLXArray(Float(denominator), dtype: mel.dtype))
            let std = MLX.sqrt(variance)
            capture?("mel_mean", mean); capture?("mel_variance", variance); capture?("mel_std", std)
            normalized = (mel - mean) / (std + MLXArray(1e-5, dtype: mel.dtype))
        } else {
            let mean = MLX.mean(mel)
            let std = MLX.std(mel)
            normalized = (mel - mean) / (std + MLXArray(1e-5, dtype: mel.dtype))
        }

        return normalized.transposed().expandedDimensions(axis: 0).asType(originalDType)
    }

    // Adapted from mlx-audio 0.5.1 dsp.mel_filters (MIT, Prince Canuma).
    // Standard MLX operations only: no custom kernels or optimization.
    private static func referenceMelFilters(sampleRate: Int, nFft: Int, nMels: Int) -> MLXArray {
        let fSp = 200.0 / 3.0
        let minLogMel = 1000.0 / fSp
        let logStep = log(6.4) / 27.0
        let maxMel = minLogMel + log(Double(sampleRate) / 2000.0) / logStep
        let frequencies = MLX.linspace(Float(0), Float(sampleRate / 2), count: nFft / 2 + 1)
        let mels = MLX.linspace(Double(0), maxMel, count: nMels + 2, dtype: .float32)
        let points = MLX.where(mels .>= Float(minLogMel),
                               Float(1000) * MLX.exp(Float(logStep) * (mels - Float(minLogMel))),
                               Float(fSp) * mels)
        let differences = points[1...] - points[..<(nMels + 1)]
        let slopes = points.expandedDimensions(axis: 0) - frequencies.expandedDimensions(axis: 1)
        let down = -slopes[0..., ..<nMels] / differences[..<nMels]
        let up = slopes[0..., 2...] / differences[1...]
        var filters = MLX.maximum(MLXArray.zeros(like: down), MLX.minimum(down, up))
        let normalization = Float(2) / (points[2...] - points[..<nMels])
        filters = filters * normalization.expandedDimensions(axis: 0)
        return filters.transposed()
    }

    private static func makeWindow(name: String, winLength: Int, fftLength: Int) -> MLXArray {
        let base: MLXArray
        switch name.lowercased() {
        case "hann", "hanning":
            base = MLXArray((0..<winLength).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(winLength - 1)))) })
        case "hamming":
            base = hammingWindow(size: winLength)
        case "blackman":
            base = blackmanWindow(size: winLength)
        case "bartlett":
            base = bartlettWindow(size: winLength)
        default:
            base = MLXArray((0..<winLength).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(winLength - 1)))) })
        }

        if winLength >= fftLength {
            return base[0..<fftLength]
        }

        let left = (fftLength - winLength) / 2
        let right = fftLength - winLength - left
        return MLX.concatenated([
            MLXArray.zeros([left]),
            base,
            MLXArray.zeros([right])
        ], axis: 0)
    }

    private static func hammingWindow(size: Int) -> MLXArray {
        if size <= 1 {
            return MLXArray(Array(repeating: Float(1), count: max(size, 1)))
        }
        let denom = Float(size - 1)
        let values = (0..<size).map { n in
            Float(0.54) - Float(0.46) * cos(2 * Float.pi * Float(n) / denom)
        }
        return MLXArray(values)
    }

    private static func blackmanWindow(size: Int) -> MLXArray {
        if size <= 1 {
            return MLXArray(Array(repeating: Float(1), count: max(size, 1)))
        }
        let denom = Float(size - 1)
        let values = (0..<size).map { n in
            let k = 2 * Float.pi * Float(n) / denom
            return Float(0.42) - Float(0.5) * cos(k) + Float(0.08) * cos(2 * k)
        }
        return MLXArray(values)
    }

    private static func bartlettWindow(size: Int) -> MLXArray {
        if size <= 1 {
            return MLXArray(Array(repeating: Float(1), count: max(size, 1)))
        }
        let mid = Float(size - 1) / 2
        let values = (0..<size).map { n in
            Float(1) - abs((Float(n) - mid) / mid)
        }
        return MLXArray(values)
    }
}
