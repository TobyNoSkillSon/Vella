import Foundation
import MLX

/// Bounded PCM + mel state; unlike upstream's convenience stream session this
/// never recomputes the utterance or reconstructs text from token history.
public final class VellaNemotronSession {
    private let model: NemotronASRModel
    private var samples: [Float] = []
    private var bufferStart = 0
    private var totalSamples = 0
    private var nextFrame = 0
    private var melBase = 0
    private var pending: MLXArray?
    private let encoder: NemotronASRStreamEncoderState
    private var last: Int
    private var hidden: NemoLSTMState?
    private var closed = false

    public init(model: NemotronASRModel) throws {
        let c = model.preprocessConfig
        guard c.padTo == 0, ["hann", "hanning"].contains(c.window.lowercased()), c.winLength > 1, c.winLength <= c.nFft, ["na", "none"].contains(c.normalize.lowercased()),
              model.defaultAttContextSize.first == 56 else {
            throw NSError(domain: "VellaStreaming", code: 1)
        }
        self.model = model
        encoder = NemotronASRStreamEncoderState(layers: model.encoder.layers.count)
        last = model.blankTokenID
    }
    public func push(_ chunk: [Float], final: Bool) throws -> String {
        guard !closed else { throw NSError(domain: "VellaStreaming", code: 2) }
        let c = model.preprocessConfig
        samples += chunk; totalSamples += chunk.count
        let edge = totalSamples - c.nFft / 2
        let end = final ? totalSamples / c.hopLength + 1 : edge >= 0 ? edge / c.hopLength + 1 : 0
        if end > nextFrame {
            let localStart = nextFrame - bufferStart / c.hopLength
            let localEnd = end - bufferStart / c.hopLength
            let mel = VellaNemotronFrontend.frames(MLXArray(samples), config: c, start: localStart, end: localEnd)
            pending = pending == nil ? mel : concatenated([pending!, mel], axis: 1)
            nextFrame = end
            let lookbehind = (c.nFft / 2 + c.hopLength) / c.hopLength
            let keep = max(0, nextFrame - lookbehind) * c.hopLength
            if keep > bufferStart { samples.removeFirst(keep - bufferStart); bufferStart = keep }
        }
        var text = ""
        if let mel = pending {
            model.streamEncodeChunks(mel, language: model.defaultLanguage,
                limit: melBase + mel.shape[1], melBase: melBase, preserveInputDType: true, chunkFrames: 4,
                flushTail: final, state: encoder) { features in
                // Greedy RNNT commits predictor state only on nonblank symbols.
                for time in 0..<features.shape[1] {
                    let frame = features[0..., time..<(time + 1), 0...]
                    let cap = self.model.maxSymbols.flatMap { $0 == 0 ? nil : $0 } ?? 10
                    for _ in 0..<max(0, cap) {
                        let token = self.last == self.model.blankTokenID ? nil : MLXArray([Int32(self.last)]).reshaped([1, 1])
                        let result = self.model.decoder(token, state: self.hidden)
                        let prediction = self.model.joint(frame, result.0.asType(frame.dtype)).argMax().item(Int.self)
                        if prediction == self.model.blankTokenID { break }
                        self.last = prediction
                        self.hidden = (result.1.hidden?.asType(frame.dtype), result.1.cell?.asType(frame.dtype))
                        let state = [self.hidden?.hidden, self.hidden?.cell].compactMap { $0 }
                        if !state.isEmpty { eval(state) }
                        text += NemotronASRTokenizer.decode(tokens: [prediction], vocabulary: self.model.vocabulary)
                    }
                }
            }
            let drop = encoder.consumed - melBase
            pending = drop < mel.shape[1] ? mel[0..., drop..., 0...].contiguous() : nil
            melBase = encoder.consumed
        }
        var live = encoder.attnCache.compactMap { $0 } + encoder.convCache.compactMap { $0 }
        if let mel = encoder.melCache { live.append(mel) }
        if let pending { live.append(pending) }
        if !live.isEmpty { eval(live) }
        closed = final
        Memory.clearCache()
        return text
    }
}
