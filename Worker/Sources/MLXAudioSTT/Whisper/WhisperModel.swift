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

    // MARK: - Profiling (opt-in, VELLA_WHISPER_PROFILE=1; adds syncs at phase boundaries)

    public struct Profile {
        public var mel = 0.0, encoder = 0.0, detect = 0.0, prefill = 0.0, decode = 0.0
        public var decodeSteps = 0, attempts = 0
        public var activationDType = ""
        public init() {}
    }
    public static let profiling = ProcessInfo.processInfo.environment["VELLA_WHISPER_PROFILE"] == "1"
    /// Per-request sampling seed for temperature fallback. Lab-only override `VELLA_WHISPER_SEED` (decimal or 0x hex)
    /// measures the sampling noise floor of the quality gate (lab/notes/GATE-REVISION.md); the app never sets it.
    static let samplingSeed: UInt64 = {
        guard let raw = ProcessInfo.processInfo.environment["VELLA_WHISPER_SEED"] else { return 0x5eed }
        let hex = raw.lowercased().hasPrefix("0x")
        return UInt64(hex ? String(raw.dropFirst(2)) : raw, radix: hex ? 16 : 10) ?? 0x5eed
    }()
    public var profile = Profile()

    // MARK: - Optimized path state (FastPathCapable; off after load, the worker enables it once the gate qualified it)

    public private(set) var fastDecode = false
    /// The fused decode step (`WhisperFusedDecoder`), built once when the decoder component is first enabled; used
    /// only on a half-precision checkpoint (shipped FP16 models run FP16, stock included).
    private var fusedDecoder: WhisperFusedDecoder?
    private var fusedDecoderBuilt = false
    private var activeFusedDecoder: WhisperFusedDecoder? { fastDecode && checkpointHalfDType != nil ? fusedDecoder : nil }
    /// Every raw decoder-logit tensor consumed while an optimized component is active (language detection, the
    /// pipelined greedy loop, and every step-by-step attempt including the temperature retries) finite, over the
    /// whole last `generate` call. Raw logits only: the filtered ones carry intentional -inf masks.
    var lastDecoderFinite = true
    /// The optimized decoder is active: every attempt is finite-checked.
    var checksFinite: Bool { fastDecode }
    /// Test hook (reported in worker status, never inherited by the gate's self-test child), to prove the stock
    /// fallback: "<step>" makes the pipelined greedy loop's logits non-finite from that step on; "sampled:<step>"
    /// does the same in the optimized step-by-step loop on temperature > 0 attempts only (a retry after a finite
    /// greedy attempt); "loop:<step>" in the optimized step-by-step loop at any temperature.
    static let testDecoderFault = ProcessInfo.processInfo.environment["VELLA_TEST_DECODER_NONFINITE"] ?? ""
    static let testDecoderFaultStep: Int? = Int(testDecoderFault)
    static func testLoopFault(step: Int, temperature: Float) -> Bool {
        let parts = testDecoderFault.split(separator: ":")
        guard parts.count == 2, let from = Int(parts[1]), step >= from else { return false }
        return parts[0] == "loop" || (parts[0] == "sampled" && temperature > 0)
    }
    /// Token IDs of the last `generate` call: each chunk's final decode (end-of-text excluded), then -1.
    public private(set) var lastTokens: [Int] = []

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
        // Temperature fallback samples from MLX's global key, which is seeded from the clock: seed it per request so
        // the same audio always gives the same transcript (repeatable results and `vella diagnose` comparisons).
        MLXRandom.seed(WhisperModel.samplingSeed)
        let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio
        let chunks = chunkAudioFor30sWindows(mono)
        lastTokens = []
        lastDecoderFinite = true

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
        let profiling = WhisperModel.profiling
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        var mark = now()
        func lap(_ keyPath: WritableKeyPath<Profile, Double>) { let t = now(); profile[keyPath: keyPath] += t - mark; mark = t }
        // Python DecodingOptions.fp16 defaults to true, including quantized models.
        // This always rounds mel to FP16: arbitrary FP32 sources receive half-rounded input, and BF16 weights
        // can promote FP16 input to Float32. Only the shipped FP16 checkpoints are dtype-faithful end to end.
        let features = WhisperAudio.encoderFeatures(audio: audio, nMels: config.numMelBins).asType(.float16)
        if profiling { eval(features); lap(\.mel) }
        let encoderHidden = model.encoder(features)
        if profiling { eval(encoderHidden); lap(\.encoder); profile.activationDType = "\(encoderHidden.dtype)" }
        var language = generationParameters.language
        var detectionCaches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
        let sot = MLXArray([Int32(tokenizer.startOfTranscriptId)]).expandedDimensions(axis: 0)
        let detectionHidden = model.decoder(tokens: sot, startPosition: 0, encoderHidden: encoderHidden, caches: &detectionCaches)
        let detectionLogits = model.decoder.projectToVocab(detectionHidden[0, -1]).asType(.float32)
        eval(detectionLogits)
        if checksFinite { lastDecoderFinite = lastDecoderFinite && detectionLogits.sum().item(Float.self).isFinite }
        let noSpeechProbability: Float = tokenizer.noSpeechId.map { softmax(detectionLogits)[$0].item(Float.self) } ?? 0
        if tokenizer.isMultilingual, tokenizer.resolveLanguage(language) == nil {
            var mask = [Float](repeating: -.infinity, count: detectionLogits.dim(0))
            for id in tokenizer.languageToId.values where id < mask.count { mask[id] = 0 }
            let languageID = (detectionLogits + MLXArray(mask)).argMax().item(Int.self)
            language = tokenizer.languageToId.first(where: { $0.value == languageID })?.key
        }
        // The cross-attention K/V depend only on the encoder output: the optimized decoder reuses the detection
        // pass's projections (same GEMM, same values) instead of recomputing them for every decode attempt.
        let crossCaches = fastDecode ? detectionCaches : []
        detectionCaches.removeAll()
        if profiling { lap(\.detect) }
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
        var finalTokens: [Int] = []
        // The pipelined loop evaluates the timestamp rules on the GPU; the stock rule that indexes timestamp IDs by
        // sequence position is empty only while the sequence is shorter than the first timestamp ID (always, at 224).
        let fast = fastDecode && onTokenDelta == nil && maxTokens < tokenizer.timestampBeginId
        for temperature in temperatures {
            var caches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
            if fast {
                for index in caches.indices {
                    caches[index].crossKeys = crossCaches[index].crossKeys
                    caches[index].crossValues = crossCaches[index].crossValues
                }
            }
            let prompt = MLXArray(promptIds.map(Int32.init)).expandedDimensions(axis: 0)
            var hidden = model.decoder(tokens: prompt, startPosition: 0, encoderHidden: encoderHidden, caches: &caches)
            var logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
            var generated: [Int] = []
            var previousText = ""
            var sumLogProbability: Float = 0
            if profiling { eval(logits); lap(\.prefill) }
            if fast && temperature == 0 {
                (generated, sumLogProbability) = pipelinedGreedy(
                    logits: logits, caches: &caches, encoderHidden: encoderHidden, promptCount: promptIds.count,
                    maxTokens: maxTokens, beginSuppress: beginSuppress, suppress: suppress, tokenizer: tokenizer)
            } else {
            // Raw-logit sums of every consumed step, evaluated with the step's logits and read once per attempt.
            var sums: [MLXArray] = []
            for step in 0..<maxTokens {
                if checksFinite, WhisperModel.testLoopFault(step: step, temperature: temperature) {
                    FastPathGate.debug("whisper: injected non-finite logits, step \(step), temperature \(temperature)")
                    logits = logits * MLXArray(Float.nan)
                }
                if checksFinite {
                    let sum = logits.sum()
                    eval(logits, sum)
                    sums.append(sum)
                } else {
                    eval(logits)
                }
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
            if !sums.isEmpty {
                lastDecoderFinite = lastDecoderFinite && MLX.stacked(sums).asArray(Float.self).allSatisfy(\.isFinite)
            }
            }
            if profiling { lap(\.decode); profile.decodeSteps += generated.count + 1; profile.attempts += 1 }
            finalText = tokenizer.decode(tokens: generated)
            finalCount = generated.count
            finalTokens = generated
            let average = sumLogProbability / Float(generated.count + 1)
            if noSpeechProbability > 0.6 && average < -1 {
                finalText = ""; finalTokens = []; break
            }
            if average >= -1 && compressionRatio(finalText) <= 2.4 { break }
        }
        lastTokens += finalTokens + [-1]
        return (finalText, promptIds.count, finalCount, language)
    }

    // MARK: - Optimized greedy decode

    /// Constant 0/-inf masks for the GPU-side token rules (one per model; the suppress lists are per checkpoint).
    private struct RuleMasks {
        let key: [Int]
        let first: MLXArray      // step 0: begin-suppress + suppress + no-timestamps + the empty-sequence rule
        let later: MLXArray      // steps >= 1: suppress + no-timestamps
        let suppressFirst: MLXArray, suppressLater: MLXArray  // the suppress part alone (stock filters before the rules)
        let timestamps: MLXArray // [begin, vocab)
        let textToEot: MLXArray  // [0, eot)
        let text: MLXArray       // [0, begin)
    }
    private var ruleMasks: RuleMasks?

    private func masks(count: Int, beginSuppress: [Int], suppress: [Int], tokenizer: WhisperTokenizer) -> RuleMasks {
        let key = [count, -1] + beginSuppress + [-2] + suppress
        if let ruleMasks, ruleMasks.key == key { return ruleMasks }
        let begin = tokenizer.timestampBeginId
        func mask(_ ids: [Int], _ ranges: [Range<Int>] = []) -> [Float] {
            var values = [Float](repeating: 0, count: count)
            for id in ids where id >= 0 && id < count { values[id] = -.infinity }
            for range in ranges { for id in range.clamped(to: 0..<count) { values[id] = -.infinity } }
            return values
        }
        let lastAllowed = begin + Int((Double(config.maxSourcePositions) / 30).rounded())
        let emptyRules = [0..<begin] + (lastAllowed + 1 < count ? [(lastAllowed + 1)..<count] : [])
        let suppressFirst = mask(beginSuppress + suppress)
        let suppressLater = mask(suppress)
        let made = RuleMasks(
            key: key,
            first: MLXArray(mask([tokenizer.noTimestampsId], emptyRules)),
            later: MLXArray(mask([tokenizer.noTimestampsId])),
            suppressFirst: MLXArray(suppressFirst), suppressLater: MLXArray(suppressLater),
            timestamps: MLXArray(mask([], [begin..<count])),
            textToEot: MLXArray(mask([], [0..<tokenizer.endOfTextId])),
            text: MLXArray(mask([], [0..<begin])))
        ruleMasks = made
        return made
    }

    /// Greedy decode with the token rules on the GPU and step N+1 queued from the still-lazy token N before the
    /// host reads N (one wasted step after end-of-text). Same ops on the same values as the stock loop: the
    /// suppress masks, then the timestamp rules' mask (0/-inf entries, so one addition equals the stock sequence),
    /// argmax, and the per-step log-probability summed on the host in the same order. Token-exact with stock.
    private func pipelinedGreedy(
        logits first: MLXArray, caches: inout [WhisperLayerCache], encoderHidden: MLXArray, promptCount: Int,
        maxTokens: Int, beginSuppress: [Int], suppress: [Int], tokenizer: WhisperTokenizer
    ) -> ([Int], Float) {
        let begin = tokenizer.timestampBeginId
        let rules = masks(count: first.dim(0), beginSuppress: beginSuppress, suppress: suppress, tokenizer: tokenizer)
        let beginArray = MLXArray(Int32(begin))
        let zero = MLXArray(Float(0))
        let faultStep = WhisperModel.testDecoderFaultStep
        func select(_ step: Int, _ raw: MLXArray, _ previous: MLXArray?, _ beforePrevious: MLXArray?) -> (token: MLXArray, logProbability: MLXArray, sum: MLXArray) {
            var logits = raw
            if let faultStep, step >= faultStep { logits = logits * MLXArray(Float.nan) }
            let filtered = logits + (step == 0 ? rules.suppressFirst : rules.suppressLater)
            let logProbabilities = filtered - filtered.logSumExp()
            let timestampMass = logProbabilities[begin...].logSumExp()
            let maxText = logProbabilities[..<begin].max()
            var mask = (step == 0 ? rules.first : rules.later) + MLX.where(timestampMass .> maxText, rules.text, zero)
            if let previous {
                let lastIsTimestamp = previous .>= beginArray
                let penultimateIsTimestamp = beforePrevious.map { $0 .>= beginArray } ?? MLXArray(true)
                mask = mask + MLX.where(lastIsTimestamp .&& penultimateIsTimestamp, rules.timestamps, zero)
                    + MLX.where(lastIsTimestamp .&& .!penultimateIsTimestamp, rules.textToEot, zero)
            }
            let final = filtered + mask
            let token = final.argMax(axis: -1)
            let chosen = MLX.takeAlong(final, token.reshaped([1]), axis: 0)
            return (token, chosen - final.logSumExp(), logits.sum())
        }
        var current = select(0, first, nil, nil)
        asyncEval(current.token, current.logProbability, current.sum)
        var previous: MLXArray? = nil
        var generated: [Int] = []
        var logProbabilities: [MLXArray] = []
        var sums: [MLXArray] = []
        for step in 0..<maxTokens {
            var queued: (token: MLXArray, logProbability: MLXArray, sum: MLXArray)? = nil
            if step + 1 < maxTokens {
                let token = current.token.reshaped([1, 1])
                let hidden = activeFusedDecoder?.step(model.decoder, token: token, position: promptCount + step, caches: &caches)
                    ?? model.decoder(tokens: token, startPosition: promptCount + step, encoderHidden: encoderHidden, caches: &caches)
                let logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
                queued = select(step + 1, logits, current.token, previous)
                asyncEval(queued!.token, queued!.logProbability, queued!.sum)
            }
            let next = current.token.item(Int.self)
            logProbabilities.append(current.logProbability)
            sums.append(current.sum)
            if next == tokenizer.endOfTextId { break }
            generated.append(next)
            guard let queued else { break }
            previous = current.token
            current = queued
        }
        let values = MLX.concatenated(logProbabilities).asArray(Float.self)
        let finite = MLX.stacked(sums).asArray(Float.self).allSatisfy(\.isFinite)
        lastDecoderFinite = lastDecoderFinite && finite
        var sumLogProbability: Float = 0
        for value in values { sumLogProbability += value }
        return (generated, sumLogProbability)
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
        var sanitized: [String: MLXArray]
        switch detectFormat(weights) {
        case .huggingFace: sanitized = sanitizeHuggingFace(weights)
        case .mlxWhisper: sanitized = sanitizeMlxWhisper(weights)
        }
        // Both formats may supply an FP32 fixed table alongside FP16 convolutions. Preserve its values, rounded
        // once as old Fast rounded them per call; retaining FP32 would silently promote encoder and decoder.
        // Convolutions stay floating point in affine tiers, so packed Linear weights do not select this dtype.
        let key = "model.encoder.embed_positions.weight"
        if let conv = sanitized["model.encoder.conv1.weight"] ?? sanitized["model.encoder.conv2.weight"] {
            let dtype = positionTableDType(checkpoint: conv.dtype)
            if let supplied = sanitized[key] {
                sanitized[key] = supplied.asType(dtype)
            } else {
                sanitized[key] = whisperSinusoids(length: config.maxSourcePositions, channels: conv.shape[0], dtype: dtype)
            }
        }
        return sanitized
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

        return sanitized
    }

    /// Fixed table storage dtype from the floating convolution, else Float32; not an end-to-end BF16 guarantee.
    static func positionTableDType(checkpoint: DType) -> DType {
        checkpoint == .float16 || checkpoint == .bfloat16 ? checkpoint : .float32
    }

    /// Vella's Double-trig → Float32 sinusoids, rounded once to the selected table dtype.
    /// Dtype-faithful to mlx-whisper on shipped FP16 sources, not bit-identical: ~1.85% of entries differ by one
    /// FP16 ulp from its Float32-trig table. Keep these pre-existing values to preserve old Fast token identity.
    static func whisperSinusoids(length: Int, channels: Int, dtype: DType = .float32) -> MLXArray {
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
        let table = MLXArray(values).reshaped([length, channels])
        let target = positionTableDType(checkpoint: dtype)
        return target == .float32 ? table : table.asType(target)
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

    /// `derived`: a precision made at load (Vella) from this float checkpoint; `modelDirectory` is its source.
    public static func fromDirectory(
        _ modelDirectory: URL,
        derived: DerivedPrecision? = nil
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
        var sanitized = sanitize(weights: weights, config: config)
        weights.removeAll()
        var quantization = try? JSONDecoder().decode(WhisperQuantizedModelConfig.self, from: configData).quantization
        // A locally derived precision (Vella): quantize the float source tensor by tensor like mlx-whisper's published
        // quants (every Linear and the token embedding; the positional embeddings stay float), then load it the same way.
        if let derived {
            guard quantization == nil, let bits = derived.bits, let groupSize = derived.groupSize else {
                throw DerivedPrecision.Invalid.manifest("the source is already quantized")
            }
            derived.apply(to: &sanitized, targets: try derived.quantizationTargets(model, exclude: { $0.contains("embed_positions") }))
            quantization = WhisperQuantizationConfig(groupSize: groupSize, bits: bits)
        }
        if let quantization {
            try installCheckpointQuantization(model: model, weights: sanitized) { path, module in
                guard module is Linear || path.hasSuffix("decoder.embed_tokens") else { return nil }
                guard sanitized["\(path).scales"] != nil else { return nil }
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

// MARK: - Optimized path

extension WhisperModel: FastPathCapable {
    /// Bump whenever the optimized components or their parity reference change.
    /// whisper-4 (3 Oct 2026): stock runs FP16 on shipped checkpoints, dtype-faithful to mlx-whisper, so the old `encoder` component
    /// (the checkpoint-dtype model, `whisper-3-f16-model`) is gone; Fast and Exact are the same decoder components.
    public static var fastPathRevision: String { "whisper-4" }

    /// The checkpoint's floating dtype (FP16 for every published Whisper), nil when the encoder is Float32.
    var checkpointHalfDType: DType? {
        let dtype = model.encoder.conv1.weight.dtype
        return dtype == .float16 || dtype == .bfloat16 ? dtype : nil
    }

    /// decoder: the token rules on the GPU and a pipelined greedy loop (token-exact with the stock loop; stock read
    /// three scalars and rebuilt three vocabulary-sized masks on the host per token, leaving the GPU idle), plus the
    /// detection pass's cross-attention K/V reused for the prompt (identical values), and on quantized checkpoints the
    /// fused decode step (`fused_decode`, token-exact). Every component is exact: stock and optimized run the same
    /// encoder (FP16 on shipped checkpoints), and the self-test compares their tokens.
    public func configureFastPath(enabled: Bool, component: String) -> Bool {
        guard component == "both" || component == "decoder" else { return false }
        fastDecode = enabled; lastDecoderFinite = true
        if enabled && !fusedDecoderBuilt {
            fusedDecoderBuilt = true
            fusedDecoder = WhisperFusedDecoder(model.decoder)
        }
        return true
    }

    public var fastPathFinite: Bool { lastDecoderFinite }

    /// The transcript's words (special and timestamp tokens dropped), for the tolerance self-test's word edits.
    public func qualificationWords(_ tokens: [Int]) -> [String] {
        guard let tokenizer else { return tokens.map(String.init) }
        return tokenizer.decode(tokens: tokens.filter { $0 >= 0 && $0 < tokenizer.endOfTextId })
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var fastPathComponents: [String: Bool] {
        ["decoder": fastDecode, "fused_decode": activeFusedDecoder != nil]
    }

    /// Token IDs for a self-test clip, exactly as the worker transcribes (stock and optimized alike).
    public func qualificationTokens(audio: MLXArray) -> [Int] {
        // Temperature fallback samples from MLX's time-seeded global key: seed it so a clip that falls back
        // samples the same keys on both paths (the self-test child only).
        MLXRandom.seed(WhisperModel.samplingSeed)
        _ = generate(audio: audio, generationParameters: STTGenerateParameters(maxTokens: 1024, verbose: false, chunkDuration: 30))
        return Array(lastTokens.dropLast())
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
