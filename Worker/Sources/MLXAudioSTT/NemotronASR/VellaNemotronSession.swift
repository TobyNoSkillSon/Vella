import Foundation
import MLX
import MLXNN

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
    /// Predictor output for the current (last, hidden): the LSTM step and the joint's
    /// pred projection only change when a nonblank symbol is emitted.
    private var predictor: (state: NemoLSTMState, projection: MLXArray)?
    static let batchedDecode = ProcessInfo.processInfo.environment["VELLA_NEMO_BATCHED_DECODE"] != "0"

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
        let pushStart = VellaStreamProfile.enabled ? CFAbsoluteTimeGetCurrent() : 0
        defer { if VellaStreamProfile.enabled { VellaStreamProfile.add("push"); VellaStreamProfile.add("push_ms", (CFAbsoluteTimeGetCurrent() - pushStart) * 1000) } }
        let c = model.preprocessConfig
        samples += chunk; totalSamples += chunk.count
        let edge = totalSamples - c.nFft / 2
        let end = final ? totalSamples / c.hopLength + 1 : edge >= 0 ? edge / c.hopLength + 1 : 0
        if end > nextFrame {
            let localStart = nextFrame - bufferStart / c.hopLength
            let localEnd = end - bufferStart / c.hopLength
            let mel = VellaNemotronFrontend.frames(MLXArray(samples), config: c, start: localStart, end: localEnd)
            VellaStreamProfile.add("mel_calls")
            if VellaStreamProfile.enabled { VellaStreamProfile.time("mel_eval") { eval(mel) } }
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
                VellaStreamProfile.add("enc_chunks"); VellaStreamProfile.add("enc_frames", Double(features.shape[1]))
                if VellaStreamProfile.enabled { VellaStreamProfile.time("enc_eval") { eval(features) } }
                let decodeStart = VellaStreamProfile.enabled ? CFAbsoluteTimeGetCurrent() : 0
                defer { VellaStreamProfile.add("decode_ms", (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000) }
                if Self.batchedDecode { text += self.decodeChunk(features); return }
                for time in 0..<features.shape[1] {
                    let frame = features[0..., time..<(time + 1), 0...]
                    let cap = self.model.maxSymbols.flatMap { $0 == 0 ? nil : $0 } ?? 10
                    for _ in 0..<max(0, cap) {
                        let token = self.last == self.model.blankTokenID ? nil : MLXArray([Int32(self.last)]).reshaped([1, 1])
                        let result = self.model.decoder(token, state: self.hidden)
                        let prediction = self.model.joint(frame, result.0.asType(frame.dtype)).argMax().item(Int.self)
                        VellaStreamProfile.add("sync_item")
                        if prediction == self.model.blankTokenID { break }
                        self.last = prediction
                        self.hidden = (result.1.hidden?.asType(frame.dtype), result.1.cell?.asType(frame.dtype))
                        let state = [self.hidden?.hidden, self.hidden?.cell].compactMap { $0 }
                        if !state.isEmpty { eval(state); VellaStreamProfile.add("sync_state") }
                        VellaStreamProfile.add("tokens")
                        text += NemotronASRTokenizer.decode(tokens: [prediction], vocabulary: self.model.vocabulary)
                    }
                }
            }
            let drop = encoder.consumed - melBase
            pending = drop < mel.shape[1] ? mel[0..., drop..., 0...].contiguous() : nil
            melBase = encoder.consumed
        }
        var live = encoder.live
        if let pending { live.append(pending) }
        if let h = hidden?.hidden { live.append(h) }
        if let c = hidden?.cell { live.append(c) }
        if !live.isEmpty { VellaStreamProfile.time("live_eval") { eval(live) }; VellaStreamProfile.add("sync_live") }
        closed = final
        Memory.clearCache()
        return text
    }

    /// Greedy RNNT over one encoder chunk with one host sync per predictor state
    /// instead of one per frame and symbol. Every tensor op keeps the per-frame
    /// shapes of `NemoJointNetwork.callAsFunction`, so each logit is bit-identical;
    /// only the argmax reads are batched: the joint of every remaining frame is
    /// evaluated against the current predictor, the walk stops at the first
    /// nonblank symbol, and after an emission the rest is re-evaluated.
    private func decodeChunk(_ features: MLXArray) -> String {
        let joint = model.joint
        let blank = model.blankTokenID
        let cap = model.maxSymbols.flatMap { $0 == 0 ? nil : $0 } ?? 10
        let count = features.shape[1]
        let dtype = features.dtype
        let encoded = (0..<count).map { joint.enc(features[0..., $0..<($0 + 1), 0...]).expandedDimensions(axis: 2) }
        var text = ""
        var time = 0, symbols = 0
        while time < count {
            if predictor == nil {
                let token = last == blank ? nil : MLXArray([Int32(last)]).reshaped([1, 1])
                let result = model.decoder(token, state: hidden)
                let state: NemoLSTMState = (result.1.hidden?.asType(dtype), result.1.cell?.asType(dtype))
                predictor = (state, joint.pred(result.0.asType(dtype)).expandedDimensions(axis: 1))
            }
            let projection = predictor!.projection
            let logits = encoded[time...].map { encP -> MLXArray in
                var x = encP + projection
                switch joint.activationName {
                case "relu": x = relu(x)
                case "sigmoid": x = sigmoid(x)
                default: x = tanh(x)
                }
                return joint.outputProj(x).argMax()
            }
            let predictions = MLX.stacked(logits).asArray(Int32.self)
            VellaStreamProfile.add("sync_item")
            var index = 0
            while time < count, Int(predictions[index]) == blank { time += 1; index += 1; symbols = 0 }
            guard time < count else { break }
            let token = Int(predictions[index])
            last = token
            hidden = predictor!.state
            predictor = nil
            VellaStreamProfile.add("tokens")
            text += NemotronASRTokenizer.decode(tokens: [token], vocabulary: model.vocabulary)
            symbols += 1
            if symbols >= cap { time += 1; symbols = 0 }
        }
        return text
    }
}
