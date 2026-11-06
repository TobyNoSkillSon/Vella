// SPDX-License-Identifier: MIT
// Nemotron 3.5 Transcribe 30B-A4B: speech and speaker experts feeding a Nemotron-H decoder. Ported from mlx-audio
// @92decb7 (MIT, mlx_audio/stt/models/nemotron_transcribe) and the MTP self-speculation of the research runner
// (Assistant/Research/2026-10-28-nemotron-transcribe/code/mtp.py, generate_chain).
import Foundation
import MLX
import MLXNN
import Tokenizers

public final class NemotronTranscribeModel: Module, STTGenerationModel {
    @ModuleInfo(key: "llm") var llm: NTLanguageModel
    @ModuleInfo(key: "perception") var perception: NTPerception

    let decoderConfig: NTDecoderConfig
    let eos: Set<Int>
    let padToken: Int
    var tokenizer: (any Tokenizer)?
    var audioToken = 131072
    /// Loaded from extras/mtp.safetensors (MLX tiers); nil runs plain greedy decoding.
    var mtp: NTMTP?
    /// Drafts per pass of the MTP chain (the research runner's measured setting; `VELLA_NEMOTRON_TRANSCRIBE_DRAFTS`
    /// overrides it for lab A/B, 2–8).
    var draftDepth = ProcessInfo.processInfo.environment["VELLA_NEMOTRON_TRANSCRIBE_DRAFTS"].flatMap(Int.init)
        .map { Swift.min(8, Swift.max(2, $0)) } ?? 4
    /// The user's vocabulary words (plain list only), applied to the next request.
    public var vocabularyWords: [String] = []
    /// Token IDs of the last chunk, for parity checks.
    public private(set) var lastTokens: [Int] = []
    /// Whether the last request dropped a trailing vocabulary sentence, and how many chunks it had.
    public private(set) var lastGuardDropped: [String] = []
    public private(set) var lastChunkCount = 0
    /// MTP drafts are verified by the main model, but batched verification changes near-tie choices (1–2 words of
    /// a 60 s clip with a list), so it is an inexact lever: Optimized · Exact and stock MLX decode plain greedy.
    public var usesMTP: Bool { mtp != nil && Self.mtpAllowed && mtpRuntimeFailure == nil }
    /// Draft-and-verify failed at run time (an MLX error or non-finite logits in a verify pass): that chunk was decoded
    /// again plain greedy, and the model stays on plain greedy until it is reloaded (sticky, like the other models'
    /// runtime fallback to stock). Nil while draft-and-verify is healthy.
    public private(set) var mtpRuntimeFailure: String?
    /// Set when the last request fell back (the worker pushes a "fallback" status once).
    public private(set) var lastRequestFellBack = false
    /// Chunks whose draft-and-verify output hit the token limit and were decoded again plain greedy (since load).
    public private(set) var runawayRetries = 0
    static var mtpAllowed: Bool {
        ProcessInfo.processInfo.environment["VELLA_NEMOTRON_TRANSCRIBE_MTP"] != "0" && !FastPathGate.exactOnly && !FastPathGate.forcedStock
    }
    /// Why the model runs as stock MLX, for the helper's status; nil when it runs as designed: draft-and-verify,
    /// or Optimized · Exact, whose recipe is plain decoding (reported as optimized with `mtp` off, like other models'
    /// inexact components under Exact).
    public var plainDecodingReason: String? {
        if usesMTP { return nil }
        if let mtpRuntimeFailure { return "Runtime fallback: draft-and-verify failed (\(mtpRuntimeFailure)); plain decoding." }
        if mtp == nil { return "This checkpoint has no draft head; plain decoding." }
        if FastPathGate.forcedStock { return FastPathGate.forcedStockReason }
        if FastPathGate.exactOnly { return nil }
        return "Draft-and-verify decoding is off (VELLA_NEMOTRON_TRANSCRIBE_MTP=0)."
    }
    /// The last request's error (a chunk that threw); the worker turns it into a failed request, never silence.
    public private(set) var lastError: Error?

    init(decoder: NTDecoderConfig, perception: NTPerceptionConfig, eos: Set<Int>, pad: Int) {
        decoderConfig = decoder; self.eos = eos; padToken = pad
        _llm.wrappedValue = NTLanguageModel(decoder)
        _perception.wrappedValue = NTPerception(perception)
        super.init()
    }

    public var defaultGenerationParameters: STTGenerateParameters { STTGenerateParameters(maxTokens: 1024, temperature: 0) }

    // MARK: Loading

    /// NVIDIA's BF16 checkpoint (one model.safetensors in NeMo keys, mapped here; its CTC head is not loaded), or an
    /// int8/int4 precision derived from it at load (`derived`: Vella's manifest-only directory, the recipe in
    /// `NemotronTranscribeRecipe`). An MLX-layout folder (sharded, per-module "quantization" in config.json,
    /// extras/mtp.safetensors) also loads, for lab exports.
    public static func fromModelDirectory(_ directory: URL, derived: DerivedPrecision? = nil) async throws -> NemotronTranscribeModel {
        let source = derived?.source ?? directory
        let model = try skeleton(source)
        let tokenizer = try await AutoTokenizer.from(modelFolder: source)
        let ids = tokenizer.encode(text: NemotronTranscribePrompt.audioTag, addSpecialTokens: false)
        guard ids.count == 1 else { throw NemotronTranscribeError.tokenizer("<|audio|> is not one token") }
        model.tokenizer = tokenizer
        model.audioToken = ids[0]
        try model.loadWeights(source, derived: derived)
        model.warmUp()
        return model
    }

    /// The module tree for a checkpoint's config.json; every parameter is a lazy placeholder until `loadWeights`.
    static func skeleton(_ directory: URL) throws -> NemotronTranscribeModel {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any] ?? [:]
        guard let llmJSON = root["llm_config"] as? [String: Any] else { throw NemotronTranscribeError.config("llm_config") }
        guard (root["prompt_format"] as? String ?? "nemotron3p5") == "nemotron3p5" else { throw NemotronTranscribeError.config("prompt_format") }
        let decoder = try NTDecoderConfig(json: llmJSON)
        let perception = try NTPerceptionConfig(root: root)
        let eosIDs = (root["eos_token_id"] as? [Int]) ?? [(root["eos_token_id"] as? Int) ?? 11]
        let model = NemotronTranscribeModel(decoder: decoder, perception: perception, eos: Set(eosIDs), pad: root["pad_token_id"] as? Int ?? 0)
        model.checkpointQuantization = NTQuantizationEntries(value: root["quantization"] as? [String: Any])
        return model
    }

    /// The folder's own per-module quantization (MLX layout), wrapped so module reflection skips it.
    private var checkpointQuantization = NTQuantizationEntries(value: nil)

    /// The checkpoint's tensors, lazily (MLX reads each from the file when it is evaluated).
    static func checkpointTensors(_ directory: URL) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw NemotronTranscribeError.weights("no safetensors") }
        var weights: [String: MLXArray] = [:]
        for file in files { weights.merge(try MLX.loadArrays(url: file)) { _, new in new } }
        return weights
    }

    /// Installs the weights of `directory`, quantizing them first when `derived` asks for it.
    func loadWeights(_ directory: URL, derived: DerivedPrecision?) throws {
        var weights = try Self.checkpointTensors(directory)
        let nvidia = weights.keys.contains { $0.hasPrefix("llm.model.") }
        guard derived == nil || nvidia else {
            // Vella's rule: a precision is derived from the 16-bit download only, never from a quantized folder.
            throw DerivedPrecision.Invalid.manifest("the source is not NVIDIA's BF16 checkpoint")
        }
        var mtpTensors: [String: MLXArray] = [:]
        if nvidia {
            mtpTensors = Self.mtpWeights(weights)
            weights = Self.sanitize(weights)
        }
        var config = checkpointQuantization.value
        if let derived {
            // The recipe (and its golden test) is group 64; the expert width 1856 does not divide by 128.
            guard let bits = derived.bits, let group = derived.groupSize, group == 64, derived.dtype == nil, derived.floatModules.isEmpty else {
                throw DerivedPrecision.Invalid.manifest("Nemotron Transcribe derives int8 or int4 at group 64 only")
            }
            let plan = NemotronTranscribeRecipe.decoderPlan(self, precisionBits: bits)
            config = NemotronTranscribeRecipe.quantize(&weights, plan: plan, groupSize: group)
        }
        try Self.installQuantization(self, weights: weights, config: config)
        try update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        weights.removeAll()
        eval(self)
        Memory.clearCache()

        let head = NTMTP(decoderConfig)
        let mtpURL = directory.appendingPathComponent("extras/mtp.safetensors")
        if nvidia, mtpTensors.count == NTMTP.nvidiaKeys.count {
            // The checkpoint's own head: as shipped for BF16; for a derived precision, routed experts 4-bit, the rest
            // 8-bit (drafts are verified by the main model, so the head's precision changes speed, never the text).
            var headConfig: [String: Any]?
            if let group = derived?.groupSize {
                headConfig = NemotronTranscribeRecipe.quantize(&mtpTensors, plan: NemotronTranscribeRecipe.mtpPlan(head), groupSize: group)
            }
            try Self.installQuantization(head, weights: mtpTensors, config: headConfig)
            try head.update(parameters: ModuleParameters.unflattened(mtpTensors), verify: .all)
        } else if !nvidia, FileManager.default.fileExists(atPath: mtpURL.path) {
            let (tensors, metadata) = try MLX.loadArraysAndMetadata(url: mtpURL)
            let quantization = metadata["quantization"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            try Self.installQuantization(head, weights: tensors, config: quantization)
            try head.update(parameters: ModuleParameters.unflattened(tensors), verify: .all)
        } else {
            return
        }
        eval(head)
        mtp = head
        Memory.clearCache()
    }

    /// The first request after a load paid ~11 s of one-time kernel preparation (25 s clip: 12.2 s cold, 0.75 s
    /// warm). Two seconds of faint noise through the encoders and a few decoded tokens move that into the load.
    func warmUp() {
        let noise = MLXRandom.normal([2 * NemotronTranscribeChunking.sampleRate], key: MLXRandom.key(0)) * 1e-3
        let audio = perception(noise)
        if let embeddings = try? inputs(tokens: promptTokens(words: []), audio: audio) {
            _ = decode(embeddings, maxTokens: 8)
        }
        lastTokens = []
        Memory.clearCache()
    }

    /// The MTP head's tensors from NVIDIA's checkpoint in NTMTP layout (research mtp.py `mtp_weights`).
    static func mtpWeights(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        for (source, target) in NTMTP.nvidiaKeys {
            guard var value = weights[source] else { continue }
            if source.hasSuffix("_projs") { value = value.transposed(0, 2, 1) }
            if source.hasSuffix("gate.weight") { value = value.asType(.float32) }
            out[target] = value
        }
        return out
    }

    /// NVIDIA's NeMo keys → this module tree (mlx-audio `Model.sanitize`).
    static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        for (original, tensor) in weights {
            guard let (key, transform) = NemotronTranscribeKeys.map(original, shape: tensor.shape) else { continue }
            var value = tensor
            if transform.transpose { value = value.transposed(0, 2, 1) }
            if transform.float32 { value = value.asType(.float32) }
            out[key] = value
        }
        return out
    }

    /// Replace every layer whose checkpoint carries scales by its quantized form (bits and group per module from
    /// the "quantization" entries, else the default). Nothing is quantized here: the codes come from the checkpoint.
    static func installQuantization(_ model: Module, weights: [String: MLXArray], config: [String: Any]?) throws {
        let defaultGroup = config?["group_size"] as? Int ?? 64, defaultBits = config?["bits"] as? Int ?? 4
        var updates: [(String, Module)] = []
        for (path, module) in model.leafModules().flattened() {
            guard let weight = weights[path + ".weight"], let scales = weights[path + ".scales"] else { continue }
            let entry = config?[path] as? [String: Any]
            let group = entry?["group_size"] as? Int ?? defaultGroup, bits = entry?["bits"] as? Int ?? defaultBits
            let biases = weights[path + ".biases"]
            let replacement: Module
            switch module {
            case is NTSwitchLinear:
                replacement = NTQuantizedSwitchLinear(weight: weight, scales: scales, biases: biases, groupSize: group, bits: bits)
            case is Linear:
                replacement = QuantizedLinear(weight: weight, bias: weights[path + ".bias"], scales: scales, biases: biases,
                                              groupSize: group, bits: bits, mode: .affine)
                replacement.freeze()
            default: throw NemotronTranscribeError.weights("quantized \(path) is not a linear layer")
            }
            updates.append((path, replacement))
        }
        model.update(modules: ModuleChildren.unflattened(updates))
    }

    // MARK: Inputs

    func promptTokens(words: [String]) throws -> [Int] {
        guard let tokenizer else { throw NemotronTranscribeError.tokenizer("not loaded") }
        return NemotronTranscribePrompt.turns(words: words).flatMap { tokenizer.encode(text: $0, addSpecialTokens: false) }
    }

    /// Prompt embeddings with the audio placeholder replaced by the audio embeddings: (tokens, 1 × N × D).
    func inputs(tokens ids: [Int], audio: MLXArray) throws -> MLXArray {
        let positions = ids.indices.filter { ids[$0] == audioToken }
        guard positions.count == 1, let index = positions.first else { throw NemotronTranscribeError.input("one audio placeholder expected") }
        let embedded = llm.backbone.embeddings(MLXArray(ids.map { Int32($0 == audioToken ? padToken : $0) }).reshaped(1, -1))
        return concatenated([embedded[0..., ..<index], audio.asType(embedded.dtype), embedded[0..., (index + 1)...]], axis: 1)
    }

    // MARK: Decoding

    private func head(_ h: MLXArray) -> MLXArray { argMax(llm.lmHead(h), axis: -1) }

    /// Greedy, as mlx-lm's generate_step: 512-token prefill blocks, the last prompt position alone, one step ahead.
    func decodeGreedy(_ embeddings: MLXArray, maxTokens: Int) -> [Int] {
        let cache = llm.backbone.makeCache()
        let total = embeddings.dim(1)
        var processed = 0
        while total - processed > 1 {
            let count = min(512, total - processed - 1)
            let h = llm.backbone(embeddings[0..., processed ..< (processed + count)], cache: cache)
            eval(h)
            processed += count
        }
        func step(_ x: MLXArray) -> MLXArray { head(llm.backbone(x, cache: cache)[0..., -1]) }
        var y = step(embeddings[0..., processed...])
        asyncEval(y)
        var out: [Int] = []
        while out.count < maxTokens {
            let next = step(llm.backbone.embeddings(y.reshaped(1, 1)))
            asyncEval(next)
            let token = y.item(Int.self)
            if eos.contains(token) { break }
            out.append(token)
            y = next
        }
        return out
    }

    /// Greedy self-speculation: `draftDepth` chained MTP drafts verified by the main model in one pass, one host
    /// sync per pass. Rejected drafts never stay in a cache (Mamba states restored, attention caches trimmed).
    func decodeMTP(_ embeddings: MLXArray, maxTokens: Int, mtp: NTMTP) throws -> [Int] {
        let fault = Self.injectedFault
        let embed = llm.backbone.embeddings
        let cache = llm.backbone.makeCache()
        let mcache = NTKVCache()
        let depth = draftDepth
        let total = embeddings.dim(1)
        var hs: [MLXArray] = []
        var post = embeddings
        var s = 0
        while s < total {
            post = llm.backbone(embeddings[0..., s ..< min(total, s + 2048)], cache: cache)
            eval(post)
            hs.append(post)
            s += 2048
        }
        let t = head(post[0..., (-1)...]).reshaped(-1).item(Int.self)
        var out: [Int] = []
        if eos.contains(t) || maxTokens == 0 { return out }
        out.append(t)

        func chain(_ x0: MLXArray, _ first: MLXArray) -> MLXArray {
            var drafts = [first], token = first, x = x0
            for _ in 0 ..< (depth - 1) {
                let (nx, xo) = mtp(embed(token.reshaped(1, 1)), x, cache: mcache)
                x = nx
                token = head(xo[0..., (-1)...]).reshaped(-1)
                drafts.append(token)
            }
            return concatenated(drafts)
        }

        let next = concatenated([embeddings[0..., 1...], embed(MLXArray([Int32(t)]).reshaped(1, 1))], axis: 1)
        var offset = 0
        var x = embeddings, xo = embeddings
        for h in hs {
            let l = h.dim(1)
            (x, xo) = mtp(next[0..., offset ..< (offset + l)], h, cache: mcache)
            offset += l
        }
        var drafts = chain(x[0..., (-1)...], head(xo[0..., (-1)...]).reshaped(-1))
        var pending = [t]
        var mtpDone = 0
        while out.count < maxTokens {
            let snapshot: [(MLXArray?, MLXArray?)?] = cache.map {
                if case .mamba(let m)? = $0 { return (m.conv, m.state) }
                return nil
            }
            let feed = concatenated([MLXArray(pending.map { Int32($0) }), drafts.asType(.int32)])
            let verified = llm.backbone(embed(feed.reshaped(1, -1)), cache: cache)
            let logits = llm.lmHead(verified)
            let ysArray = argMax(logits, axis: -1)[0]
            // One flag per verify pass, read in the same sync as the tokens: a NaN/Inf logit means the draft path
            // (or the model under it) produced garbage, and greedy argmax over it would be a wrong transcript.
            let bad = logicalOr(isNaN(logits).any(), isInf(logits).any())
            eval(ysArray, drafts, verified, bad)
            if fault == "throw" { throw NemotronTranscribeError.input("injected draft-and-verify fault") }
            if bad.item(Bool.self) || fault == "nonfinite" { throw NemotronTranscribeError.input("non-finite logits") }
            let ys = ysArray.asArray(Int.self), dl = drafts.asArray(Int.self)
            let k = pending.count
            var accepted = 0
            while accepted < dl.count && ys[k - 1 + accepted] == dl[accepted] { accepted += 1 }
            let bonus = ys[k - 1 + accepted]
            let new = Array(dl[..<accepted]) + [bonus]
            let fed = pending + dl
            mcache.trim(depth - 1)
            let upto = k + accepted
            let eNext = Array((Array(fed[1 ..< upto]) + [bonus])[mtpDone...])
            let (nx, nxo) = mtp(embed(MLXArray(eNext.map { Int32($0) }).reshaped(1, -1)), verified[0..., mtpDone ..< upto], cache: mcache)
            drafts = chain(nx[0..., (-1)...], head(nxo[0..., (-1)...]).reshaped(-1))
            if accepted == dl.count {
                pending = [bonus]; mtpDone = 0
            } else {
                for (c, snap) in zip(cache, snapshot) {
                    switch c {
                    case .mamba(let m)?: m.conv = snap?.0; m.state = snap?.1
                    case .attention(let a)?: a.trim(fed.count)
                    case nil: break
                    }
                }
                pending = Array(fed[..<upto]) + [bonus]; mtpDone = upto
            }
            for token in new {
                if eos.contains(token) { return out }
                out.append(token)
                if out.count >= maxTokens { return out }
            }
        }
        return out
    }

    /// `VELLA_TEST_OPTIMIZED_FAULT` (throw | nonfinite): the draft-and-verify path fails at run time (tests).
    static var injectedFault: String? { ProcessInfo.processInfo.environment["VELLA_TEST_OPTIMIZED_FAULT"].flatMap { $0.isEmpty ? nil : $0 } }

    /// Draft-and-verify when allowed; on a runtime failure the same input is decoded again plain greedy (the stock
    /// recipe) and draft-and-verify stays off until reload. Greedy itself has no fallback: its errors propagate.
    func decode(_ embeddings: MLXArray, maxTokens: Int) -> [Int] {
        if usesMTP, let mtp {
            do {
                let tokens = try withError { try decodeMTP(embeddings, maxTokens: maxTokens, mtp: mtp) }
                // A draft-and-verify run that reaches the token limit without an end token is a repetition loop
                // (night 6 Nov, int4 full v2: one 20 s segment repeated "It's awesome." 248 times where plain greedy
                // transcribed it). The chunk is decoded again plain greedy; draft-and-verify stays on for the next one.
                guard tokens.count >= maxTokens else { return tokens }
                runawayRetries += 1
            } catch {
                mtpRuntimeFailure = "\(error)"
                lastRequestFellBack = true
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
        }
        return decodeGreedy(embeddings, maxTokens: maxTokens)
    }

    /// Tests: `decode` as a request runs it, and clearing the sticky fallback between injected faults.
    func decodeWithFallbackForTests(_ embeddings: MLXArray, maxTokens: Int) -> [Int] {
        lastRequestFellBack = false
        return decode(embeddings, maxTokens: maxTokens)
    }
    func resetRuntimeFallbackForTests() { mtpRuntimeFailure = nil; lastRequestFellBack = false }

    func text(_ tokens: [Int]) -> String {
        NemotronTranscribeMarkup.strip(tokenizer?.decode(tokens: tokens, skipSpecialTokens: false) ?? "")
    }

    /// One chunk (at most two minutes) → its text, with the trailing-vocabulary guard.
    func transcribeChunk(_ samples: MLXArray, words: [String], maxTokens: Int) throws -> String {
        guard samples.ndim == 1, samples.dim(0) >= 160 else { return "" }
        let perceptionStart = Date()
        let audio = perception(samples.asType(.float32))
        eval(audio)
        lastPerceptionSeconds = Date().timeIntervalSince(perceptionStart)
        let terms = NemotronTranscribePrompt.vocabulary(words)
        let tokens = decode(try inputs(tokens: try promptTokens(words: terms), audio: audio), maxTokens: maxTokens)
        lastTokens = tokens
        let withList = text(tokens)
        if let candidate = NemotronTranscribeVocabularyGuard.trailingCandidate(withList, words: terms) {
            // The audio embeddings are reused; only the prompt and decode run again.
            let plain = text(decode(try inputs(tokens: try promptTokens(words: []), audio: audio), maxTokens: maxTokens))
            if NemotronTranscribeVocabularyGuard.shouldDrop(withList: withList, withoutList: plain, dropped: candidate.dropped) {
                lastGuardDropped.append(candidate.dropped)
                return candidate.kept
            }
        }
        return withList
    }

    /// Optimized paths only (Standard keeps the stock per-chunk clear).
    static var keepCache: Bool { ProcessInfo.processInfo.environment["VELLA_DICTATION_KEEP_CACHE"] != "0" && !FastPathGate.forcedStock }
    private var lastPerceptionSeconds = 0.0

    public func generate(audio: MLXArray, generationParameters: STTGenerateParameters) -> STTOutput {
        let start = Date()
        let samples = audio.asType(.float32).asArray(Float.self)
        let plan = NemotronTranscribeChunking.plan(samples)
        lastChunkCount = plan.count
        lastGuardDropped = []
        lastError = nil
        lastRequestFellBack = false
        var parts: [String] = []
        var generated = 0
        for range in plan {
            let seconds = Double(range.count) / Double(NemotronTranscribeChunking.sampleRate)
            // About 2.5 tokens a second of speech; generous so a fast talker is never cut.
            let limit = max(generationParameters.maxTokens, Int(seconds * 15))
            lastTokens = []
            let chunkStart = Date()
            do {
                let part = try transcribeChunk(MLXArray(Array(samples[range])), words: vocabularyWords, maxTokens: limit)
                if !part.isEmpty { parts.append(part) }
            } catch {
                lastError = error
                break
            }
            generated += lastTokens.count
            NemotronTranscribeProfile.chunk(seconds: seconds, wall: Date().timeIntervalSince(chunkStart), tokens: lastTokens.count,
                                            mtp: usesMTP, perception: lastPerceptionSeconds)
            // The dictation service keeps MLX's buffer cache between requests (cache-limited); clearing it after every
            // chunk made each 20 s segment re-allocate its Metal buffers. VELLA_DICTATION_KEEP_CACHE=0 restores it.
            if !Self.keepCache { Memory.clearCache() }
        }
        let elapsed = Date().timeIntervalSince(start)
        return STTOutput(text: parts.joined(separator: " "), generationTokens: generated, totalTokens: generated,
                         generationTps: elapsed > 0 ? Double(generated) / elapsed : 0, totalTime: elapsed)
    }
}

/// `VELLA_NEMOTRON_TRANSCRIBE_PROFILE=<file>`: one JSON line per chunk (audio seconds, wall, perception, tokens, path),
/// appended to the file. Lab only; costs nothing when unset.
enum NemotronTranscribeProfile {
    static let path = ProcessInfo.processInfo.environment["VELLA_NEMOTRON_TRANSCRIBE_PROFILE"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    static func chunk(seconds: Double, wall: Double, tokens: Int, mtp: Bool, perception: Double) {
        guard let path else { return }
        let line = String(format: "{\"audio_s\":%.3f,\"wall_s\":%.4f,\"perception_s\":%.4f,\"tokens\":%d,\"mtp\":%@}\n",
                          seconds, wall, perception, tokens, mtp ? "true" : "false")
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
