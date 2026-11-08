// SPDX-License-Identifier: MIT
// MLX-free parts of Nemotron 3.5 Transcribe: prompt format, vocabulary prompt, chunk plan and the trailing-word guard.
import Foundation

public enum NemotronTranscribeError: Error, LocalizedError {
    case config(String)
    case weights(String)
    case tokenizer(String)
    case input(String)

    public var errorDescription: String? {
        switch self {
        case .config(let s): "Nemotron Transcribe config: \(s)"
        case .weights(let s): "Nemotron Transcribe weights: \(s)"
        case .tokenizer(let s): "Nemotron Transcribe tokenizer: \(s)"
        case .input(let s): "Nemotron Transcribe input: \(s)"
        }
    }
}

/// The checkpoint's `nemotron3p5` chat format and NVIDIA's recommended verbatim ASR prompt (model card, "Prompt
/// Guide" and "Exact ASR Benchmark Prompts"): empty system prompt, thinking off, the instruction in the user turn.
public enum NemotronTranscribePrompt {
    public static let audioTag = "<|audio|>"
    /// NVIDIA's verbatim template; `Language:` reads "as spoken" unless a request names the language.
    public static let asr = instruction(language: nil)
    /// mlx-audio's default prompt, which Vella sent before 2.2.1 (the opt-in parity test's reference used it).
    public static let mlxAudioASR = "Produce a verbatim transcript of the audio. Preserve named entities, abbreviations, numbers, dates, "
        + "measurements, acronyms, and technical terms as clearly as possible. Keep the same language as spoken and do not translate."
    /// Words passed to the model at most (a long list dilutes the hint and costs prefill).
    public static let maxWords = 128
    /// A request's context text at most (the API's `prompt`), in characters.
    public static let maxContextCharacters = 2_000

    /// The verbatim instruction with its language slot filled ("Turkish"), or "as spoken".
    public static func instruction(language: String?) -> String {
        let name = language?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "")
        let slot = (name?.isEmpty ?? true) ? "as spoken" : name!
        return "Audio transcription. Language: \(slot). Wording: verbatim, including fillers and repetitions. "
            + "Formatting: punctuation and capitalization. Output: transcript only."
    }

    /// The user turn. Context goes in NVIDIA's `Context terms:` slot: the request's own context when it has one
    /// (it replaces the vocabulary), else the plain vocabulary word list. Never Parakeet's acoustic entries or
    /// variants (they are spellings of sounds, and a model reading them as text is primed to write them).
    public static func user(words: [String], language: String? = nil, context: String? = nil, instruction custom: String? = nil) -> String {
        var prompt = custom ?? instruction(language: language)
        if let terms = contextTerms(words: words, context: context) { prompt += " Context terms: " + terms }
        return prompt + " " + audioTag
    }

    /// What follows "Context terms:", or nil for none: the request's context on one line (ending with a full stop),
    /// else the vocabulary list.
    public static func contextTerms(words: [String], context: String?) -> String? {
        if let context {
            var line = context.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            line = String(line.prefix(maxContextCharacters))
            guard !line.isEmpty else { return nil }
            return ".!?…".contains(line.last!) ? line : line + "."
        }
        let terms = vocabulary(words)
        return terms.isEmpty ? nil : terms.joined(separator: ", ") + "."
    }

    /// Trimmed, non-empty, de-duplicated (case-insensitively, first spelling kept), at most `maxWords`.
    public static func vocabulary(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !term.contains("\n"), seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count == maxWords { break }
        }
        return out
    }

    /// The three chat turns, each tokenized on its own without BOS (as NeMo does). Thinking is off.
    public static func turns(words: [String], language: String? = nil, context: String? = nil, instruction custom: String? = nil) -> [String] {
        ["<|im_start|>system\n<|im_end|>\n", "<|im_start|>user\n\(user(words: words, language: language, context: context, instruction: custom))<|im_end|>\n",
         "<|im_start|>assistant\n<think></think>"]
    }

    /// English name of an ISO 639 code for the `Language:` slot ("tr" → "Turkish"); nil when unknown.
    public static func languageName(_ code: String) -> String? {
        let key = code.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").lowercased()
        guard !key.isEmpty else { return nil }
        let base = String(key.split(separator: "-").first ?? Substring(key))
        guard let name = Locale(identifier: "en_US").localizedString(forLanguageCode: base), name.lowercased() != base else { return nil }
        return name
    }
}

/// Repetition loops. The model can fail to stop and repeat one block until the token limit (NVIDIA's card,
/// "Generation-Loop Guardrail"; on a noisy Turkish recording (8 Nov) int4 repeated "Kültür! Beden!" 167 times, in Vella's
/// Swift path and in mlx-audio's Python code alike, with or without draft-and-verify).
public enum NemotronTranscribeLoop {
    /// A block repeated this many times in a row is a loop (the card's guardrail threshold).
    public static let minRepeats = 20
    /// Longest repeated block looked for during decoding, in tokens.
    public static let maxPeriod = 64

    /// When the tail of `tokens` is one block of at most `maxPeriod` tokens repeated at least `minRepeats` times:
    /// where the repetition starts and the block length. The shortest block wins.
    public static func tail(_ tokens: [Int], minRepeats: Int = minRepeats, maxPeriod: Int = maxPeriod) -> (start: Int, period: Int)? {
        let n = tokens.count
        guard minRepeats >= 2 else { return nil }
        for period in 1 ... maxPeriod where period * minRepeats <= n {
            var periodic = true
            for i in 0 ..< period * (minRepeats - 1) where tokens[n - 1 - i] != tokens[n - 1 - i - period] {
                periodic = false
                break
            }
            guard periodic else { continue }
            var start = n - period * minRepeats
            while start > 0, tokens[start - 1] == tokens[start - 1 + period] { start -= 1 }
            return (start, period)
        }
        return nil
    }

    /// The tokens up to and including the first copy of a looping tail, and whether there was one.
    public static func cut(_ tokens: [Int]) -> (tokens: [Int], looped: Bool) {
        guard let loop = tail(tokens) else { return (tokens, false) }
        return (Array(tokens[..<(loop.start + loop.period)]), true)
    }

    // The card's `cleanup_generation_loops`, adapted from Qwen3-ASR's `detect_and_fix_repetitions` (Apache-2.0,
    // Copyright 2026 The Alibaba Qwen team; see THIRD_PARTY_NOTICES.md): a character repeated more than 20 times, and a
    // block of 1–4,096 characters repeated at least 20 times, each collapse to one copy.
    private static let charRun = try! NSRegularExpression(pattern: #"(.)\1{20,}"#, options: [.dotMatchesLineSeparators])
    private static let blockRun = try! NSRegularExpression(pattern: #"(.{1,4096}?)\1{19,}"#, options: [.dotMatchesLineSeparators])

    /// NVIDIA's guardrail on decoded text; text without such a run is returned unchanged.
    public static func cleanup(_ text: String) -> String {
        var s = text
        for regex in [charRun, blockRun] {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
        }
        return s
    }

    /// Where a looping chunk is cut in two for a second try: the quietest 100 ms frame in its middle half, or nil
    /// when either half would be shorter than `minimumSeconds`.
    public static func split(_ samples: [Float], range: Range<Int>, sampleRate: Int = 16_000, minimumSeconds: Double = 4) -> Int? {
        let minimum = Int(minimumSeconds * Double(sampleRate))
        guard range.count >= 2 * minimum else { return nil }
        let frame = sampleRate / 10
        let lower = max(range.lowerBound + range.count / 4, range.lowerBound + minimum)
        let upper = min(range.upperBound - range.count / 4, range.upperBound - minimum)
        guard upper - lower >= frame else { return range.lowerBound + range.count / 2 }
        var best = range.lowerBound + range.count / 2, bestEnergy = Double.infinity
        var start = lower
        while start + frame <= upper {
            var energy = 0.0
            for i in start ..< (start + frame) { energy += Double(samples[i] * samples[i]) }
            if energy < bestEnergy { bestEnergy = energy; best = start + frame / 2 }
            start += frame / 2
        }
        return best
    }

    /// A decoded piece of audio: its text, whether its decode still ended in a loop, and its generated tokens.
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var looped: Bool
        public var tokens: Int
        public init(text: String, looped: Bool, tokens: Int = 0) { self.text = text; self.looped = looped; self.tokens = tokens }
    }

    /// Decodes `range`; a piece that still loops after the decoder's own retry is cut in two at a quiet point and each
    /// half decoded again (at most `depth` times), so the speech after a loop is not lost. A half that loops once
    /// more keeps its text up to the first copy of the loop.
    public static func recovering(
        _ range: Range<Int>, depth: Int = 2, decode: (Range<Int>) throws -> Piece, split: (Range<Int>) -> Int?
    ) rethrows -> [Piece] {
        let piece = try decode(range)
        guard piece.looped, depth > 0, let cut = split(range), cut > range.lowerBound, cut < range.upperBound else { return [piece] }
        return try recovering(range.lowerBound ..< cut, depth: depth - 1, decode: decode, split: split)
            + recovering(cut ..< range.upperBound, depth: depth - 1, decode: decode, split: split)
    }
}

/// Where long recordings are cut. The model is offline: text appears only after a whole chunk is encoded, and on
/// recordings of several minutes small numeric changes flipped punctuation and one run dropped its last two sentences.
/// So chunks are at most two minutes, cut at the quietest 100 ms in the last 20 s before the limit.
public enum NemotronTranscribeChunking {
    public static let sampleRate = 16_000
    public static let maxSeconds = 120.0
    public static let searchSeconds = 20.0
    static let frame = 1_600

    public static func plan(_ samples: [Float], maxSeconds: Double = maxSeconds, searchSeconds: Double = searchSeconds) -> [Range<Int>] {
        let limit = Int(maxSeconds * Double(sampleRate))
        let search = min(limit / 2, Int(searchSeconds * Double(sampleRate)))
        guard samples.count > limit else { return [0 ..< samples.count] }
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > limit {
            let end = start + limit
            var best = end, bestEnergy = Double.infinity
            // Frames ending at or before `end`, latest first, so ties keep the longest chunk.
            var frameEnd = end
            while frameEnd - frame >= end - search {
                var energy = 0.0
                for i in (frameEnd - frame) ..< frameEnd { energy += Double(samples[i] * samples[i]) }
                if energy < bestEnergy { bestEnergy = energy; best = frameEnd - frame / 2 }
                frameEnd -= frame / 2
            }
            ranges.append(start ..< best)
            start = best
        }
        ranges.append(start ..< samples.count)
        return ranges
    }
}

/// The vocabulary hint can make words up: on Toby's speech, a 17-word list made the model append a list word
/// ("Poznań") that was never spoken. A trailing sentence made only of list words is a candidate (or the whole text,
/// when it is only list words); the model decides whether it stays: the same audio is decoded once more without the
/// list, and the candidate is dropped when that transcript is shorter by at least the candidate's words (the plain
/// decode heard nothing there). Word counts, not sentences: the plain decode may punctuate differently.
public enum NemotronTranscribeVocabularyGuard {
    /// The trailing sentence when it consists only of vocabulary words (kept is empty when nothing precedes it).
    public static func trailingCandidate(_ text: String, words: [String]) -> (kept: String, dropped: String)? {
        let vocabulary = Set(NemotronTranscribePrompt.vocabulary(words).map { normalize($0) })
        guard !vocabulary.isEmpty else { return nil }
        let sentences = split(text)
        guard let last = sentences.last else { return nil }
        let tokens = last.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        // Multi-word terms ("Liquid AI") match as a phrase too.
        let phrase = tokens.joined(separator: " ")
        guard vocabulary.contains(phrase) || tokens.allSatisfy({ vocabulary.contains($0) }) else { return nil }
        let kept = sentences.dropLast().joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (kept, last.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The hint can also leak as the list itself, anywhere in the text (a noisy Turkish recording, 8 Nov: the
    /// output opened with "Vella, Heimdall, Qwen, harness, Nemotron, …" and repeated it later). A sentence of at least
    /// `listMinimumWords` list words that are at least 80 % of its words is a candidate; `shouldDropList` decides.
    public static let listMinimumWords = 3
    public static func listCandidates(_ text: String, words: [String]) -> [String] {
        let vocabulary = vocabularyTokens(words)
        guard !vocabulary.isEmpty else { return [] }
        return split(text).filter { sentence in
            let tokens = tokens(sentence)
            let listed = tokens.filter { vocabulary.contains($0) }.count
            return listed >= listMinimumWords && Double(listed) >= 0.8 * Double(tokens.count)
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A list candidate goes when the decode without the list did not hear most of its list words: fewer than half
    /// of them appear anywhere in that transcript, spelled alike ("Heimdal" or "Bella" counts as hearing "Heimdall" or
    /// "Vella": without the list the model misspells exactly these words). Keeping wins a tie.
    public static func shouldDropList(_ candidate: String, withoutList: String, words: [String]) -> Bool {
        let vocabulary = vocabularyTokens(words)
        let listed = tokens(candidate).filter { vocabulary.contains($0) }
        guard !listed.isEmpty else { return false }
        let heard = Set(tokens(withoutList))
        return 2 * listed.filter { word in heard.contains { alike($0, word) } }.count < listed.count
    }

    /// Equal, or within one character edit per four letters (at least one).
    static func alike(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let limit = max(1, max(x.count, y.count) / 4)
        guard abs(x.count - y.count) <= limit else { return false }
        var row = Array(0 ... y.count)
        for i in 1 ... max(1, x.count) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[y.count] <= limit
    }

    /// `text` without the given sentences (each removed once, in order), spaces tidied.
    public static func removing(_ dropped: [String], from text: String) -> String {
        var remaining = dropped
        let kept = split(text).filter { sentence in
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = remaining.firstIndex(of: trimmed) { remaining.remove(at: i); return false }
            return true
        }
        return kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every word of every list term, normalized ("Liquid AI" → "liquid", "ai").
    static func vocabularyTokens(_ words: [String]) -> Set<String> {
        Set(NemotronTranscribePrompt.vocabulary(words).flatMap { tokens($0) })
    }
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// Sentences with their terminators and trailing spaces (a fragment without a terminator counts).
    public static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var chars = Array(text)
        while chars.last?.isWhitespace == true { chars.removeLast() }
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if ".!?…".contains(chars[i]) {
                while i + 1 < chars.count, ".!?…\"”')".contains(chars[i + 1]) { i += 1; current.append(chars[i]) }
                if i + 1 == chars.count || chars[i + 1].isWhitespace {
                    while i + 1 < chars.count, chars[i + 1].isWhitespace { i += 1; current.append(chars[i]) }
                    out.append(current); current = ""
                }
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return out
    }

    /// Whether the candidate goes: the plain decode has no words where the list decode wrote it. The plain decode is
    /// anchored at the last word the two should share (the last kept word, matched from the end), so a filler or a
    /// near-tie spelling elsewhere cannot decide it. Without that anchor, word counts decide. Keeping wins any doubt.
    public static func shouldDrop(withList: String, withoutList: String, dropped: String) -> Bool {
        func words(_ t: String) -> [String] { t.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty } }
        let list = words(withList), plain = words(withoutList), candidate = words(dropped)
        let kept = Array(list.dropLast(candidate.count))
        let tail: Int
        if let anchor = kept.last, let index = plain.lastIndex(of: anchor) {
            tail = plain.count - index - 1
        } else {
            tail = plain.count - kept.count
        }
        return tail <= 0
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
    }
}

/// Dictation uses only the plain ASR prompt, which emits no markup. If any slips out anyway, it is removed and the
/// words between tags are kept: speaker tags (<spk:N>), event and style tags (<ev:…>, <sty:…>), and thinking blocks
/// (a <think>…</think> block is dropped with its content; a stray <think> or </think> tag alone is removed).
public enum NemotronTranscribeMarkup {
    public static func strip(_ text: String) -> String {
        var s = text
        // Each removed tag leaves a marker; only the gaps at markers are tidied, so text without markup is unchanged
        // (French spacing before "?" stays).
        let mark = "\u{1}"
        for pattern in [#"<think>[\s\S]*?</think>"#, #"</?think>"#, #"</?(?:spk|ev|sty):[^<>\s]*>"#, #"<\|[a-z_]+\|>"#] {
            s = s.replacingOccurrences(of: pattern, with: mark, options: .regularExpression)
        }
        guard s.contains(mark) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        s = s.replacingOccurrences(of: #"[ \t]*\x{01}[\s\x{01}]*(?=[,.;:!?…]|$)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s\x{01}]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]*\x{01}[\s\x{01}]*"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// NVIDIA's NeMo checkpoint keys → the MLX module tree (mlx-audio `Model.sanitize`). nil: not loaded (the MTP and
/// CTC-timestamp heads, empty `_extra_state` tensors).
public enum NemotronTranscribeKeys {
    public struct Transform: Equatable, Sendable {
        /// (0, 2, 1): stacked experts to [experts, out, in]; depthwise and upsampling convolutions to MLX layout.
        public var transpose = false
        /// The MoE router computes in FP32 (Automodel), even with BF16 weights.
        public var float32 = false
    }

    public static func map(_ original: String, shape: [Int]) -> (String, Transform)? {
        if original.hasPrefix("llm.mtp.") || original.hasPrefix("ctc_timestamp.") || original.hasSuffix("._extra_state") { return nil }
        var key = original
        for (from, to) in [("llm.model.embed_tokens.", "llm.backbone.embeddings."), ("llm.model.norm.", "llm.backbone.norm_f."),
                           ("llm.model.layers.", "llm.backbone.layers."), ("._fp32_params.", "."), (".ffn.net.0.", ".ffn.linear1."),
                           (".ffn.net.3.", ".ffn.linear2."), (".preprocessor.featurizer.", ".preprocessor.")] {
            key = key.replacingOccurrences(of: from, with: to)
        }
        var t = Transform()
        if key.hasSuffix(".experts.gate_and_up_projs") {
            key = key.replacingOccurrences(of: ".experts.gate_and_up_projs", with: ".switch_mlp.fc1.weight"); t.transpose = true
        } else if key.hasSuffix(".experts.down_projs") {
            key = key.replacingOccurrences(of: ".experts.down_projs", with: ".switch_mlp.fc2.weight"); t.transpose = true
        } else if key.hasSuffix(".conv1d.weight"), shape.count == 3, shape[1] == 1 {
            t.transpose = true
        } else if key.hasSuffix(".subpixel_upsample.weight"), shape.count == 3, shape[2] == 3 {
            t.transpose = true
        }
        if key.hasPrefix("llm."), key.hasSuffix(".gate.weight") { t.float32 = true }
        return (key, t)
    }
}
