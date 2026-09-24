// Whisper decoding-policy adaptation: Copyright © 2023 Apple Inc.
// MIT license; see LICENSE-mlx-whisper. Based on pinned mlx-audio 0.5.1.
import Foundation
import zlib
import MLX
import MLXNN
import MLXAudioCore

public final class WhisperModel: Module, STTGenerationModel {
    public let config: WhisperConfig
    public let generationConfig: WhisperGenerationConfig?

    @ModuleInfo(key: "model") var model: WhisperSubmodels

    private var tokenizer: WhisperTokenizer?

    public init(config: WhisperConfig, generationConfig: WhisperGenerationConfig? = nil) {
        self.config = config
        self.generationConfig = generationConfig
        self._model.wrappedValue = WhisperSubmodels(config: config)
    }

    public var defaultGenerationParameters: STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: config.maxTargetPositions - 16,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            verbose: false,
            language: nil,
            chunkDuration: Float(WhisperAudioConfig.chunkLengthSeconds),
            minChunkDuration: 0.1,
            repetitionPenalty: 1.0,
            repetitionContextSize: 32
        )
    }

    public func generate(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> STTOutput {
        let startTime = Date()
        let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio
        let chunks = chunkAudioFor30sWindows(mono)

        var allText: [String] = []
        var allSegments: [[String: Any]] = []
        var totalPromptTokens = 0
        var totalGenerationTokens = 0
        var detectedLanguage: String? = nil

        for (index, chunk) in chunks.enumerated() {
            if generationParameters.verbose {
                let endSeconds = chunk.offsetSeconds + Float(chunk.audio.dim(0)) / Float(WhisperAudioConfig.sampleRate)
                print("[Whisper] chunk \(index + 1)/\(chunks.count) \(String(format: "%.1f", chunk.offsetSeconds))s..\(String(format: "%.1f", endSeconds))s")
            }
            let (text, promptTokens, generationTokens, lang) = transcribeChunk(
                audio: chunk.audio,
                generationParameters: generationParameters
            )
            totalPromptTokens += promptTokens
            totalGenerationTokens += generationTokens
            if detectedLanguage == nil { detectedLanguage = lang }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allText.append(trimmed)
                let endSeconds = Double(chunk.offsetSeconds) + Double(chunk.audio.dim(0)) / Double(WhisperAudioConfig.sampleRate)
                allSegments.append([
                    "text": trimmed,
                    "start": Double(chunk.offsetSeconds),
                    "end": endSeconds,
                ])
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let combined = allText.joined(separator: " ")

        return STTOutput(
            text: combined,
            segments: allSegments.isEmpty ? nil : allSegments,
            language: detectedLanguage ?? generationParameters.language,
            promptTokens: totalPromptTokens,
            generationTokens: totalGenerationTokens,
            totalTokens: totalPromptTokens + totalGenerationTokens,
            promptTps: elapsed > 0 ? Double(totalPromptTokens) / elapsed : 0,
            generationTps: elapsed > 0 ? Double(totalGenerationTokens) / elapsed : 0,
            totalTime: elapsed,
            peakMemoryUsage: Double(Memory.peakMemory) / 1e9
        )
    }

    public func generateStream(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> AsyncThrowingStream<STTGeneration, Error> {
        AsyncThrowingStream { continuation in
            let startTime = Date()
            let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio
            let chunks = chunkAudioFor30sWindows(mono)

            var allText: [String] = []
            var allSegments: [[String: Any]] = []
            var totalPromptTokens = 0
            var totalGenerationTokens = 0
            var detectedLanguage: String? = nil

            for (index, chunk) in chunks.enumerated() {
                if generationParameters.verbose {
                    let endSeconds = chunk.offsetSeconds + Float(chunk.audio.dim(0)) / Float(WhisperAudioConfig.sampleRate)
                    print("[Whisper] chunk \(index + 1)/\(chunks.count) \(String(format: "%.1f", chunk.offsetSeconds))s..\(String(format: "%.1f", endSeconds))s")
                }

                let (text, promptTokens, generationTokens, lang) = transcribeChunk(
                    audio: chunk.audio,
                    generationParameters: generationParameters,
                    onTokenDelta: { delta in
                        if !delta.isEmpty {
                            continuation.yield(.token(delta))
                        }
                    }
                )
                totalPromptTokens += promptTokens
                totalGenerationTokens += generationTokens
                if detectedLanguage == nil { detectedLanguage = lang }

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    allText.append(trimmed)
                    let endSeconds = Double(chunk.offsetSeconds) + Double(chunk.audio.dim(0)) / Double(WhisperAudioConfig.sampleRate)
                    allSegments.append([
                        "text": trimmed,
                        "start": Double(chunk.offsetSeconds),
                        "end": endSeconds,
                    ])
                }
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let combined = allText.joined(separator: " ")

            let output = STTOutput(
                text: combined,
                segments: allSegments.isEmpty ? nil : allSegments,
                language: detectedLanguage ?? generationParameters.language,
                promptTokens: totalPromptTokens,
                generationTokens: totalGenerationTokens,
                totalTokens: totalPromptTokens + totalGenerationTokens,
                promptTps: elapsed > 0 ? Double(totalPromptTokens) / elapsed : 0,
                generationTps: elapsed > 0 ? Double(totalGenerationTokens) / elapsed : 0,
                totalTime: elapsed,
                peakMemoryUsage: Double(Memory.peakMemory) / 1e9
            )
            continuation.yield(.result(output))
            continuation.finish()
        }
    }

    // MARK: - Chunking

    private struct AudioChunk {
        let audio: MLXArray
        let offsetSeconds: Float
    }

    private func chunkAudioFor30sWindows(_ audio: MLXArray) -> [AudioChunk] {
        let sampleRate = WhisperAudioConfig.sampleRate
        let windowSamples = WhisperAudioConfig.chunkLengthSamples
        let totalSamples = audio.dim(0)
        if totalSamples <= windowSamples {
            return [AudioChunk(audio: audio, offsetSeconds: 0)]
        }

        var chunks: [AudioChunk] = []
        var start = 0
        while start < totalSamples {
            let end = min(start + windowSamples, totalSamples)
            let slice = audio[start..<end]
            chunks.append(AudioChunk(audio: slice, offsetSeconds: Float(start) / Float(sampleRate)))
            start = end
        }
        return chunks
    }

    // MARK: - Single-chunk transcription

    private func transcribeChunk(
        audio: MLXArray,
        generationParameters: STTGenerateParameters,
        onTokenDelta: ((String) -> Void)? = nil
    ) -> (text: String, promptTokens: Int, generationTokens: Int, language: String?) {
        guard let tokenizer else { fatalError("Whisper tokenizer not loaded") }
        // Python DecodingOptions.fp16 defaults to true, including quantized models.
        let features = WhisperAudio.encoderFeatures(audio: audio, nMels: config.numMelBins).asType(.float16)
        let encoderHidden = model.encoder(features)
        var language = generationParameters.language
        var detectionCaches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
        let sot = MLXArray([Int32(tokenizer.startOfTranscriptId)]).expandedDimensions(axis: 0)
        let detectionHidden = model.decoder(tokens: sot, startPosition: 0, encoderHidden: encoderHidden, caches: &detectionCaches)
        let detectionLogits = model.decoder.projectToVocab(detectionHidden[0, -1]).asType(.float32)
        eval(detectionLogits)
        let noSpeechProbability: Float = tokenizer.noSpeechId.map { softmax(detectionLogits)[$0].item(Float.self) } ?? 0
        if tokenizer.isMultilingual, tokenizer.resolveLanguage(language) == nil {
            var mask = [Float](repeating: -.infinity, count: detectionLogits.dim(0))
            for id in tokenizer.languageToId.values where id < mask.count { mask[id] = 0 }
            let languageID = (detectionLogits + MLXArray(mask)).argMax().item(Int.self)
            language = tokenizer.languageToId.first(where: { $0.value == languageID })?.key
        }
        detectionCaches.removeAll()
        let promptIds = tokenizer.buildPromptTokens(language: language, task: "transcribe", withoutTimestamps: false)
        let beginSuppress = generationConfig?.beginSuppressTokens ?? [220, tokenizer.endOfTextId]
        var suppress = generationConfig?.suppressTokens ?? []
        suppress += [tokenizer.transcribeId, tokenizer.translateId, tokenizer.prevSotId,
                     tokenizer.sotLMId, tokenizer.noSpeechId, tokenizer.startOfTranscriptId].compactMap { $0 }
        suppress = Array(Set(suppress)).sorted()
        // The reference worker filters out max_tokens: Whisper receives its
        // default sample_len = n_text_ctx / 2, not a 1024-token decode budget.
        let maxTokens = max(1, min(generationParameters.maxTokens, config.maxTargetPositions / 2))
        let temperatures: [Float] = generationParameters.temperature == 0 && onTokenDelta == nil
            ? [0, 0.2, 0.4, 0.6, 0.8, 1] : [generationParameters.temperature]
        var finalText = ""
        var finalCount = 0
        for temperature in temperatures {
            var caches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
            let prompt = MLXArray(promptIds.map(Int32.init)).expandedDimensions(axis: 0)
            var hidden = model.decoder(tokens: prompt, startPosition: 0, encoderHidden: encoderHidden, caches: &caches)
            var logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
            var generated: [Int] = []
            var previousText = ""
            var sumLogProbability: Float = 0
            for step in 0..<maxTokens {
                eval(logits)
                var filtered = logits
                if step == 0 { filtered = suppressLogits(filtered, ids: beginSuppress) }
                filtered = suppressLogits(filtered, ids: suppress)
                filtered = applyTimestampRules(filtered, generated: generated, tokenizer: tokenizer)
                let next = sample(filtered, temperature: temperature)
                sumLogProbability += (filtered[next] - filtered.logSumExp()).item(Float.self)
                if next == tokenizer.endOfTextId { break }
                generated.append(next)
                if let onTokenDelta {
                    let text = tokenizer.decode(tokens: generated)
                    if text != previousText {
                        onTokenDelta(text.hasPrefix(previousText) ? String(text.dropFirst(previousText.count)) : text)
                        previousText = text
                    }
                }
                let token = MLXArray([Int32(next)]).expandedDimensions(axis: 0)
                hidden = model.decoder(tokens: token, startPosition: promptIds.count + step, encoderHidden: encoderHidden, caches: &caches)
                logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
            }
            finalText = tokenizer.decode(tokens: generated)
            finalCount = generated.count
            let average = sumLogProbability / Float(generated.count + 1)
            if noSpeechProbability > 0.6 && average < -1 {
                finalText = ""; break
            }
            if average >= -1 && compressionRatio(finalText) <= 2.4 { break }
        }
        return (finalText, promptIds.count, finalCount, language)
    }

    private func applyTimestampRules(_ logits: MLXArray, generated: [Int], tokenizer: WhisperTokenizer) -> MLXArray {
        let begin = tokenizer.timestampBeginId
        let count = logits.dim(0)
        var mask = [Float](repeating: 0, count: count)
        mask[tokenizer.noTimestampsId] = -.infinity
        let lastIsTimestamp = generated.last.map { $0 >= begin } ?? false
        let penultimateIsTimestamp = generated.count < 2 || generated[generated.count - 2] >= begin
        if lastIsTimestamp {
            let range = penultimateIsTimestamp ? begin..<count : 0..<tokenizer.endOfTextId
            for id in range { mask[id] = -.infinity }
        }
        // Reproduce pinned mlx-audio 0.5.1 literally: this rule uses sequence
        // indices, not timestamp IDs, so its range is empty for <=224 tokens.
        if let index = generated.indices.last(where: { generated[$0] > begin }) {
            let end = index + ((index == 0 || penultimateIsTimestamp) ? 1 : 0)
            if end > begin { for id in begin..<min(end, count) { mask[id] = -.infinity } }
        }
        if generated.isEmpty {
            for id in 0..<begin { mask[id] = -.infinity }
            let lastAllowed = begin + Int((Double(config.maxSourcePositions) / 30).rounded())
            if lastAllowed + 1 < count { for id in (lastAllowed + 1)..<count { mask[id] = -.infinity } }
        }
        // Reference compares the original logits before adding this timestamp mask.
        let logProbabilities = logits - logits.logSumExp()
        let timestampMass = logProbabilities[begin...].logSumExp()
        let maxText = logProbabilities[..<begin].max()
        if (timestampMass .> maxText).item(Bool.self) {
            for id in 0..<begin { mask[id] = -.infinity }
        }
        return logits + MLXArray(mask)
    }

    private func compressionRatio(_ text: String) -> Double {
        let input = Array(text.utf8)
        if input.isEmpty { return 0 }
        var length = compressBound(uLong(input.count))
        var compressed = [UInt8](repeating: 0, count: Int(length))
        let status = input.withUnsafeBufferPointer { source in
            compressed.withUnsafeMutableBufferPointer { destination in
                compress2(destination.baseAddress, &length, source.baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        return status == Z_OK ? Double(input.count) / Double(length) : 0
    }

    private func sample(_ logits: MLXArray, temperature: Float) -> Int {
        let logits1D = logits.ndim > 1 ? logits.squeezed() : logits
        if temperature <= 0 {
            return logits1D.argMax(axis: -1).item(Int.self)
        }
        let scaled = (logits1D / temperature).expandedDimensions(axis: 0)
        return categorical(scaled).item(Int.self)
    }

    private func suppressLogits(_ logits: MLXArray, ids: [Int]) -> MLXArray {
        if ids.isEmpty { return logits }
        let length = logits.dim(-1)
        var mask = [Float](repeating: 0, count: length)
        for id in ids where id >= 0 && id < length {
            mask[id] = -.infinity
        }
        return logits + MLXArray(mask)
    }

    private func suppressFromIndex(_ logits: MLXArray, fromIndex: Int) -> MLXArray {
        let length = logits.dim(-1)
        if fromIndex >= length { return logits }
        var mask = [Float](repeating: 0, count: length)
        for i in fromIndex..<length { mask[i] = -1e9 }
        return logits + MLXArray(mask)
    }

    // MARK: - Loading

    /// Source layout for a Whisper safetensors checkpoint.
    enum WeightFormat {
        /// HuggingFace `transformers` layout (`openai/whisper-*`).
        case huggingFace
        /// OpenAI / mlx-whisper layout (`mlx-community/whisper-*`).
        case mlxWhisper
    }

    static func detectFormat(_ weights: [String: MLXArray]) -> WeightFormat {
        for key in weights.keys where key.contains(".blocks.") {
            return .mlxWhisper
        }
        return .huggingFace
    }

    static func sanitize(weights: [String: MLXArray], config: WhisperConfig) -> [String: MLXArray] {
        switch detectFormat(weights) {
        case .huggingFace: return sanitizeHuggingFace(weights)
        case .mlxWhisper: return sanitizeMlxWhisper(weights)
        }
    }

    private static func sanitizeHuggingFace(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, value) in weights {
            // proj_out is tied to embed_tokens; projectToVocab uses the embedding directly.
            if rawKey == "proj_out.weight" || rawKey == "model.proj_out.weight" {
                continue
            }

            var key = rawKey
            // Re-exports that drop the top-level `model.` still need it for module lookup.
            if !key.hasPrefix("model.") {
                if key.hasPrefix("encoder.") || key.hasPrefix("decoder.") {
                    key = "model." + key
                }
            }

            var newValue = value
            if (key == "model.encoder.conv1.weight" || key == "model.encoder.conv2.weight"), newValue.ndim == 3 {
                // PyTorch Conv1d: [out, in, kernel] -> MLX Conv1d: [out, kernel, in]
                newValue = newValue.transposed(0, 2, 1)
            }
            sanitized[key] = newValue
        }

        return sanitized
    }

    private static func sanitizeMlxWhisper(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, value) in weights {
            if rawKey == "alignment_heads" { continue }
            guard let mapped = remapMlxWhisperKey(rawKey) else { continue }
            sanitized[mapped] = value
        }

        // mlx-whisper omits the encoder positional embedding because it's a
        // fixed sinusoid; synthesise it so `update(parameters:verify:.all)` passes.
        let encPosKey = "model.encoder.embed_positions.weight"
        if sanitized[encPosKey] == nil, let conv2 = sanitized["model.encoder.conv2.weight"] {
            sanitized[encPosKey] = whisperSinusoids(length: 1500, channels: conv2.shape[0])
        }

        return sanitized
    }

    private static func whisperSinusoids(length: Int, channels: Int) -> MLXArray {
        precondition(channels % 2 == 0, "Whisper sinusoid channels must be even")
        let half = channels / 2
        let logTimescaleIncrement = log(10000.0) / Double(max(half - 1, 1))
        var values = [Float](repeating: 0, count: length * channels)
        for pos in 0..<length {
            for i in 0..<half {
                let scaledTime = Double(pos) * exp(-logTimescaleIncrement * Double(i))
                values[pos * channels + i] = Float(sin(scaledTime))
                values[pos * channels + half + i] = Float(cos(scaledTime))
            }
        }
        return MLXArray(values).reshaped([length, channels])
    }

    private static func remapMlxWhisperKey(_ rawKey: String) -> String? {
        if rawKey == "encoder.positional_embedding" {
            return "model.encoder.embed_positions.weight"
        }
        if rawKey == "decoder.positional_embedding" {
            return "model.decoder.embed_positions.weight"
        }
        if rawKey.hasPrefix("decoder.token_embedding.") {
            return "model.decoder.embed_tokens."
                + String(rawKey.dropFirst("decoder.token_embedding.".count))
        }
        if rawKey == "encoder.conv1.weight" || rawKey == "encoder.conv1.bias"
            || rawKey == "encoder.conv2.weight" || rawKey == "encoder.conv2.bias"
        {
            return "model." + rawKey
        }
        if rawKey.hasPrefix("encoder.ln_post.") {
            return "model.encoder.layer_norm." + String(rawKey.dropFirst("encoder.ln_post.".count))
        }
        if rawKey.hasPrefix("decoder.ln.") {
            return "model.decoder.layer_norm." + String(rawKey.dropFirst("decoder.ln.".count))
        }

        for stem in ["encoder", "decoder"] {
            let blocksPrefix = "\(stem).blocks."
            guard rawKey.hasPrefix(blocksPrefix) else { continue }
            let rest = rawKey.dropFirst(blocksPrefix.count)
            guard let dot = rest.firstIndex(of: ".") else { return nil }
            let layerIndex = String(rest[..<dot])
            let suffix = String(rest[rest.index(after: dot)...])
            guard let mapped = remapBlockSuffix(suffix, isDecoder: stem == "decoder") else { return nil }
            return "model.\(stem).layers.\(layerIndex).\(mapped)"
        }

        return nil
    }

    private static func remapBlockSuffix(_ suffix: String, isDecoder: Bool) -> String? {
        let attnNameMap: [String: String] = [
            "query": "q_proj", "key": "k_proj", "value": "v_proj", "out": "out_proj",
        ]

        if let rest = stripPrefix(suffix, "attn_ln.") {
            return "self_attn_layer_norm.\(rest)"
        }
        if isDecoder, let rest = stripPrefix(suffix, "cross_attn_ln.") {
            return "encoder_attn_layer_norm.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp_ln.") {
            return "final_layer_norm.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp1.") {
            return "fc1.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp2.") {
            return "fc2.\(rest)"
        }
        if let rest = stripPrefix(suffix, "attn.") {
            return remapAttnSuffix(rest, container: "self_attn", attnNameMap: attnNameMap)
        }
        if isDecoder, let rest = stripPrefix(suffix, "cross_attn.") {
            return remapAttnSuffix(rest, container: "encoder_attn", attnNameMap: attnNameMap)
        }
        return nil
    }

    private static func remapAttnSuffix(
        _ suffix: String,
        container: String,
        attnNameMap: [String: String]
    ) -> String? {
        guard let dot = suffix.firstIndex(of: ".") else { return nil }
        let projName = String(suffix[..<dot])
        let tail = String(suffix[suffix.index(after: dot)...])
        guard let mappedProj = attnNameMap[projName] else { return nil }
        return "\(container).\(mappedProj).\(tail)"
    }

    private static func stripPrefix(_ string: String, _ prefix: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }

    public static func fromDirectory(
        _ modelDirectory: URL
    ) async throws -> WhisperModel {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(WhisperConfig.self, from: configData)

        var generationConfig: WhisperGenerationConfig? = nil
        let generationConfigURL = modelDirectory.appendingPathComponent("generation_config.json")
        if FileManager.default.fileExists(atPath: generationConfigURL.path),
           let data = try? Data(contentsOf: generationConfigURL)
        {
            generationConfig = try? JSONDecoder().decode(WhisperGenerationConfig.self, from: data)
        }

        let model = WhisperModel(config: config, generationConfig: generationConfig)
        let files = try FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil
        )
        let safetensors = files
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !safetensors.isEmpty else {
            throw NSError(
                domain: "WhisperModel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No .safetensors files found in \(modelDirectory.path)."]
            )
        }

        var weights: [String: MLXArray] = [:]
        for url in safetensors {
            let shard = try MLX.loadArrays(url: url)
            weights.merge(shard) { _, new in new }
        }
        let sanitized = sanitize(weights: weights, config: config)
        if let quantization = try? JSONDecoder().decode(WhisperQuantizedModelConfig.self, from: configData).quantization {
            try installCheckpointQuantization(model: model, weights: sanitized) { path, module in
                guard module is Linear || path.hasSuffix("decoder.embed_tokens") else { return nil }
                return (quantization.groupSize, quantization.bits, .affine)
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)

        let tokenizerDir = modelDirectory
        model.tokenizer = try await WhisperTokenizer(
            modelDirectory: modelDirectory,
            baseConfig: config,
            generationConfig: generationConfig,
            tokenizerDirectory: tokenizerDir
        )

        eval(model)
        return model
    }




}

private struct WhisperQuantizedModelConfig: Decodable {
    let quantization: WhisperQuantizationConfig?
}

private struct WhisperQuantizationConfig: Decodable {
    let groupSize: Int
    let bits: Int

    private enum CodingKeys: String, CodingKey {
        case groupSize = "group_size"
        case bits
    }
}
