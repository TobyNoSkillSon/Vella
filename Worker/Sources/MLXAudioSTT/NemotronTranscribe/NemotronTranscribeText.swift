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

/// The checkpoint's `nemotron3p5` chat format and ASR task prompt (mlx-audio nemotron_transcribe.py).
public enum NemotronTranscribePrompt {
    public static let audioTag = "<|audio|>"
    public static let asr = "Produce a verbatim transcript of the audio. Preserve named entities, abbreviations, numbers, dates, "
        + "measurements, acronyms, and technical terms as clearly as possible. Keep the same language as spoken and do not translate."
    /// Words passed to the model at most (a long list dilutes the hint and costs prefill).
    public static let maxWords = 128

    /// The user turn. Only the plain word list goes in: never Parakeet's acoustic entries or variants (they are
    /// spellings of sounds, and a model reading them as text is primed to write them).
    public static func user(words: [String]) -> String {
        var prompt = asr
        let terms = vocabulary(words)
        if !terms.isEmpty { prompt += "\nContextual vocabulary: " + terms.joined(separator: ", ") }
        return prompt + " " + audioTag
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
    public static func turns(words: [String]) -> [String] {
        ["<|im_start|>system\n<|im_end|>\n", "<|im_start|>user\n\(user(words: words))<|im_end|>\n", "<|im_start|>assistant\n<think></think>"]
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
/// ("Poznań") that was never spoken. A trailing sentence made only of list words is a candidate; the model decides
/// whether it stays: the same audio is decoded once more without the list, and the candidate is dropped when that
/// transcript has fewer sentences (the plain decode heard nothing there).
public enum NemotronTranscribeVocabularyGuard {
    /// The trailing sentence when it consists only of vocabulary words and something precedes it.
    public static func trailingCandidate(_ text: String, words: [String]) -> (kept: String, dropped: String)? {
        let vocabulary = Set(NemotronTranscribePrompt.vocabulary(words).map { normalize($0) })
        guard !vocabulary.isEmpty else { return nil }
        let sentences = split(text)
        guard sentences.count >= 2, let last = sentences.last else { return nil }
        let tokens = last.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        // Multi-word terms ("Liquid AI") match as a phrase too.
        let phrase = tokens.joined(separator: " ")
        guard vocabulary.contains(phrase) || tokens.allSatisfy({ vocabulary.contains($0) }) else { return nil }
        let kept = sentences.dropLast().joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (kept, last.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// Whether the candidate goes: the decode without the list has fewer sentences.
    public static func shouldDrop(withList: String, withoutList: String) -> Bool {
        split(withoutList).count < split(withList).count
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
        s = s.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</?think>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</?(?:spk|ev|sty):[^<>\s]*>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<\|[a-z_]+\|>"#, with: " ", options: .regularExpression)
        // Tidy the gaps the tags leave: one space between words, none before punctuation.
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" +([,.;:!?…])"#, with: "$1", options: .regularExpression)
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
