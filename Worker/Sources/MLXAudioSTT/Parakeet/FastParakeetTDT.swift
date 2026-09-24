import MLX
import MLXNN

/// Single-row TDT greedy decode. One compiled graph contains 32 steps × five kernels.
/// All checkpoint-derived arrays (including duration choices) are explicit compile arguments.
final class FastParakeetTDT {
    private weak var model: ParakeetModel?
    private let hidden, dimension, outputs, projection, blank: Int
    private let weights: [MLXArray]
    private(set) var lastFinite = true
    private(set) var lastError: String?
    private let joint = MLXFast.metalKernel(name: "vella_tdt_joint", inputNames: ["enc_p", "t", "pred_p", "W", "b"], outputNames: ["logits"], source: FastParakeetMetal.joint, header: FastParakeetMetal.header)
    private let argmax = MLXFast.metalKernel(name: "vella_tdt_argmax", inputNames: ["logits", "t", "n_frames", "new_syms", "last", "durations", "max_symbols"], outputNames: ["tok_o", "dur_o", "emit_o", "t_o", "syms_o", "last_o"], source: FastParakeetMetal.argmax, header: FastParakeetMetal.header)
    private let lstm1 = MLXFast.metalKernel(name: "vella_tdt_lstm1", inputNames: ["emit", "tok", "h", "c", "ch", "cc", "table", "Wh"], outputNames: ["h_o", "c_o", "ch_o", "cc_o"], source: FastParakeetMetal.lstm1, header: FastParakeetMetal.header)
    private let lstm2 = MLXFast.metalKernel(name: "vella_tdt_lstm2", inputNames: ["emit", "x", "h", "c", "ch", "cc", "Wx", "Wh", "bias"], outputNames: ["h_o", "c_o", "ch_o", "cc_o"], source: FastParakeetMetal.lstm2, header: FastParakeetMetal.header)
    private let predict = MLXFast.metalKernel(name: "vella_tdt_pred", inputNames: ["emit", "x", "W", "b", "old"], outputNames: ["out"], source: FastParakeetMetal.pred, header: FastParakeetMetal.header)
    private lazy var run: @Sendable ([MLXArray]) -> [MLXArray] = makeRun()

    init?(_ model: ParakeetModel) {
        guard (model.variant == .tdt || model.variant == .tdtCtc), let decoder = model.decoder, let head = model.joint,
              head.activationName == "relu", decoder.prediction.decRnn.layers.count == 2,
              let wb = head.outputProj.bias, let pb = head.pred.bias,
              let b1 = decoder.prediction.decRnn.layers[1].bias,
              let b0 = decoder.prediction.decRnn.layers[0].bias else { return nil }
        self.model = model
        let layers = decoder.prediction.decRnn.layers
        // A Q4 checkpoint keeps FP32 recurrent matrices, while dequantized
        // embedding/joint matrices retain their F16 scale dtype. No BF16 cast.
        func dense(_ layer: Linear) -> MLXArray {
            guard let q = layer as? QuantizedLinear else { return layer.weight }
            return MLX.dequantized(q.weight, scales: q.scales, biases: q.biases,
                                   groupSize: q.groupSize, bits: q.bits, mode: q.mode,
                                   globalScale: q.globalScale, dtype: q.scales.dtype)
        }
        let embedding: MLXArray
        if let q = decoder.prediction.embed as? QuantizedEmbedding {
            embedding = MLX.dequantized(q.weight, scales: q.scales, biases: q.biases,
                                        groupSize: q.groupSize, bits: q.bits, mode: q.mode,
                                        globalScale: q.globalScale, dtype: q.scales.dtype)
        } else { embedding = decoder.prediction.embed.weight }
        let headWeight = dense(head.outputProj), predWeight = dense(head.pred)
        hidden = layers[0].hiddenSize
        dimension = headWeight.shape[1]
        outputs = headWeight.shape[0]
        projection = predWeight.shape[0]
        blank = model.vocabulary.count
        guard dimension % 8 == 0, hidden % 8 == 0, hidden > 0,
              outputs == blank + 1 + model.durations.count, blank < embedding.shape[0] else { return nil }
        let table = MLX.addMM(b0, embedding, layers[0].wx.transposed())
        let noBlank = MLX.concatenated([table[0..<blank], b0.reshaped([1, -1]), table[(blank + 1)...]], axis: 0)
        weights = [noBlank, layers[0].wh, layers[1].wx, layers[1].wh, b1,
                   headWeight, wb, predWeight, pb,
                   MLXArray(model.durations.map(Int32.init)), MLXArray([Int32(model.maxSymbols ?? Int(Int32.max))])]
        guard (try? MLX.withError { MLX.eval(weights); return true }) == true else { return nil }
    }

    // State layout: h0,c0,ch0,cc0,h1,c1,ch1,cc1,pred. Weights start at offset 14.
    private func makeRun() -> @Sendable ([MLXArray]) -> [MLXArray] {
        // Capture only kernel objects and integer dimensions: never this decoder,
        // the model, or checkpoint arrays in a TLS compilation cache.
        let joint = joint, argmax = argmax, lstm1 = lstm1, lstm2 = lstm2, predict = predict
        let hidden = hidden, dimension = dimension, outputs = outputs, projection = projection, blank = blank
        return MLX.compile { a in
        let feature = a[0], n = a[1]
        var time = a[2], last = a[3], syms = a[4]
        var state = Array(a[5..<14]); let w = Array(a[14...]); let dtype = feature.dtype
        var records: [[MLXArray]] = []
        var finite: [MLXArray] = []
        for _ in 0..<32 {
            let logits = joint([feature, time, state[8], w[5], w[6]],
                               template: [("D", dimension), ("NOUT", outputs), ("NSG", 8), ("RT", state[8].dtype)],
                               grid: (32, ((outputs + 7) / 8) * 8, 1), threadGroup: (32, 8, 1),
                               outputShapes: [[outputs]], outputDTypes: [.float32])[0]
            finite.append(MLX.all(MLX.isFinite(logits)))
            let step = argmax([logits, time, n, syms, last, w[9], w[10]],
                              template: [("V", blank + 1), ("NDUR", w[9].size), ("BLANK", blank), ("RT", state[8].dtype)],
                              grid: (1024, 1, 1), threadGroup: (1024, 1, 1),
                              outputShapes: Array(repeating: [1], count: 6), outputDTypes: Array(repeating: .int32, count: 6))
            let shapes = Array(repeating: [hidden], count: 4), dtypes = Array(repeating: dtype, count: 4)
            let first = lstm1([step[2], step[0], state[0], state[1], state[2], state[3], w[0], w[1]],
                              template: [("H", hidden), ("OT", dtype), ("RT", dtype)], grid: (32, hidden, 1), threadGroup: (32, 8, 1),
                              outputShapes: shapes, outputDTypes: dtypes)
            let second = lstm2([step[2], first[2], state[4], state[5], state[6], state[7], w[2], w[3], w[4]],
                               template: [("H", hidden), ("OT", dtype), ("RT", dtype)], grid: (32, hidden, 1), threadGroup: (32, 8, 1),
                               outputShapes: shapes, outputDTypes: dtypes)
            let pred = predict([step[2], second[2], w[7], w[8], state[8]],
                               template: [("H", hidden), ("P", projection), ("OT", state[8].dtype), ("RT", state[8].dtype)],
                               grid: (32, projection, 1), threadGroup: (32, 8, 1),
                               outputShapes: [[projection]], outputDTypes: [dtype])[0]
            records.append([step[0], time, step[1], step[2]])
            state = first + second + [pred]
            time = step[3]; syms = step[4]; last = step[5]
        }
        let stacked = (0..<4).map { index in MLX.concatenated(records.map { $0[index] }, axis: 0) }
        finite.append(contentsOf: state.map { MLX.all(MLX.isFinite($0)) })
        return stacked + [time, last, syms] + state + [MLX.all(MLX.stacked(finite))]
        }
    }

    func decode(_ features: MLXArray, length: Int, onToken: ((Int) -> Void)? = nil) -> ParakeetAlignedResult {
        lastFinite = true
        lastError = nil
        guard let model, let head = model.joint, let decoder = model.decoder else {
            lastFinite = false
            return ParakeetAlignment.sentencesToResult(ParakeetAlignment.tokensToSentences([]))
        }
        let projected = head.enc(features[0])
        let pad = (128 - projected.shape[0] % 128) % 128
        let enc = pad == 0 ? projected : MLX.concatenated([projected, MLXArray.zeros([pad, projected.shape[1]], dtype: projected.dtype)], axis: 0)
        let z = MLXArray.zeros([2, 1, hidden], dtype: features.dtype)
        // Stock blank-input proposal is the initial candidate, with committed state still zero.
        let proposal = decoder.predictBatched(MLXArray([Int32(blank)]).reshaped([1, 1]), state: (hidden: z, cell: z), blankToken: Int32(blank))
        let hh = proposal.1.hidden!, cc = proposal.1.cell!
        let pred = head.pred(proposal.0.asType(features.dtype)).reshaped([projection])
        let zero = MLXArray.zeros([hidden], dtype: features.dtype)
        var state = [zero, zero, hh[0, 0].reshaped([hidden]), cc[0, 0].reshaped([hidden]),
                     zero, zero, hh[1, 0].reshaped([hidden]), cc[1, 0].reshaped([hidden]), pred]
        var time = MLXArray([Int32(0)]), last = MLXArray([Int32(blank)]), syms = MLXArray([Int32(0)])
        let n = MLXArray([Int32(length)])
        let sec = Double(model.encoderConfig.subsamplingFactor * model.preprocessConfig.hopLength) / Double(model.preprocessConfig.sampleRate)
        var tokens: [ParakeetAlignedToken] = []
        while true {
            let result: [MLXArray]
            do {
                result = try MLX.withError {
                    let arrays = run([enc, n, time, last, syms] + state + weights)
                    MLX.eval(arrays)
                    return arrays
                }
            } catch {
                lastFinite = false
                lastError = String(describing: error)
                return ParakeetAlignment.sentencesToResult(ParakeetAlignment.tokensToSentences([]))
            }
            lastFinite = lastFinite && result[16].item(Bool.self)
            let ids = result[0].asArray(Int32.self), times = result[1].asArray(Int32.self),
                jumps = result[2].asArray(Int32.self), emits = result[3].asArray(Int32.self)
            for i in ids.indices where emits[i] != 0 {
                onToken?(Int(ids[i]))
                guard !ParakeetTokenizer.isSpecialToken(Int(ids[i]), vocabulary: model.vocabulary) else { continue }
                let id = Int(ids[i]); tokens.append(ParakeetAlignedToken(id: id, text: ParakeetTokenizer.decode(tokens: [id], vocabulary: model.vocabulary), start: Double(times[i]) * sec, duration: Double(jumps[i]) * sec))
            }
            time = result[4]; last = result[5]; syms = result[6]; state = Array(result[7..<16])
            if Int(time.item(Int32.self)) >= length { break }
        }
        return ParakeetAlignment.sentencesToResult(ParakeetAlignment.tokensToSentences(tokens))
    }
}
