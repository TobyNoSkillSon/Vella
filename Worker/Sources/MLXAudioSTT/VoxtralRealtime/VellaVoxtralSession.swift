import Foundation
import MLX

/// Production feed/step/close contract. No utterance token/PCM/transcript history.
/// Encoder positions stay absolute and KV slides; no periodic acoustic resets.
public final class VellaVoxtralSession {
    private let model: VoxtralRealtimeModel
    private var mel: VoxtralRealtimeMelStream
    private var conv = VoxtralRealtimeConvStemState()
    private var caches: [VoxtralRealtimeEncoderKVCache?]
    private var encoderPosition = 0
    private var projectionTail: MLXArray?
    private var adapter: MLXArray?
    private var adapterBase = 0
    private var decoderCache: [VoxtralRealtimeDecoderKVCache?]?
    private var logits: MLXArray?
    private var position: Int
    private let promptLength: Int
    private let delayTokens: Int
    private var seeded = false
    private var closed = false
    private var transcript = VoxtralRealtimeTranscriptText()
    public private(set) var done = false

    public init(model: VoxtralRealtimeModel) {
        self.model = model
        model.ensureAdaScales(transcriptionDelayMs: 480)
        delayTokens = model.numDelayTokens(480)
        promptLength = 1 + model.config.nLeftPadTokens + delayTokens
        position = promptLength
        let audio = model.config.audioEncodingArgs
        mel = VoxtralRealtimeMelStream(leftPadSamples: model.config.nLeftPadTokens * 1280,
            melFilters: model.ensureMelFilters(), windowSize: audio.windowSize,
            hopLength: audio.hopLength, globalLogMelMax: audio.globalLogMelMax)
        caches = Array(repeating: nil, count: model.encoder.transformerLayers.count)
    }
    private func ingest(_ samples: [Float]) {
        let features = mel.append(samples)
        guard features.shape[1] > 0 else { return }
        let rows = model.encoder.convStemStep(features, state: &conv)
        guard rows.shape[0] > 0 else { return }
        // Preserve every causal row, including unaligned downsample tails.
        var encoded = model.encoder.encodeIncremental(rows, startPos: encoderPosition, caches: &caches)
        encoderPosition += rows.shape[0]
        if let tail = projectionTail { encoded = concatenated([tail, encoded], axis: 0) }
        let ds = model.config.encoderArgs.downsampleFactor
        let usable = encoded.shape[0] - encoded.shape[0] % ds
        projectionTail = usable < encoded.shape[0] ? encoded[usable...].contiguous() : nil
        guard usable > 0 else { return }
        let projected = model.encoder.downsampleAndProject(encoded[..<usable])
        adapter = adapter == nil ? projected : concatenated([adapter!, projected], axis: 0)
        eval(adapter!)
    }
    public func feed(_ samples: [Float], final: Bool) throws {
        guard !done, !closed else { throw NSError(domain: "VellaStreaming", code: 3) }
        if !seeded { ingest([]); seeded = true } // Python seeds left-pad separately.
        if !samples.isEmpty { ingest(samples) }
        if final {
            ingest(Array(repeating: 0, count: (delayTokens + 11) * 1280))
            // Closing emits exactly floor(total/hop) frames. The frontend already
            // seeded centered left zeros; right reflection sees the zero pad only.
            ingest(Array(repeating: 0, count: mel.finishTailPadCount))
            closed = true
        }
    }
    public func step() -> String {
        guard !done else { return "" }
        if logits == nil {
            guard let adapter, adapter.shape[0] >= promptLength else {
                if closed { done = true }
                return ""
            }
            let ids = [model.config.bosTokenId] + Array(repeating: model.config.streamingPadTokenId, count: promptLength - 1)
            let embeddings = model.decoder.embedTokens(MLXArray(ids.map(Int32.init)))
            let result = model.decoder(adapter[..<promptLength] + embeddings, startPos: 0, cache: nil)
            decoderCache = result.1
            logits = model.decoder.logits(result.0[promptLength - 1])
            eval(logits!)
        }
        for _ in 0..<64 {
            let available = adapterBase + (adapter?.shape[0] ?? 0)
            if position >= available && !closed { break }
            let token = model.sample(logits: logits!, temperature: 0)
            // Include token bytes as Python wrapper does; tokenizer handles EOS.
            transcript.append(model.streamingTokenBytes(token))
            if position >= available { done = true; break }
            let embedding = adapter![position - adapterBase] + model.decoder.embedToken(tokenId: token)
            let result = model.decoder(embedding.expandedDimensions(axis: 0), startPos: position, cache: decoderCache)
            decoderCache = result.1
            logits = model.decoder.logits(result.0[0]); eval(logits!)
            if token == model.config.eosTokenId { done = true; break }
            position += 1
        }
        // Equivalent to retiring consumed Python _adapter_frames after every step.
        if let rows = adapter {
            let drop = min(max(position - adapterBase, 0), rows.shape[0])
            adapter = drop < rows.shape[0] ? rows[drop...].contiguous() : nil
            adapterBase += drop
        }
        var arrays = caches.compactMap { $0 }.flatMap { [$0.keys, $0.values] }
        arrays += (decoderCache ?? []).compactMap { $0 }.flatMap { [$0.keys, $0.values] }
        if let projectionTail { arrays.append(projectionTail) }
        if let adapter { arrays.append(adapter) }
        if let carry = conv.conv1Carry { arrays.append(carry) }
        if let carry = conv.conv2Carry { arrays.append(carry) }
        if !arrays.isEmpty { eval(arrays) }
        Memory.clearCache()
        return transcript.drainStable(final: done)
    }
}

// Use the same stock fused primitive as Python, not a hand-expanded sin/cos
// sequence whose low-precision rotation changes token ties.
func vellaVoxtralRoPE(_ x: MLXArray, heads: Int, headDim: Int, theta: Float, offset: Int) -> MLXArray {
    let rows = x.shape[0]
    let shaped = x.reshaped(1, rows, heads, headDim).transposed(0, 2, 1, 3)
    return MLXFast.RoPE(shaped, dimensions: headDim, traditional: true, base: theta, scale: 1, offset: offset)
        .transposed(0, 2, 1, 3).reshaped(rows, heads * headDim)
}
