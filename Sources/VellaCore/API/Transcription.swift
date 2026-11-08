import Foundation

// MARK: Transcription options

public enum TranscriptFormat: String, CaseIterable {
    case json, text, verbose_json, srt, vtt
}

/// The fields of `POST /v1/audio/transcriptions` Vella uses. Only the audio is required; everything else has a
/// default: the user's dictation model, the language as spoken, the user's vocabulary, JSON out. `temperature` is
/// validated and ignored (decoding is greedy). `language` (a code, an English name or `auto`) and `prompt` reach the
/// model, or the request is refused with a 400 naming why (`TranscriptionControls`); `vocabulary` is `true`/`false`
/// or words to add for this request only ("Kadıköy, Beşiktaş"). verbose_json echoes the requested language (`unknown`
/// when omitted) and what was applied (`vella`).
public struct TranscriptionOptions: Equatable {
    /// Names that mean "the user's dictation model" (OpenAI SDK examples send whisper-1).
    public static let currentAliases: Set<String> = ["", "whisper-1", "vella", "default", "current", "auto"]
    /// Empty: the current dictation model.
    public var model: String
    public var language: String?
    public var prompt: String?
    public var format: TranscriptFormat
    public var temperature: Double?
    public var granularities: [String]
    /// false: this request ignores vocabulary.json (Parakeet's biasing and Nemotron's context terms).
    public var vocabulary: Bool
    /// Words added to the vocabulary for this request only (vocabulary.json is not changed).
    public var words: [String]
    public init(
        model: String = "", language: String? = nil, prompt: String? = nil, format: TranscriptFormat = .json,
        temperature: Double? = nil, granularities: [String] = [], vocabulary: Bool = true, words: [String] = []
    ) {
        self.model = model; self.language = language; self.prompt = prompt; self.format = format
        self.temperature = temperature; self.granularities = granularities; self.vocabulary = vocabulary; self.words = words
    }

    /// The request names no model: the user's dictation model (or, for a language it cannot take, a downloaded model
    /// that can; `TranscriptionControls.pick`).
    public var usesDefaultModel: Bool { Self.currentAliases.contains(model.trimmingCharacters(in: .whitespaces).lowercased()) }

    /// The worker request's `options` object; nil when every setting is the default (the request is unchanged).
    public var workerOptions: [String: Any]? {
        var object: [String: Any] = [:]
        if let language { object["language"] = language }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { object["prompt"] = prompt }
        if !vocabulary { object["vocabulary"] = false }
        if !words.isEmpty { object["words"] = words }
        return object.isEmpty ? nil : object
    }

    /// The most words one request may add, and the vocabulary's word rule (letters only, as vocabulary.json).
    public static let maxWords = 64
    /// "Kadıköy, Beşiktaş" or "Kadıköy Beşiktaş" → ["Kadıköy", "Beşiktaş"]; duplicates dropped, order kept.
    public static func parseWords(_ raw: String) throws -> [String] {
        var words: [String] = []
        for word in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init) {
            guard word.count <= 64, word.allSatisfy(\.isLetter) else {
                throw APIError(400, "vocabulary words are letters only (\(word.prefix(64)) is not); separate them with commas", param: "vocabulary")
            }
            if !words.contains(where: { $0.lowercased() == word.lowercased() }) { words.append(word) }
        }
        guard words.count <= maxWords else { throw APIError(400, "at most \(maxWords) vocabulary words per request", param: "vocabulary") }
        return words
    }

    /// "tr", "TR", "pt-BR", "Turkish", "turkish" → a lowercased code; "auto" → nil (as spoken).
    public static func languageCode(_ raw: String) throws -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || ["auto", "detect", "any"].contains(value.lowercased()) { return nil }
        guard value.count <= 32, value.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" || $0 == " " }) else {
            throw APIError(400, "language must be a code such as tr or a name such as Turkish", param: "language")
        }
        let lower = value.lowercased()
        if lower.count <= 3 || lower.contains("-") || lower.contains("_") {
            guard lower.count <= 16, !lower.contains(" ") else { throw APIError(400, "language must be a code such as tr or a name such as Turkish", param: "language") }
            return lower
        }
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count <= 3 {
            if english.localizedString(forLanguageCode: code)?.lowercased() == lower { return code }
        }
        throw APIError(400, "language \(value) is not a language name Vella knows; use a code such as tr", param: "language", code: "unsupported_language")
    }

    /// Validates form fields (each name → its values, in order). Unknown fields are ignored, like OpenAI's optional
    /// parameters Vella does not implement (`include[]`, `chunking_strategy`).
    public static func validate(_ fields: [String: [String]]) throws -> TranscriptionOptions {
        func one(_ name: String) throws -> String? {
            guard let values = fields[name], !values.isEmpty else { return nil }
            guard values.count == 1 else { throw APIError(400, "\(name) was sent more than once", param: name) }
            return values[0]
        }
        var options = TranscriptionOptions()
        options.model = try one("model")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard options.model.count <= 200 else { throw APIError(400, "model is too long", param: "model") }
        if let raw = try one("response_format"), !raw.isEmpty {
            guard let format = TranscriptFormat(rawValue: raw) else {
                throw APIError(400, "response_format must be one of json, text, verbose_json, srt, vtt", param: "response_format")
            }
            options.format = format
        }
        if let raw = try one("language"), !raw.isEmpty { options.language = try languageCode(raw) }
        if let raw = try one("prompt") {
            guard raw.utf8.count <= 16 * 1024 else { throw APIError(400, "prompt is too long", param: "prompt") }
            options.prompt = raw
        }
        if let raw = try one("vocabulary"), !raw.isEmpty {
            switch raw.lowercased() {
            case "true", "1", "on", "yes": options.vocabulary = true
            case "false", "0", "off", "no", "none": options.vocabulary = false
            default: options.words = try parseWords(raw)
            }
        }
        if let raw = try one("temperature"), !raw.isEmpty {
            guard let value = Double(raw), value.isFinite, (0...1).contains(value) else {
                throw APIError(400, "temperature must be a number between 0 and 1", param: "temperature")
            }
            options.temperature = value
        }
        let granularities = (fields["timestamp_granularities[]"] ?? []) + (fields["timestamp_granularities"] ?? [])
        if granularities.contains("word") {
            throw APIError(
                400, "Word timestamps are not supported. Use timestamp_granularities[]=segment with response_format=verbose_json (JSON: timestamp_granularities: [\"segment\"]).",
                param: "timestamp_granularities")
        }
        for value in granularities where value != "segment" {
            throw APIError(400, "Only segment timestamps are supported.", param: "timestamp_granularities")
        }
        options.granularities = granularities
        if !granularities.isEmpty, options.format != .verbose_json {
            throw APIError(400, "timestamp_granularities requires response_format verbose_json", param: "timestamp_granularities")
        }
        if let raw = try one("stream"), raw.lowercased() == "true" {
            throw APIError(400, "streaming responses are not supported; omit stream", param: "stream")
        }
        return options
    }

    /// A JSON body: the same options plus `path`, an absolute local file (the `vella` command's call; no upload).
    public static func validate(json body: Data) throws -> (path: String, options: TranscriptionOptions) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw APIError(400, "body must be a JSON object")
        }
        var fields: [String: [String]] = [:]
        // A list of words is always words, even "No" or "On" (review, 8 Nov): only a scalar can be true/false.
        var listed: [String]?
        for (key, value) in object where key != "path" {
            switch value {
            case let s as String: fields[key] = [s]
            case let n as NSNumber: fields[key] = [CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue]
            case let a as [String] where key == "timestamp_granularities": fields[key] = a
            case let a as [String] where key == "vocabulary": listed = a
            case is NSNull: continue
            default: throw APIError(400, "\(key) has an unsupported type", param: key)
            }
        }
        guard let path = object["path"] as? String, path.hasPrefix("/") else {
            throw APIError(400, "a JSON request needs path: an absolute path to a local audio file (or upload it as multipart/form-data)", param: "path")
        }
        var options = try validate(fields)
        if let listed { options.words = try parseWords(listed.joined(separator: ",")) }
        return (path, options)
    }
}

// MARK: What each model can apply

/// Which request settings a Dictation model applies. A setting a model cannot apply is refused, never dropped
/// (agent friction, 8 Nov: `--language tr` was accepted and silently ignored). One exception, by design: a language
/// a detecting model (Parakeet) already covers is accepted and left to its detection, since that is what it does with
/// that language anyway; `vella.language_applied` stays null so the echo is honest.
public enum TranscriptionControls {
    public struct Capabilities: Equatable {
        public var language: Bool
        public var prompt: Bool
        /// Takes added vocabulary words (Parakeet's biasing, Nemotron's context terms).
        public var words: Bool
    }
    /// By catalog family. Families outside the catalog (lab and test models) pass through; their helper refuses
    /// what its architecture cannot apply.
    public static func capabilities(familyID: String) -> Capabilities {
        let id = familyID.lowercased()
        if id.hasPrefix("parakeet-") { return Capabilities(language: false, prompt: false, words: true) }
        if id.hasPrefix("whisper-") || id.hasPrefix("qwen3-asr-") { return Capabilities(language: true, prompt: false, words: false) }
        return Capabilities(language: true, prompt: true, words: true)
    }
    /// Models that can take `language` / `prompt` / words, for the error text.
    static let languageModels = "Nemotron 3.5 Transcribe, Whisper or Qwen3-ASR"
    static let promptModels = "Nemotron 3.5 Transcribe"
    static let wordModels = "Parakeet or Nemotron 3.5 Transcribe"

    static func knows(_ language: String, _ languages: [String]) -> Bool {
        let base = String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        return languages.isEmpty || languages.contains(where: { $0.lowercased() == base || $0.lowercased() == language })
    }

    /// Whether `familyID` can serve `options` as asked (a known language, every setting it takes).
    public static func serves(_ options: TranscriptionOptions, familyID: String, languages: [String]) -> Bool {
        let can = capabilities(familyID: familyID)
        if let language = options.language, !knows(language, languages) || (!can.language && languages.isEmpty) { return false }
        if let prompt = options.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !can.prompt { return false }
        if !options.words.isEmpty, !can.words { return false }
        return true
    }

    /// Downloaded models tried, in order, when the dictation model cannot take the requested language: the light
    /// multilingual ones first, the 30B Nemotron last.
    public static let languageFallbackOrder = [
        "qwen3-asr-1.7b", "whisper-large-v3-turbo", "whisper-large-v3", "qwen3-asr-0.6b", "nemotron-3.5-transcribe"
    ]
    /// A request that names no model and asks for a language the dictation model does not know: the first downloaded
    /// model (`available`: id and languages) that serves it. Nil keeps the dictation model (it serves the request, or
    /// nothing downloaded does, and its refusal names what to do).
    public static func pick(_ options: TranscriptionOptions, current: String?, available: [(id: String, languages: [String])]) -> String? {
        guard options.usesDefaultModel, options.language != nil, let current,
            let mine = available.first(where: { $0.id == current }),
            !serves(options, familyID: mine.id, languages: mine.languages)
        else { return nil }
        let ranked = available.sorted { a, b in
            (languageFallbackOrder.firstIndex(of: a.id) ?? Int.max) < (languageFallbackOrder.firstIndex(of: b.id) ?? Int.max)
        }
        return ranked.first(where: { $0.id != current && serves(options, familyID: $0.id, languages: $0.languages) })?.id
    }

    /// A model asked for by name: its exact id, else the only id starting with it ("nemotron", "whisper-large-v3-t"),
    /// else among several the current one, else the first in catalog order ("parakeet" → parakeet-v3-ultra).
    public static func match(_ requested: String, ids: [String], current: String?) -> String? {
        let key = requested.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = ids.first(where: { $0.lowercased() == key }) { return exact }
        let prefixed = ids.filter { $0.lowercased().hasPrefix(key) }
        if let current, prefixed.contains(current) { return current }
        return prefixed.first
    }

    /// The words in the user's vocabulary.json (0 when it is absent); nil when it cannot be read as a vocabulary.
    public static func vocabularyWordCount(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? Data(contentsOf: url), data.count <= 65536,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let words = object["words"] as? [Any]
        else { return nil }
        return words.count
    }

    /// Added words and the user's vocabulary must fit vocabulary.json's 128-word limit together: a 400, never a drop.
    public static func checkRoom(_ options: TranscriptionOptions, vocabularyWords: Int?) throws {
        guard !options.words.isEmpty else { return }
        let total = (options.vocabulary ? vocabularyWords ?? 0 : 0) + options.words.count
        guard total <= 128 else {
            throw APIError(
                400, "Your vocabulary and the added words come to \(total); at most 128 fit. Add fewer words, or leave the vocabulary out.",
                param: "vocabulary", code: "vocabulary_too_large")
        }
    }

    /// The settings this family is sent: a language a detecting model covers is left to its detection.
    public static func applying(_ options: TranscriptionOptions, familyID: String) -> TranscriptionOptions {
        var out = options
        if !capabilities(familyID: familyID).language { out.language = nil }
        return out
    }

    /// Throws the 400 for a setting `familyID` cannot apply, or a language outside `languages` (when it lists any).
    public static func check(_ options: TranscriptionOptions, familyID: String, name: String, languages: [String]) throws {
        let can = capabilities(familyID: familyID)
        if let language = options.language {
            if !can.language, languages.isEmpty {
                throw APIError(
                    400, "\(name) detects the language itself and cannot be told one. Omit language, or use \(languageModels).",
                    param: "language", code: "unsupported_parameter")
            }
            if !knows(language, languages) {
                throw APIError(
                    400,
                    "\(name) does not recognize language \(language). It knows: \(languages.joined(separator: ", ")). Omit language to detect it, "
                        + "or name a model that knows it (\(languageModels); `vella models` lists them; get one only with the user's consent).",
                    param: "language", code: "unsupported_language")
            }
        }
        if let prompt = options.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !can.prompt {
            throw APIError(
                400, "\(name) cannot use a prompt. Omit prompt, or use \(promptModels), which takes it as context terms.",
                param: "prompt", code: "unsupported_parameter")
        }
        if !options.words.isEmpty, !can.words {
            throw APIError(
                400, "\(name) cannot take vocabulary words. Omit them, or use \(wordModels).",
                param: "vocabulary", code: "unsupported_parameter")
        }
        if !options.words.isEmpty, let prompt = options.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw APIError(
                400, "A prompt replaces the vocabulary, so added words would not reach the model. Send words or a prompt, not both.",
                param: "vocabulary", code: "unsupported_parameter")
        }
    }
}

/// What a transcription actually applied, gathered from its segments' worker replies (`applied`).
public struct AppliedSettings: Equatable {
    /// The language the model was told; nil: as spoken.
    public var language: String?
    /// The exact instruction sent (Nemotron 3.5 Transcribe; nil for models without a text prompt).
    public var prompt: String?
    public var vocabulary = true
    /// Vocabulary words the model was given (the most any segment used).
    public var vocabularyWords = 0
    /// Segments whose decode still ended in a repetition loop (their text keeps one copy of the repeated block).
    public var loops = 0
    /// Vocabulary sentences removed because the model wrote the list, not the speech.
    public var vocabularyDropped = 0
    /// Segments served by Heimdall's shared model, and by Vella's own.
    public var heimdallSegments = 0, ownSegments = 0
    public init() {}
    /// "heimdall", "vella" or "mixed"; nil before any segment.
    public var via: String? {
        heimdallSegments > 0 && ownSegments > 0 ? "mixed" : heimdallSegments > 0 ? "heimdall" : ownSegments > 0 ? "vella" : nil
    }

    /// Adds one segment's `applied` object.
    public mutating func add(_ object: [String: Any]) {
        if let value = object["language"] as? String { language = value }
        if let value = object["prompt"] as? String, prompt == nil { prompt = value }
        if let value = object["vocabulary"] as? Bool { vocabulary = value }
        if let value = (object["vocabulary_words"] as? NSNumber)?.intValue { vocabularyWords = max(vocabularyWords, value) }
        loops += (object["loops"] as? NSNumber)?.intValue ?? 0
        vocabularyDropped += (object["vocabulary_dropped"] as? NSNumber)?.intValue ?? 0
        if object["via"] as? String == "heimdall" { heimdallSegments += 1 } else { ownSegments += 1 }
    }

    /// Plain warnings for the response; empty when the transcript needs none.
    public var warnings: [String] {
        loops == 0
            ? []
            : [
                "\(loops) \(loops == 1 ? "segment" : "segments") ended in a repetition loop; the repeated words are kept once and "
                    + "speech there may be missing. Try another precision or model for this audio."
            ]
    }
}

// MARK: Responses

/// One timed piece of a transcript (one of the app's audio segments; seconds from the start of the file).
public struct TranscriptSegment: Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public init(id: Int, start: Double, end: Double, text: String) { self.id = id; self.start = start; self.end = end; self.text = text }
}

public enum TranscriptFormatter {
    /// Body and Content-Type for a finished transcript in the requested format.
    public static func render(
        _ format: TranscriptFormat, text: String, segments: [TranscriptSegment], duration: Double,
        language: String?, model: String? = nil, applied: AppliedSettings? = nil
    ) -> (contentType: String, body: Data) {
        let usage: [String: Any] = ["type": "duration", "seconds": Int(duration.rounded(.up))]
        let warnings = applied?.warnings ?? []
        switch format {
        case .json:
            var object: [String: Any] = ["text": text, "usage": usage]
            if !warnings.isEmpty { object["warnings"] = warnings }
            return ("application/json", jsonData(object))
        case .verbose_json:
            let items: [[String: Any]] = segments.map {
                ["id": $0.id, "seek": 0, "start": round3($0.start), "end": round3($0.end), "text": $0.text, "tokens": [Int](), "temperature": 0.0]
            }
            var object: [String: Any] = [
                "task": "transcribe", "language": language ?? "unknown", "duration": round3(duration),
                "text": text, "segments": items, "usage": usage
            ]
            if let applied {
                // What reached the model: agents need not read the source to check it (friction 2, 8 Nov).
                var vella: [String: Any] = [
                    "language_applied": applied.language as Any? ?? NSNull(), "vocabulary": applied.vocabulary,
                    "vocabulary_words": applied.vocabularyWords, "loops": applied.loops, "vocabulary_dropped": applied.vocabularyDropped
                ]
                if let model { vella["model"] = model }
                if let prompt = applied.prompt { vella["prompt"] = prompt }
                if let via = applied.via { vella["via"] = via }
                object["vella"] = vella
            }
            if !warnings.isEmpty { object["warnings"] = warnings }
            return ("application/json", jsonData(object))
        case .text:
            return ("text/plain; charset=utf-8", Data((text + "\n").utf8))
        case .srt:
            let blocks = segments.enumerated().map { i, s in "\(i + 1)\n\(timestamp(s.start, ",")) --> \(timestamp(s.end, ","))\n\(s.text)\n" }
            return ("text/plain; charset=utf-8", Data(blocks.joined(separator: "\n").utf8))
        case .vtt:
            let blocks = segments.map { "\(timestamp($0.start, ".")) --> \(timestamp($0.end, "."))\n\($0.text)\n" }
            return ("text/plain; charset=utf-8", Data((["WEBVTT\n"] + blocks).joined(separator: "\n").utf8))
        }
    }
    /// 3725.5 → "01:02:05,500"
    public static func timestamp(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    public static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
