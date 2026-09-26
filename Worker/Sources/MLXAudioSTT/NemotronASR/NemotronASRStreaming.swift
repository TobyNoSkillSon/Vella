import Foundation
import MLX
import MLXNN

// Cache-aware streaming for Nemotron 3.5 ASR (mirrors the model's native mode).
// Each conformer layer keeps an attention cache (last `leftCache` attention-input
// frames) and a conv cache (last `convKernel-1` GLU-output frames); subsampling is
// incremental with a 16-frame mel cache. Output is frame-identical to the offline
// (chunked_limited) encoder at the native chunk size (rightContext + 1), so the
// streamed transcript equals `decode(...)`.

private let nemoPreEncodeMelCache = 16

/// Steady-state `linear_pos(posEmb)` per layer. With a full attention cache the
/// relative-position window is the same every chunk, so the projection is too.
final class NemotronASRPositionCache {
    var key: (offset: Int, length: Int)?
    var projections: [MLXArray?] = []
}  // >= causal receptive field of 8x dw-striding

/// Per-stream cache-aware encoder state, carried across chunks (and, in a live
/// session, across `step` calls). Holding it outside the chunk loop is what lets
/// the same loop serve both the one-shot `generateStream` and the incremental
/// `NemotronASRStreamSession`.
final class NemotronASRStreamEncoderState {
    var attnCache: [MLXArray?]
    var convCache: [MLXArray?]
    var melCache: MLXArray?
    var emitted = 0   // subsampled frames already emitted to the decoder (absolute)
    var consumed = 0  // mel frames already consumed by the encoder (absolute)
    /// Projected K/V of the last `leftCache` frames (VELLA_NEMO_KVCACHE=1 mode).
    /// Optimized-path switches, fixed per session (stock: both false).
    var usePositionCache = false
    var useKeyValueCache = false
    var keyCache: [MLXArray?]
    var valueCache: [MLXArray?]
    var live: [MLXArray] { (attnCache + convCache + keyCache + valueCache).compactMap { $0 } + [melCache].compactMap { $0 } }

    init(layers: Int) {
        attnCache = [MLXArray?](repeating: nil, count: layers)
        convCache = [MLXArray?](repeating: nil, count: layers)
        keyCache = [MLXArray?](repeating: nil, count: layers)
        valueCache = [MLXArray?](repeating: nil, count: layers)
    }
}

extension NemotronASRModel {
    /// `NemoRelPositionMultiHeadAttention.callAsFunction` for one streaming chunk,
    /// op for op, with the steady-state position projection reused and (opt-in)
    /// K/V projected once per frame instead of over the whole cache every chunk.
    /// Returns (attention output, next attention-input cache or nil in K/V mode).
    private func streamAttention(
        _ attn: NemoRelPositionMultiHeadAttention, layer: Int, _ xn: MLXArray, attnCache: MLXArray?,
        state: NemotronASRStreamEncoderState, leftCache: Int
    ) -> (MLXArray, MLXArray) {
        let nHead = attn.nHead, headDim = attn.headDim, scale = attn.scale
        let qSeq = xn.shape[1]
        let kProj: MLXArray, vProj: MLXArray, cacheLen: Int, attnNext: MLXArray
        if state.useKeyValueCache {
            cacheLen = state.keyCache[layer]?.shape[1] ?? 0
            let newK = attn.linearK(xn), newV = attn.linearV(xn)
            kProj = state.keyCache[layer].map { MLX.concatenated([$0, newK], axis: 1) } ?? newK
            vProj = state.valueCache[layer].map { MLX.concatenated([$0, newV], axis: 1) } ?? newV
            let len = kProj.shape[1]
            state.keyCache[layer] = kProj[0..., max(0, len - leftCache)..<len, 0...]
            state.valueCache[layer] = vProj[0..., max(0, len - leftCache)..<len, 0...]
            attnNext = xn[0..., 0..<0, 0...]
        } else {
            cacheLen = attnCache?.shape[1] ?? 0
            let kv = attnCache == nil ? xn : MLX.concatenated([attnCache!, xn], axis: 1)
            kProj = attn.linearK(kv); vProj = attn.linearV(kv)
            let len = kv.shape[1]
            attnNext = kv[0..., max(0, len - leftCache)..<len, 0...]
        }
        let qProj = attn.linearQ(xn)
        var pProj: MLXArray
        let cache = positionCache
        if state.usePositionCache, let key = cache.key, key == (cacheLen, qSeq), let hit = cache.projections[layer] {
            pProj = hit
        } else {
            pProj = attn.linearPos(encoder.posEnc(xn, offset: cacheLen).1)
            if state.usePositionCache && cacheLen == leftCache {
                if cache.key == nil || cache.key! != (cacheLen, qSeq) {
                    cache.key = (cacheLen, qSeq)
                    cache.projections = [MLXArray?](repeating: nil, count: encoder.layers.count)
                }
                cache.projections[layer] = pProj
            }
        }
        let batch = qProj.shape[0]
        let kSeq = kProj.shape[1]
        let posLen = pProj.shape[1]
        if pProj.shape[0] == 1 && batch > 1 { pProj = MLX.broadcast(pProj, to: [batch, posLen, attn.nFeat]) }
        let qHeads = qProj.reshaped(batch, qSeq, nHead, headDim)
        let qU = (qHeads + attn.posBiasU.asType(qHeads.dtype)).transposed(0, 2, 1, 3)
        let qV = (qHeads + attn.posBiasV.asType(qHeads.dtype)).transposed(0, 2, 1, 3)
        let kHeads = kProj.reshaped(batch, kSeq, nHead, headDim).transposed(0, 2, 1, 3)
        let vHeads = vProj.reshaped(batch, kSeq, nHead, headDim).transposed(0, 2, 1, 3)
        let pHeads = pProj.reshaped(batch, posLen, nHead, headDim).transposed(0, 2, 1, 3)
        var matrixBD = MLX.matmul(qV, pHeads.swappedAxes(-2, -1))
        let tq = matrixBD.shape[2]
        let padded = MLX.padded(matrixBD, widths: [.init(0), .init(0), .init(0), .init((1, 0))])
        matrixBD = padded.reshaped([batch, nHead, posLen + 1, tq])[0..., 0..., 1..., 0...].reshaped([batch, nHead, tq, posLen])
        matrixBD = matrixBD[0..., 0..., 0..., ..<kSeq] * MLXArray(scale).asType(matrixBD.dtype)
        let attended = MLXFast.scaledDotProductAttention(
            queries: qU, keys: kHeads, values: vHeads, scale: scale, mask: .array(matrixBD))
        let out = attended.transposed(0, 2, 1, 3).reshaped(batch, qSeq, -1)
        return (attn.linearOut(out), attnNext)
    }

    private func nemoStreamBlock(
        _ block: NemotronASRConformerBlock,
        layer: Int,
        state: NemotronASRStreamEncoderState,
        _ x: MLXArray,
        attnCache: MLXArray?,
        convCache: MLXArray?,
        leftCache: Int,
        convLeft: Int
    ) -> (MLXArray, MLXArray, MLXArray) {
        var residual = x + MLXArray(Float(0.5)).asType(x.dtype) * block.feedForward1(block.normFeedForward1(x))

        // cache-aware self-attention (Q = chunk, K/V = [cache ++ chunk])
        let xn = block.normSelfAtt(residual)
        let attnNext: MLXArray
        if state.usePositionCache || state.useKeyValueCache {
            let r = streamAttention(block.selfAttn, layer: layer, xn, attnCache: attnCache, state: state, leftCache: leftCache)
            residual = residual + r.0
            attnNext = r.1
        } else {
            let cacheLen = attnCache?.shape[1] ?? 0
            let kv = attnCache == nil ? xn : MLX.concatenated([attnCache!, xn], axis: 1)
            let posEmb = encoder.posEnc(xn, offset: cacheLen).1
            residual = residual + block.selfAttn(xn, kv, kv, posEmb: posEmb, mask: nil)
            let kvLen = kv.shape[1]
            attnNext = kv[0..., max(0, kvLen - leftCache)..<kvLen, 0...]
        }

        // cache-aware causal conv (prepend conv cache instead of zero-padding)
        let xc = block.normConv(residual)
        let pw = block.conv.pointwiseConv1(xc)
        let sp = pw.split(parts: 2, axis: 2)
        let g = sp[0] * sigmoid(sp[1])  // (1, c, d)
        let cc = convCache ?? MLXArray.zeros([g.shape[0], convLeft, g.shape[2]], dtype: g.dtype)
        let din = MLX.concatenated([cc, g], axis: 1)
        let dw = block.conv.depthwiseConv(din)
        let dinLen = din.shape[1]
        let convNext = din[0..., max(0, dinLen - convLeft)..<dinLen, 0...]
        var y = block.conv.batchNorm(dw)
        y = silu(y)
        residual = residual + block.conv.pointwiseConv2(y)

        residual = residual + MLXArray(Float(0.5)).asType(residual.dtype)
            * block.feedForward2(block.normFeedForward2(residual))
        return (block.normOut(residual), attnNext, convNext)
    }

    /// Run encoder + prompt fusion in cache-aware chunks, invoking `onChunk` with
    /// each chunk's post-prompt encoder frames (1, c, d). Frame-identical to offline.
    /// One-shot wrapper: encodes the whole `mel` with a fresh state and a flushed tail.
    func cacheAwareStreamEncode(
        _ mel: MLXArray,
        language: String?,
        chunkFrames: Int? = nil,
        onChunk: (MLXArray) -> Void
    ) {
        var features = mel
        if features.ndim == 2 { features = features.expandedDimensions(axis: 0) }
        let state = NemotronASRStreamEncoderState(layers: encoder.layers.count)
        streamEncodeChunks(
            features,
            language: language,
            limit: features.shape[1],
            chunkFrames: chunkFrames,
            flushTail: true,
            state: state,
            onChunk: onChunk
        )
    }

    /// Resumable cache-aware encoder loop shared by `cacheAwareStreamEncode` (one-shot)
    /// and `NemotronASRStreamSession` (incremental). Processes `mel` frames in
    /// `[state.consumed, limit)`:
    ///   * `flushTail == false`: only whole `chunkMel`-sized chunks are emitted; a
    ///     trailing partial chunk is left for a later call (when more audio arrives).
    ///   * `flushTail == true`: the final partial chunk is processed and all of its
    ///     subsampled frames are emitted (matches the offline encoder tail).
    /// `limit` lets a live caller cap processing to *frozen* mel frames (those whose
    /// STFT window is fully covered by real audio), keeping the output bit-identical
    /// to the offline encode. All counters live in `state`, so calls compose.
    func streamEncodeChunks(
        _ mel: MLXArray,
        language: String?,
        limit: Int,
        melBase: Int = 0,
        preserveInputDType: Bool = false,
        chunkFrames: Int?,
        flushTail: Bool,
        state: NemotronASRStreamEncoderState,
        onChunk: (MLXArray) -> Void
    ) {
        var features = mel
        if features.ndim == 2 { features = features.expandedDimensions(axis: 0) }
        if !preserveInputDType { features = features.asType(computeDType) }

        let sf = encoderConfig.subsamplingFactor
        let right = defaultAttContextSize.count > 1 ? defaultAttContextSize[1] : 13
        let cf = chunkFrames ?? max(1, right + 1)
        let chunkMel = cf * sf
        let leftCache = defaultAttContextSize.first ?? 56
        let convLeft = encoderConfig.convKernelSize - 1

        while state.consumed < limit {
            let end = min(state.consumed + chunkMel, limit)
            // Mid-stream: defer a partial trailing chunk until the next call / flush.
            if !flushTail && (end - state.consumed) < chunkMel { break }

            let m = features[0..., (state.consumed - melBase)..<(end - melBase), 0...]
            let cacheLen = state.melCache?.shape[1] ?? 0
            let win = state.melCache == nil ? m : MLX.concatenated([state.melCache!, m], axis: 1)
            let winLen = win.shape[1]
            let lengths = MLXArray([Int32(winLen)]).asType(.int32)
            let sub = encoder.preEncode(win, lengths: lengths).0  // (1, k, d)

            let isFinal = flushTail && (end >= limit)
            let base = (state.consumed - cacheLen) / sf
            let lo = state.emitted - base
            let hi = isFinal ? sub.shape[1] : (end / sf - base)
            state.consumed = end
            state.melCache = win[0..., max(0, winLen - nemoPreEncodeMelCache)..<winLen, 0...]

            if hi <= lo {
                state.emitted = base + max(lo, hi)
                continue
            }
            state.emitted = base + hi
            var h = sub[0..., lo..<hi, 0...]
            for li in encoder.layers.indices {
                let r = nemoStreamBlock(
                    encoder.layers[li], layer: li, state: state, h,
                    attnCache: state.attnCache[li], convCache: state.convCache[li],
                    leftCache: leftCache, convLeft: convLeft
                )
                h = r.0
                state.attnCache[li] = r.1
                state.convCache[li] = r.2
            }
            onChunk(applyPrompt(h, language: language))
        }
    }
}
