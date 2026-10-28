// SPDX-License-Identifier: MIT
// Speech and speaker experts of Nemotron 3.5 Transcribe. Ported from mlx-audio @92decb7 (MIT):
// mlx_audio/stt/models/nemotron_transcribe/perception.py (adapted by NVIDIA from NeMo Speech's
// parallel_expert_encoder.py, Apache-2.0), mlx_audio/vad/models/nemotron_diarization/nemotron_diarization.py and the
// AOSC speaker-cache compression of mlx_audio/vad/models/sortformer/sortformer.py (after NeMo Speech, Apache-2.0).
import Foundation
import MLX
import MLXFFT
import MLXFast
import MLXNN

struct NTEncoderConfig: Sendable {
    var featIn = 128, dModel = 512, nLayers = 31, nHeads = 8, subsampling = 8
    var ffExpansion: Float = 4, qkvBias = false, qkNorm = false, preBlockNorm = true, xscaling = false
    var ropeBase: Float = 10000, rotaryFraction: Float = 1

    init(json: [String: Any]) throws {
        for (key, expected) in [("subsampling", "feature_stacking"), ("self_attention_model", "rope"), ("attn_mode", "full")] {
            if let value = json[key] as? String, value != expected { throw NemotronTranscribeError.config("encoder \(key)") }
        }
        if let v = json["feat_in"] as? Int { featIn = v }
        if let v = json["d_model"] as? Int { dModel = v }
        if let v = json["n_layers"] as? Int { nLayers = v }
        if let v = json["n_heads"] as? Int { nHeads = v }
        if let v = json["subsampling_factor"] as? Int { subsampling = v }
        if let v = (json["ff_expansion"] as? NSNumber)?.floatValue { ffExpansion = v }
        if let v = json["qkv_bias"] as? Bool { qkvBias = v }
        if let v = json["qk_norm"] as? Bool { qkNorm = v }
        if let v = json["pre_block_norm"] as? Bool { preBlockNorm = v }
        if let v = json["xscaling"] as? Bool { xscaling = v }
        if let v = (json["rope_base"] as? NSNumber)?.floatValue { ropeBase = v }
        if let v = (json["rotary_fraction"] as? NSNumber)?.floatValue { rotaryFraction = v }
    }
}

/// The speaker model's cache settings, as `SALMAutomodel.generate` uses them (the PE encoder's online settings).
struct NTSpeakerCacheConfig: Sendable {
    var speakers = 8, fifoLength = 40, cacheLength = 188, updatePeriod = 300, silenceFramesPerSpeaker = 1
    var predScoreThreshold: Float = 0.25, scoresBoostLatest: Float = 0.05, silThreshold: Float = 0.2
    var strongBoostRate: Float = 0.75, weakBoostRate: Float = 1.5, minPosScoresRate: Float = 0.5
    var maxIndex = 99999
}

struct NTPerceptionConfig: Sendable {
    var asr: NTEncoderConfig
    var speaker: NTEncoderConfig
    var cache: NTSpeakerCacheConfig
    var tfDModel = 192
    var outputDim: Int
    var hopLength = 160, nFFT = 512, winLength = 400, mels = 128
    var preemphasis: Float = 0.97
    /// Encoder frames per window and per side of context.
    var windowFrames = 500, leftContext = 50, rightContext = 50
    var thresholded = true, activityThreshold: Float = 0.5, speakerKernelScale: Float = 1

    init(root: [String: Any]) throws {
        guard let pe = root["pe_encoder_config"] as? [String: Any], let perception = root["perception"] as? [String: Any],
              let asrJSON = pe["asr_encoder_cfg"] as? [String: Any], let diar = pe["diarization_model_cfg"] as? [String: Any],
              let diarEncoder = diar["encoder"] as? [String: Any], let modules = diar["sortformer_modules"] as? [String: Any],
              let output = perception["output_dim"] as? Int, let pre = perception["preprocessor"] as? [String: Any]
        else { throw NemotronTranscribeError.config("perception") }
        guard (pe["asr_encoder_type"] as? String ?? "transformer") == "transformer",
              pe["speaker_feature_config_version"] as? Int == 1,
              (pe["asr_normalize_type"] as? String ?? "per_feature") == "per_feature"
        else { throw NemotronTranscribeError.config("speech encoder contract") }
        asr = try NTEncoderConfig(json: asrJSON)
        speaker = try NTEncoderConfig(json: diarEncoder)
        guard asr.subsampling == speaker.subsampling else { throw NemotronTranscribeError.config("encoder strides") }
        outputDim = output
        switch pe["speaker_feature_mode"] as? String {
        case "thresholded":
            thresholded = true
            guard let t = (pe["speaker_activity_threshold"] as? NSNumber)?.floatValue, (0 ... 1).contains(t) else {
                throw NemotronTranscribeError.config("speaker_activity_threshold")
            }
            activityThreshold = t
        case "continuous": thresholded = false
        default: throw NemotronTranscribeError.config("speaker_feature_mode")
        }
        if let v = (pe["spk_kernel_scale"] as? NSNumber)?.floatValue { speakerKernelScale = v }
        windowFrames = pe["online_inference_length"] as? Int ?? 500
        leftContext = max(0, pe["chunk_left_context"] as? Int ?? 50)
        rightContext = max(0, pe["chunk_right_context"] as? Int ?? 50)
        cache = NTSpeakerCacheConfig()
        cache.speakers = modules["num_spks"] as? Int ?? 8
        cache.fifoLength = pe["diar_fifo_len"] as? Int ?? 40
        cache.cacheLength = pe["diar_spkcache_len"] as? Int ?? 188
        cache.updatePeriod = pe["diar_spkcache_update_period"] as? Int ?? 300
        cache.silenceFramesPerSpeaker = modules["spkcache_sil_frames_per_spk"] as? Int ?? 1
        if let v = (modules["pred_score_threshold"] as? NSNumber)?.floatValue { cache.predScoreThreshold = v }
        if let v = (modules["scores_boost_latest"] as? NSNumber)?.floatValue { cache.scoresBoostLatest = v }
        if let v = (modules["sil_threshold"] as? NSNumber)?.floatValue { cache.silThreshold = v }
        if let v = (modules["strong_boost_rate"] as? NSNumber)?.floatValue { cache.strongBoostRate = v }
        if let v = (modules["weak_boost_rate"] as? NSNumber)?.floatValue { cache.weakBoostRate = v }
        if let v = (modules["min_pos_scores_rate"] as? NSNumber)?.floatValue { cache.minPosScoresRate = v }
        if let v = modules["max_index"] as? Int { cache.maxIndex = v }
        tfDModel = modules["tf_d_model"] as? Int ?? 192
        let rate = pre["sample_rate"] as? Int ?? 16000
        hopLength = Int(Double(rate) * ((pre["window_stride"] as? NSNumber)?.doubleValue ?? 0.01))
        winLength = Int(Double(rate) * ((pre["window_size"] as? NSNumber)?.doubleValue ?? 0.025))
        nFFT = pre["n_fft"] as? Int ?? 512
        mels = pre["features"] as? Int ?? 128
        preemphasis = (pre["preemph"] as? NSNumber)?.floatValue ?? 0.97
        guard (pre["window"] as? String ?? "hann") == "hann", (pre["frame_splicing"] as? Int ?? 1) == 1,
              pre["normalize"] == nil || pre["normalize"] is NSNull || pre["normalize"] as? String == "NA"
        else { throw NemotronTranscribeError.config("preprocessor") }
    }
}

// MARK: - Log-mels

/// NeMo's deterministic log-mels with the checkpoint's filter bank and window (no dither).
final class NTMelFeatures: Module {
    var fb: MLXArray
    var window: MLXArray
    let hop: Int, nFFT: Int, preemphasis: Float

    init(_ c: NTPerceptionConfig) {
        fb = MLXArray.zeros([1, c.mels, c.nFFT / 2 + 1]); window = MLXArray.zeros([c.winLength])
        hop = c.hopLength; nFFT = c.nFFT; preemphasis = c.preemphasis
        super.init()
    }

    /// (1, mels, samples / hop) for one recording.
    func callAsFunction(_ audio: MLXArray) -> MLXArray {
        let total = audio.dim(0)
        let count = total / hop
        let frames = MLXArray(Int32(0) ..< Int32(count))
        let positions = expandedDimensions(frames, axis: 1) * Int32(hop) + expandedDimensions(MLXArray(Int32(0) ..< Int32(nFFT)), axis: 0) - Int32(nFFT / 2)
        func gather(_ indices: MLXArray) -> MLXArray {
            let values = audio[clip(indices, min: 0, max: max(0, total - 1))]
            return MLX.where(logicalAnd(indices .>= 0, indices .< Int32(total)), values, MLXArray(Float(0)))
        }
        var x = gather(positions) - preemphasis * gather(positions - 1)
        x = MLX.where(logicalAnd(positions .>= 0, positions .< Int32(total)), x, MLXArray(Float(0)))
        let pad = nFFT - window.dim(0)
        let w = padded(window.asType(.float32), widths: [IntOrPair((pad / 2, pad - pad / 2))])
        let power = pow(abs(MLXFFT.rfft(x * w, axis: -1)), 2)
        let features = log(matmul(power, fb[0].asType(.float32).T) + Float(pow(2.0, -24.0)))
        return expandedDimensions(contiguous(features.T), axis: 0)
    }
}

/// NeMo's per-feature normalization (sample standard deviation over time).
func ntNormalizeFeatures(_ f: MLXArray) -> MLXArray {
    let reference = f[.ellipsis, ..<1]
    let mean = reference + (f - reference).mean(axis: -1, keepDims: true)
    let centered = f - mean
    let variance = (centered * centered).sum(axis: -1, keepDims: true) / Float(max(1, f.dim(-1) - 1))
    return centered / (sqrt(variance) + 1e-5)
}

// MARK: - Feature-stacking RoPE Transformer

final class NTFeatureStacking: Module {
    let factor: Int
    @ModuleInfo(key: "proj") var proj: Linear
    init(_ c: NTEncoderConfig) {
        factor = c.subsampling
        _proj.wrappedValue = Linear(c.featIn * c.subsampling, c.dModel, bias: false)
        super.init()
    }
    /// (b, mel, t) → (b, ceil(t / factor), d) and the encoder length.
    func callAsFunction(_ features: MLXArray, length: Int) -> (MLXArray, Int) {
        var x = features.transposed(0, 2, 1)
        let (b, t, c) = (x.dim(0), x.dim(1), x.dim(2))
        let extra = (factor - t % factor) % factor
        if extra > 0 { x = padded(x, widths: [IntOrPair(0), IntOrPair((0, extra)), IntOrPair(0)]) }
        return (proj(x.reshaped(b, -1, c * factor)), (length + factor - 1) / factor)
    }
}

final class NTEncoderAttention: Module {
    let heads: Int, headDim: Int
    @ModuleInfo(key: "w_qkv") var qkv: Linear
    @ModuleInfo(key: "out_proj") var out: Linear
    @ModuleInfo(key: "q_norm") var qNorm: LayerNorm?
    @ModuleInfo(key: "k_norm") var kNorm: LayerNorm?
    let rope: RoPE
    init(_ c: NTEncoderConfig) {
        heads = c.nHeads; headDim = c.dModel / c.nHeads
        _qkv.wrappedValue = Linear(c.dModel, 3 * c.dModel, bias: c.qkvBias)
        _out.wrappedValue = Linear(c.dModel, c.dModel)
        if c.qkNorm {
            _qNorm.wrappedValue = LayerNorm(dimensions: headDim)
            _kNorm.wrappedValue = LayerNorm(dimensions: headDim)
        }
        rope = RoPE(dimensions: Int(Float(headDim) * c.rotaryFraction), traditional: false, base: c.ropeBase)
        super.init()
    }
    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let (b, t, d) = (x.dim(0), x.dim(1), x.dim(2))
        let p = qkv(x).reshaped(b, t, 3, heads, headDim)
        var q = p[0..., 0..., 0].transposed(0, 2, 1, 3)
        var k = p[0..., 0..., 1].transposed(0, 2, 1, 3)
        let v = p[0..., 0..., 2].transposed(0, 2, 1, 3)
        if let qNorm, let kNorm { q = qNorm(q); k = kNorm(k) }
        q = rope(q); k = rope(k)
        let y = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: pow(Float(headDim), -0.5), mask: .array(mask))
        return out(y.transposed(0, 2, 1, 3).reshaped(b, t, d))
    }
}

final class NTEncoderFeedForward: Module {
    @ModuleInfo(key: "linear1") var linear1: Linear
    @ModuleInfo(key: "linear2") var linear2: Linear
    init(_ c: NTEncoderConfig) {
        let hidden = Int(Float(c.dModel) * c.ffExpansion)
        _linear1.wrappedValue = Linear(c.dModel, hidden)
        _linear2.wrappedValue = Linear(hidden, c.dModel)
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray { linear2(gelu(linear1(x))) }
}

final class NTEncoderBlock: Module {
    @ModuleInfo(key: "norm1") var norm1: LayerNorm
    @ModuleInfo(key: "attn") var attn: NTEncoderAttention
    @ModuleInfo(key: "norm2") var norm2: LayerNorm
    @ModuleInfo(key: "ffn") var ffn: NTEncoderFeedForward
    init(_ c: NTEncoderConfig) {
        _norm1.wrappedValue = LayerNorm(dimensions: c.dModel)
        _attn.wrappedValue = NTEncoderAttention(c)
        _norm2.wrappedValue = LayerNorm(dimensions: c.dModel)
        _ffn.wrappedValue = NTEncoderFeedForward(c)
        super.init()
    }
    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let y = x + attn(norm1(x), mask: mask)
        return y + ffn(norm2(y))
    }
}

final class NTEncoder: Module {
    @ModuleInfo(key: "pre_encode") var preEncode: NTFeatureStacking
    @ModuleInfo(key: "embed_norm") var embedNorm: LayerNorm?
    @ModuleInfo(key: "layers") var layers: [NTEncoderBlock]
    @ModuleInfo(key: "final_norm") var finalNorm: LayerNorm
    let scale: Float
    init(_ c: NTEncoderConfig) {
        _preEncode.wrappedValue = NTFeatureStacking(c)
        if c.preBlockNorm { _embedNorm.wrappedValue = LayerNorm(dimensions: c.dModel) }
        _layers.wrappedValue = (0 ..< c.nLayers).map { _ in NTEncoderBlock(c) }
        _finalNorm.wrappedValue = LayerNorm(dimensions: c.dModel)
        scale = c.xscaling ? sqrt(Float(c.dModel)) : 1
        super.init()
    }
    func callAsFunction(_ x: MLXArray, length: Int) -> MLXArray {
        let mask = (MLXArray(Int32(0) ..< Int32(x.dim(1))) .< Int32(length)).reshaped(1, 1, 1, -1)
        var h = x * scale
        if let embedNorm { h = embedNorm(h) }
        for layer in layers { h = layer(h, mask: mask) }
        return finalNorm(h)
    }
}

// MARK: - Speaker model (Sortformer head + AOSC cache)

final class NTSpeakerModules: Module {
    @ModuleInfo(key: "encoder_proj") var encoderProj: Linear
    @ModuleInfo(key: "first_hidden_to_hidden") var hidden: Linear
    @ModuleInfo(key: "single_hidden_to_spks") var single: Linear
    @ModuleInfo(key: "hidden_to_spks") var pair: Linear
    @ModuleInfo(key: "subpixel_upsample") var upsample: Conv1d
    @ParameterInfo(key: "learnable_sil_emb") var silence: MLXArray
    init(fc: Int, tf: Int, speakers: Int, factor: Int) {
        _encoderProj.wrappedValue = Linear(fc, tf)
        _hidden.wrappedValue = Linear(tf, tf)
        _single.wrappedValue = Linear(tf, speakers)
        _pair.wrappedValue = Linear(2 * tf, speakers)
        _upsample.wrappedValue = Conv1d(inputChannels: tf, outputChannels: tf * factor, kernelSize: 3, padding: 1)
        _silence.wrappedValue = MLXArray.zeros([fc])
        super.init()
    }
    /// (b, t, fc) → (b, t · factor, speakers) sigmoid activities.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = encoderProj(x)
        let (b, d) = (h.dim(0), h.dim(2))
        h = upsample(h).reshaped(b, -1, d)
        h = hidden(relu(h))
        return sigmoid(single(relu(h)))
    }
}

final class NTSpeakerState {
    var cache: MLXArray, cachePreds: MLXArray, fifo: MLXArray, fifoPreds: MLXArray
    var compressed = false
    init(width: Int, speakers: Int, dtype: DType) {
        cache = MLXArray.zeros([1, 0, width], dtype: dtype); fifo = MLXArray.zeros([1, 0, width], dtype: dtype)
        cachePreds = MLXArray.zeros([1, 0, speakers]); fifoPreds = MLXArray.zeros([1, 0, speakers])
    }
}

final class NTSpeakerModel: Module {
    @ModuleInfo(key: "encoder") var encoder: NTEncoder
    @ModuleInfo(key: "sortformer_modules") var modules: NTSpeakerModules
    @ModuleInfo(key: "preprocessor") var preprocessor: NTMelFeatures
    let config: NTSpeakerCacheConfig
    let factor: Int

    init(_ c: NTPerceptionConfig) {
        config = c.cache; factor = c.speaker.subsampling
        _encoder.wrappedValue = NTEncoder(c.speaker)
        _modules.wrappedValue = NTSpeakerModules(fc: c.speaker.dModel, tf: c.tfDModel, speakers: c.cache.speakers, factor: c.speaker.subsampling)
        _preprocessor.wrappedValue = NTMelFeatures(c)
        super.init()
    }

    var dtype: DType { encoder.preEncode.proj.weight.dtype }

    /// One feature window; context predictions never enter the FIFO.
    func step(_ features: MLXArray, state: NTSpeakerState, central: Int, length: Int, leftContextFrames: Int) -> MLXArray {
        let speakers = config.speakers
        let (chunk, encoded) = encoder.preEncode(features.asType(dtype), length: length)
        let (cacheLength, fifoLength) = (state.cache.dim(1), state.fifo.dim(1))
        let combined = concatenated([state.cache, state.fifo, chunk], axis: 1)
        var high = modules(encoder(combined, length: encoded + cacheLength + fifoLength))
        let valid = MLXArray(Int32(0) ..< Int32(high.dim(1))) .< Int32((encoded + cacheLength + fifoLength) * factor)
        high = high * valid.reshaped(1, -1, 1)
        let low = high.asType(.float32).reshaped(1, -1, factor, speakers).mean(axis: 2)
        let n = (central + factor - 1) / factor
        let left = leftContextFrames / factor
        let start = cacheLength + fifoLength + left
        let result = high[0, (start * factor) ..< (start * factor + central)].asType(.float32)
        state.fifo = concatenated([state.fifo, chunk[0..., left ..< (left + n)]], axis: 1)
        state.fifoPreds = concatenated([low[0..., cacheLength ..< (cacheLength + fifoLength)], low[0..., start ..< (start + n)]], axis: 1)
        if state.fifo.dim(1) > config.fifoLength {
            let pop = min(state.fifo.dim(1), max(config.updatePeriod, state.fifo.dim(1) - config.fifoLength))
            state.cache = concatenated([state.cache, state.fifo[0..., ..<pop]], axis: 1)
            let previous = state.compressed ? state.cachePreds : low[0..., ..<cacheLength]
            state.cachePreds = concatenated([previous, state.fifoPreds[0..., ..<pop]], axis: 1)
            state.fifo = state.fifo[0..., pop...]
            state.fifoPreds = state.fifoPreds[0..., pop...]
            if state.cache.dim(1) > config.cacheLength {
                (state.cache, state.cachePreds) = NTSpeakerCache.compress(
                    state.cache, state.cachePreds, silence: expandedDimensions(modules.silence, axis: 0), config)
                state.compressed = true
            }
        }
        eval(result, state.cache, state.cachePreds, state.fifo, state.fifoPreds)
        return result
    }
}

/// Arrival-order speaker cache compression (AOSC): keep the most informative frames per speaker.
enum NTSpeakerCache {
    static func logPredScores(_ preds: MLXArray, threshold: Float) -> MLXArray {
        let logP = log(clip(preds, min: threshold))
        let log1P = log(clip(1.0 - preds, min: threshold))
        let sum = broadcast(log1P.sum(axis: 2, keepDims: true), to: preds.shape)
        return logP - log1P + sum - Float(log(0.5))
    }

    static func disableLowScores(_ preds: MLXArray, _ scores: MLXArray, minPositive: Int) -> MLXArray {
        let negInf = MLXArray(-Float.infinity)
        let speech = preds .> 0.5
        var s = MLX.where(speech, scores, negInf)
        let positive = s .> 0
        let count = positive.asType(.float32).sum(axis: 1, keepDims: true)
        let enough = count .>= Float(minPositive)
        s = MLX.where(logicalAnd(logicalAnd(logicalNot(positive), speech), enough), negInf, s)
        return s
    }

    static func boostTopK(_ scores: MLXArray, count: Int, scale: Float) -> MLXArray {
        guard count > 0 else { return scores }
        let (frames, speakers) = (scores.dim(1), scores.dim(2))
        let k = min(count, frames)
        let boost = -scale * Float(log(0.5))
        var slices: [MLXArray] = []
        for spk in 0 ..< speakers {
            let flat = scores[0..., 0..., spk]
            let top = argPartition(-flat, kth: k - 1, axis: 1)[0..., ..<k]
            let finite = flat .> -Float.infinity
            let rows = expandedDimensions(MLXArray(Int32(0) ..< Int32(flat.dim(0))), axis: 1)
            let mask = MLXArray.zeros(like: flat).at[rows, top].add(MLXArray.ones(top.shape, dtype: .float32))
            slices.append(flat + mask * boost * finite.asType(.float32))
        }
        return stacked(slices, axis: -1)
    }

    static func compress(_ embs: MLXArray, _ preds: MLXArray, silence: MLXArray, _ c: NTSpeakerCacheConfig) -> (MLXArray, MLXArray) {
        let speakers = c.speakers, length = c.cacheLength, sil = c.silenceFramesPerSpeaker
        let perSpeaker = length / speakers - sil
        let strong = Int((Float(perSpeaker) * c.strongBoostRate).rounded(.down))
        let weak = Int((Float(perSpeaker) * c.weakBoostRate).rounded(.down))
        let minPositive = Int((Float(perSpeaker) * c.minPosScoresRate).rounded(.down))
        var scores = logPredScores(preds, threshold: c.predScoreThreshold)
        scores = disableLowScores(preds, scores, minPositive: minPositive)
        if c.scoresBoostLatest > 0 && scores.dim(1) > length {
            let boost = concatenated([
                MLXArray.zeros([scores.dim(0), length, speakers]),
                MLXArray.full([scores.dim(0), scores.dim(1) - length, speakers], values: MLXArray(c.scoresBoostLatest))
            ], axis: 1)
            scores = scores + boost
        }
        scores = boostTopK(scores, count: strong, scale: 2)
        scores = boostTopK(scores, count: weak, scale: 1)
        if sil > 0 {
            scores = concatenated([scores, MLXArray.full([scores.dim(0), sil, speakers], values: MLXArray(Float.infinity))], axis: 1)
        }
        // Top frames across speakers, in time order.
        let (batch, frames) = (scores.dim(0), scores.dim(1))
        let flat = scores.transposed(0, 2, 1).reshaped(batch, -1)
        let k = min(length, flat.dim(1))
        var top = argPartition(-flat, kth: k - 1, axis: 1)[0..., ..<k]
        let values = takeAlong(flat, top, axis: 1)
        top = MLX.where(values .> -Float.infinity, top, MLXArray(Int32(c.maxIndex)))
        top = sorted(top, axis: 1)
        var disabled = top .== Int32(c.maxIndex)
        top = top % Int32(frames)
        disabled = logicalOr(disabled, top .>= Int32(frames - sil))
        top = MLX.where(disabled, MLXArray(Int32(0)), top)
        // Gather, replacing disabled positions with the silence embedding.
        let width = embs.dim(2)
        let index = expandedDimensions(top, axis: -1)
        var gathered = takeAlong(embs, broadcast(index, to: [top.dim(0), top.dim(1), width]), axis: 1)
        let mask = expandedDimensions(disabled, axis: -1)
        gathered = MLX.where(mask, broadcast(expandedDimensions(silence, axis: 1), to: [top.dim(0), length, width]), gathered)
        var gatheredPreds = takeAlong(preds, broadcast(index, to: [top.dim(0), top.dim(1), speakers]), axis: 1)
        gatheredPreds = MLX.where(mask, MLXArray(Float(0)), gatheredPreds)
        eval(gathered, gatheredPreds)
        return (gathered, gatheredPreds)
    }
}

// MARK: - Parallel expert encoder

struct NTConstant { let value: MLXArray }

final class NTParallelExpertEncoder: Module {
    @ModuleInfo(key: "asr_encoder") var asrEncoder: NTEncoder
    @ModuleInfo(key: "diarization_model") var speaker: NTSpeakerModel
    @ModuleInfo(key: "asr_norm") var asrNorm: LayerNorm
    @ModuleInfo(key: "diar_norm") var diarNorm: LayerNorm
    let config: NTPerceptionConfig
    /// Not a parameter: a constant derived from the width (wrapped so module reflection skips it).
    private let kernel: NTConstant
    var speakerKernel: MLXArray { kernel.value }

    init(_ c: NTPerceptionConfig) {
        config = c
        _asrEncoder.wrappedValue = NTEncoder(c.asr)
        _speaker.wrappedValue = NTSpeakerModel(c)
        _asrNorm.wrappedValue = LayerNorm(dimensions: c.asr.dModel)
        _diarNorm.wrappedValue = LayerNorm(dimensions: c.cache.speakers)
        // Sinusoidal speaker kernel: (speakers, width), sin/cos interleaved.
        let width = c.asr.dModel
        let position = MLXArray(Int32(0) ..< Int32(c.cache.speakers)).reshaped(-1, 1)
        let frequencies = exp(MLXArray(stride(from: 0, to: width, by: 2).map { Float($0) }) * Float(-(log(10000.0) / Double(width))))
        let angles = position * frequencies
        kernel = NTConstant(value: stacked([sin(angles), cos(angles)], axis: -1).reshaped(-1, width))
        super.init()
    }

    func fuse(_ states: MLXArray, _ probabilities: MLXArray) -> MLXArray {
        var p = probabilities.asType(states.dtype)
        if config.thresholded { p = (p .> config.activityThreshold).asType(states.dtype) }
        let targets = diarNorm(p)
        let infusion = matmul(targets, speakerKernel.asType(targets.dtype))
        return asrNorm(states) + config.speakerKernelScale * infusion
    }

    /// One recording of unnormalized (1, mel, frames) features → (1, encoder frames, width).
    func callAsFunction(_ features: MLXArray) -> MLXArray {
        let factor = config.asr.subsampling
        let size = config.windowFrames * factor, left = config.leftContext * factor, right = config.rightContext * factor
        let normalized = ntNormalizeFeatures(features).asType(asrNorm.weight?.dtype ?? .bfloat16)
        let state = NTSpeakerState(width: config.speaker.dModel, speakers: config.cache.speakers, dtype: speaker.dtype)
        let total = features.dim(-1)
        var outputs: [MLXArray] = []
        var start = 0
        while start < total {
            let end = min(start + size, total)
            let (cs, ce) = (max(0, start - left), min(total, end + right))
            let length = ce - cs
            let (x, encodedLength) = asrEncoder.preEncode(normalized[0..., 0..., cs ..< ce], length: length)
            var encoded = asrEncoder(x, length: encodedLength)
            let first = (start - cs) / factor
            let count = (end + factor - 1) / factor - (start + factor - 1) / factor
            encoded = encoded[0..., first ..< (first + count)]
            // The padded final encoder frame is included: NeMo's head pools all eight predictions before trimming.
            let probabilities = speaker.step(
                features[0..., 0..., cs ..< ce], state: state, central: count * factor, length: length, leftContextFrames: start - cs
            ).reshaped(1, count, factor, -1).mean(axis: 2)
            let output = fuse(encoded, probabilities)
            eval(output)
            outputs.append(output)
            start += size
        }
        return concatenated(outputs, axis: 1)
    }
}

final class NTPerception: Module {
    @ModuleInfo(key: "preprocessor") var preprocessor: NTMelFeatures
    @ModuleInfo(key: "encoder") var encoder: NTParallelExpertEncoder
    @ModuleInfo(key: "proj") var proj: Linear
    init(_ c: NTPerceptionConfig) {
        _preprocessor.wrappedValue = NTMelFeatures(c)
        _encoder.wrappedValue = NTParallelExpertEncoder(c)
        _proj.wrappedValue = Linear(c.asr.dModel, c.outputDim)
        super.init()
    }
    func callAsFunction(_ audio: MLXArray) -> MLXArray { proj(encoder(preprocessor(audio))) }
}
