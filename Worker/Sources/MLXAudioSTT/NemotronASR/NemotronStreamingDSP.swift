import Foundation
import MLX

// mlx-audio 0.5.1 dsp (MIT); see LICENSE-mlx-audio-python.
// Mirrors the production filter operation order, not CPU Float approximations.
enum VellaStreamingDSP {
    static func melFilters(sampleRate: Int, nFft: Int, nMels: Int) -> MLXArray {
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

}
