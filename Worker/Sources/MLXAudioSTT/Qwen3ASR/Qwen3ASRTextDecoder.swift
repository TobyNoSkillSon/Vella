//
//  Qwen3ASRTextDecoder.swift
//  MLXAudioSTT
//
// Created by Prince Canuma on 06/02/2026.
//

import Foundation
import MLX
import MLXNN
import MLXAudioCore
import MLXLMCommon
import Tokenizers

// MARK: - Text Decoder Attention

class Qwen3ASRTextAttention: Module {
    let hiddenSize: Int
    let numHeads: Int
    let numKvHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE

    init(_ config: Qwen3TextConfig, layerIdx: Int) {
        self.hiddenSize = config.hiddenSize
        self.numHeads = config.numAttentionHeads
        self.numKvHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = pow(Float(config.headDim), -0.5)

        self._qProj.wrappedValue = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        self._kProj.wrappedValue = Linear(config.hiddenSize, numKvHeads * headDim, bias: false)
        self._vProj.wrappedValue = Linear(config.hiddenSize, numKvHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, config.hiddenSize, bias: false)

        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self.rope = RoPE(dimensions: headDim, traditional: false, base: config.ropeTheta)
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let B = hiddenStates.dim(0)
        let L = hiddenStates.dim(1)

        var queries = qProj(hiddenStates)
        var keys = kProj(hiddenStates)
        var values = vProj(hiddenStates)

        queries = queries.reshaped(B, L, numHeads, headDim)
        keys = keys.reshaped(B, L, numKvHeads, headDim)
        values = values.reshaped(B, L, numKvHeads, headDim)

        // Apply Q/K normalization before transpose
        queries = qNorm(queries)
        keys = kNorm(keys)

        queries = queries.transposed(0, 2, 1, 3)
        keys = keys.transposed(0, 2, 1, 3)
        values = values.transposed(0, 2, 1, 3)

        // Apply RoPE using the pre-update cache offset, matching the previous
        // manual cache.update + scaledDotProductAttention sequence.
        if let cache = cache {
            queries = rope(queries, offset: cache.offset)
            keys = rope(keys, offset: cache.offset)
        } else {
            queries = rope(queries)
            keys = rope(keys)
        }

        // Routes to quantized attention when the cache is a QuantizedKVCache,
        // and performs the cache update internally for all cache types.
        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        ).transposed(0, 2, 1, 3).reshaped(B, L, -1)

        return oProj(output)
    }
}

// MARK: - Text Decoder MLP

class Qwen3ASRTextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: Qwen3TextConfig) {
        self._gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        return downProj(silu(gateProj(x)) * upProj(x))
    }
}

// MARK: - Text Decoder Layer

class Qwen3ASRTextDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3ASRTextAttention
    @ModuleInfo(key: "mlp") var mlp: Qwen3ASRTextMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm

    init(_ config: Qwen3TextConfig, layerIdx: Int) {
        self._selfAttn.wrappedValue = Qwen3ASRTextAttention(config, layerIdx: layerIdx)
        self._mlp.wrappedValue = Qwen3ASRTextMLP(config)
        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        var residual = hiddenStates
        var h = inputLayernorm(hiddenStates)
        h = selfAttn(h, mask: mask, cache: cache)
        h = residual + h

        residual = h
        h = postAttentionLayernorm(h)
        h = mlp(h)
        h = residual + h

        return h
    }
}

// MARK: - Text Model

public class Qwen3ASRTextModel: Module {
    let config: Qwen3TextConfig

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [Qwen3ASRTextDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    public init(_ config: Qwen3TextConfig) {
        self.config = config

        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabSize,
            dimensions: config.hiddenSize
        )
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { i in
            Qwen3ASRTextDecoderLayer(config, layerIdx: i)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

    public func callAsFunction(
        inputIds: MLXArray? = nil,
        inputsEmbeds: MLXArray? = nil,
        cache: [KVCache]? = nil
    ) -> MLXArray {
        var h: MLXArray
        if let embeds = inputsEmbeds {
            h = embeds
        } else if let ids = inputIds {
            h = embedTokens(ids)
        } else {
            fatalError("Either inputIds or inputsEmbeds must be provided")
        }

        let mask = Self.attentionMask(h: h, cache: cache?.first)

        let caches = cache ?? [KVCache?](repeating: nil, count: layers.count)
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: caches[i])
        }

        return norm(h)
    }

    /// Multi-token steps over a quantized cache need an exact additive mask:
    /// the quantized attention path replaces boolean-mask positions with a
    /// finite constant, letting future positions leak into the softmax.
    static func attentionMask(
        h: MLXArray, cache: KVCache?
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let n = h.dim(1)
        if n > 1, let cache, cache is QuantizedKVCacheProtocol {
            let offset = cache.offset
            let boolMask = createCausalMask(n: n, offset: offset)
            let additive = MLX.where(
                boolMask, MLXArray(Float(0)), MLXArray(Float(-1e9))
            ).asType(h.dtype)
            return .array(additive)
        }
        return createAttentionMask(h: h, cache: cache)
    }
}
