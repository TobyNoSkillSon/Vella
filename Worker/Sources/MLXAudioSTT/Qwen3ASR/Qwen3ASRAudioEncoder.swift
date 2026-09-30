//
//  Qwen3ASRAudioEncoder.swift
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

// MARK: - Sinusoidal Position Embedding

class Qwen3ASRSinusoidalPE: Module {
    let _positionalEmbedding: MLXArray

    init(length: Int, channels: Int, maxTimescale: Float = 10000.0) {
        precondition(channels % 2 == 0, "SinusoidalPE channels must be even")

        let logTimescaleIncrement = log(maxTimescale) / Float(channels / 2 - 1)
        let invTimescales = MLX.exp(
            -logTimescaleIncrement * MLXArray(0..<(channels / 2)).asType(.float32)
        )
        let positions = MLXArray(0..<length).asType(.float32).reshaped(-1, 1)
        let scaledTime = positions * invTimescales.reshaped(1, -1)
        self._positionalEmbedding = MLX.concatenated(
            [MLX.sin(scaledTime), MLX.cos(scaledTime)], axis: 1
        )
        super.init()
    }

    func callAsFunction(_ seqLen: Int) -> MLXArray {
        return _positionalEmbedding[0..<seqLen]
    }
}

// MARK: - Audio Encoder Attention

class Qwen3ASRAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scaling: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ config: Qwen3AudioEncoderConfig) {
        self.embedDim = config.dModel
        self.numHeads = config.encoderAttentionHeads
        self.headDim = embedDim / numHeads
        self.scaling = pow(Float(headDim), -0.5)

        precondition(headDim * numHeads == embedDim,
            "embed_dim must be divisible by num_heads")

        self._qProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._kProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._vProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._outProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
    }

    func callAsFunction(_ hiddenStates: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        let B = hiddenStates.dim(0)
        let L = hiddenStates.dim(1)

        var queries = qProj(hiddenStates)
        var keys = kProj(hiddenStates)
        var values = vProj(hiddenStates)

        queries = queries.reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)
        keys = keys.reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)

        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = mask != nil ? .array(mask!) : .none
        let attnOutput = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scaling,
            mask: maskMode
        )

        let output = attnOutput.transposed(0, 2, 1, 3).reshaped(B, L, embedDim)
        return outProj(output)
    }
}

// MARK: - Audio Encoder Layer

class Qwen3ASRAudioEncoderLayer: Module {
    let embedDim: Int

    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3ASRAttention
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    init(_ config: Qwen3AudioEncoderConfig) {
        self.embedDim = config.dModel

        self._selfAttn.wrappedValue = Qwen3ASRAttention(config)
        self._selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: embedDim)
        self._fc1.wrappedValue = Linear(embedDim, config.encoderFfnDim)
        self._fc2.wrappedValue = Linear(config.encoderFfnDim, embedDim)
        self._finalLayerNorm.wrappedValue = LayerNorm(dimensions: embedDim)
    }

    func callAsFunction(_ hiddenStates: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        // Pre-norm attention
        var residual = hiddenStates
        var h = selfAttnLayerNorm(hiddenStates)
        h = selfAttn(h, mask: mask)
        h = residual + h

        // Pre-norm FFN
        residual = h
        h = finalLayerNorm(h)
        h = gelu(fc1(h))
        h = fc2(h)
        h = residual + h

        return h
    }
}

// MARK: - Audio Encoder

public class Qwen3ASRAudioEncoder: Module {
    let config: Qwen3AudioEncoderConfig
    let nWindow: Int
    let nWindowInfer: Int

    @ModuleInfo(key: "conv2d1") var conv2d1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2d2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [Qwen3ASRAudioEncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear

    let positionalEmbedding: Qwen3ASRSinusoidalPE
    /// Conv output lengths computed on the host instead of one device round trip per chunk (optimized encoder).
    var hostLengths = false

    public init(_ config: Qwen3AudioEncoderConfig) {
        self.config = config
        let embedDim = config.dModel
        self.nWindow = config.nWindow
        self.nWindowInfer = config.nWindowInfer

        // Conv2d frontend: input is [batch, mel_bins, time, 1]
        self._conv2d1.wrappedValue = Conv2d(
            inputChannels: 1,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        self._conv2d2.wrappedValue = Conv2d(
            inputChannels: config.downsampleHiddenSize,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        self._conv2d3.wrappedValue = Conv2d(
            inputChannels: config.downsampleHiddenSize,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )

        // Frequency dimension after 3 conv layers with stride 2
        let freqAfterConv = ((((config.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        self._convOut.wrappedValue = Linear(
            config.downsampleHiddenSize * freqAfterConv, embedDim, bias: false
        )

        self.positionalEmbedding = Qwen3ASRSinusoidalPE(
            length: config.maxSourcePositions, channels: embedDim
        )

        self._layers.wrappedValue = (0..<config.encoderLayers).map { _ in
            Qwen3ASRAudioEncoderLayer(config)
        }
        self._lnPost.wrappedValue = LayerNorm(dimensions: embedDim)
        self._proj1.wrappedValue = Linear(embedDim, embedDim)
        self._proj2.wrappedValue = Linear(embedDim, config.outputDim)
    }

    public func callAsFunction(
        _ inputFeatures: MLXArray,
        featureAttentionMask: MLXArray? = nil
    ) -> MLXArray {
        // inputFeatures shape: [batch, n_mels, n_frames]
        let batchSize = inputFeatures.dim(0)
        let nFrames = inputFeatures.dim(2)

        // Determine feature lengths
        let featureLens: [Int]
        if let mask = featureAttentionMask {
            let lens = mask.sum(axis: -1).asType(.int32)
            featureLens = (0..<batchSize).map { Int(lens[$0].item(Int32.self)) }
        } else {
            featureLens = [Int](repeating: nFrames, count: batchSize)
        }

        let chunkSize = nWindow * 2

        // Split features into chunks
        var chunkLengths: [Int] = []
        var chunks: [MLXArray] = []
        var chunkCountsPerInput: [Int] = []

        for i in 0..<batchSize {
            let featLen = featureLens[i]
            let numChunks = Int(ceil(Double(featLen) / Double(chunkSize)))
            let feat = inputFeatures[i]  // [n_mels, n_frames]
            chunkCountsPerInput.append(numChunks)

            var pos = 0
            for j in 0..<numChunks {
                let clen: Int
                if j == numChunks - 1 {
                    let remainder = featLen % chunkSize
                    clen = remainder == 0 ? chunkSize : remainder
                } else {
                    clen = chunkSize
                }
                let chunk = feat[0..., pos..<(pos + clen)]  // [n_mels, clen]
                chunks.append(chunk)
                chunkLengths.append(clen)
                pos += clen
            }
        }

        let maxChunkLen = chunkLengths.max() ?? 0

        // Pad chunks to max length
        var paddedChunks: [MLXArray] = []
        for (idx, chunk) in chunks.enumerated() {
            let clen = chunkLengths[idx]
            if clen < maxChunkLen {
                let padWidth = maxChunkLen - clen
                let padded = MLX.padded(chunk, widths: [IntOrPair((0, 0)), IntOrPair((0, padWidth))])
                paddedChunks.append(padded)
            } else {
                paddedChunks.append(chunk)
            }
        }

        // Compute output lengths after CNN for each chunk
        let featureLensAfterCnnValues: [Int]
        if hostLengths {
            featureLensAfterCnnValues = chunkLengths.map(featExtractOutputLength)
        } else {
            let chunkLensArray = MLXArray(chunkLengths.map { Int32($0) })
            let featureLensAfterCnn = getFeatExtractOutputLengths(chunkLensArray)
            featureLensAfterCnnValues = (0..<chunkLengths.count).map {
                Int(featureLensAfterCnn[$0].item(Int32.self))
            }
        }

        // Process Conv2d layers in batches
        let convBatchSize = 128
        var hiddenList: [MLXArray] = []
        var chunkIdx = 0

        for batchStart in stride(from: 0, to: paddedChunks.count, by: convBatchSize) {
            let batchEnd = min(batchStart + convBatchSize, paddedChunks.count)
            let batchSlice = Array(paddedChunks[batchStart..<batchEnd])
            let batchLen = batchSlice.count

            // Stack batch and apply Conv2d: [batchLen, n_mels, maxChunkLen, 1]
            var x = MLX.stacked(batchSlice, axis: 0).expandedDimensions(axis: -1)
            x = gelu(conv2d1(x))
            x = gelu(conv2d2(x))
            x = gelu(conv2d3(x))

            // Reshape: [batchLen, f, t, c] -> [batchLen, t, c*f]
            let f = x.dim(1)
            let t = x.dim(2)
            let c = x.dim(3)
            x = x.transposed(0, 2, 3, 1).reshaped(batchLen, t, c * f)
            x = convOut(x)  // [batchLen, t, d_model]

            // Add positional embeddings
            let posEmb = positionalEmbedding(x.dim(1))
            x = x + posEmb.expandedDimensions(axis: 0)

            let convStart = ProcessInfo.processInfo.systemUptime
            eval(x)
            if Qwen3ASRModel.profiling { Qwen3ASRModel.encoderClock.conv += ProcessInfo.processInfo.systemUptime - convStart }

            // Extract valid-length hidden states
            for i in 0..<batchLen {
                let validLen = featureLensAfterCnnValues[chunkIdx]
                hiddenList.append(x[i, 0..<validLen])
                chunkIdx += 1
            }
        }

        var hiddenStates = MLX.concatenated(hiddenList, axis: 0)  // [totalValidLen, d_model]

        // Process transformer layers per-window instead of building dense O(seqLen²) mask.
        // Derive window lengths from the actual per-conv output lengths so the final
        // window plan always matches the hidden state sequence we just constructed.
        let chunksPerWindow = max(1, nWindowInfer / chunkSize)
        let windowLengths = computeChunkedEncoderWindowLengths(
            chunkFeatureLengthsAfterCnn: featureLensAfterCnnValues,
            chunkCountsPerInput: chunkCountsPerInput,
            chunksPerWindow: chunksPerWindow
        )

        // Extract windows and group by length for batched processing
        let seqLen = hiddenStates.dim(0)
        var windowsByLen: [Int: [(index: Int, data: MLXArray)]] = [:]
        var windowOffset = 0
        var windowIndex = 0
        for winLen in windowLengths {
            let end = min(windowOffset + winLen, seqLen)
            guard windowOffset < end else { continue }
            let window = hiddenStates[windowOffset..<end]
            let actualLen = end - windowOffset
            windowsByLen[actualLen, default: []].append((index: windowIndex, data: window))
            windowOffset = end
            windowIndex += 1
        }
        if windowOffset < seqLen {
            let window = hiddenStates[windowOffset..<seqLen]
            windowsByLen[seqLen - windowOffset, default: []].append((index: windowIndex, data: window))
        }

        // Process each size-group through all transformer layers
        let encoderBatchSize = 256
        var processedWindows: [(index: Int, data: MLXArray)] = []

        for (_, group) in windowsByLen {
            for bStart in stride(from: 0, to: group.count, by: encoderBatchSize) {
                let bEnd = min(bStart + encoderBatchSize, group.count)
                let batchItems = Array(group[bStart..<bEnd])

                // [batchLen, windowLen, d_model] — full self-attention within each window
                var batch = MLX.stacked(batchItems.map { $0.data }, axis: 0)
                for layer in layers {
                    batch = layer(batch, mask: nil)
                }
                let layerStart = ProcessInfo.processInfo.systemUptime
                eval(batch)
                if Qwen3ASRModel.profiling { Qwen3ASRModel.encoderClock.layers += ProcessInfo.processInfo.systemUptime - layerStart }

                for (j, item) in batchItems.enumerated() {
                    processedWindows.append((index: item.index, data: batch[j]))
                }
            }
        }

        // Reconstruct in original order
        processedWindows.sort { $0.index < $1.index }
        hiddenStates = MLX.concatenated(processedWindows.map { $0.data }, axis: 0)

        // Post-processing
        hiddenStates = lnPost(hiddenStates)
        hiddenStates = gelu(proj1(hiddenStates))
        hiddenStates = proj2(hiddenStates)

        return hiddenStates  // [seqLen, outputDim]
    }
}
