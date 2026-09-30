import Foundation

// MARK: Transcription options

public enum TranscriptFormat: String, CaseIterable {
    case json, text, verbose_json, srt, vtt
}

/// The fields of `POST /v1/audio/transcriptions` Vella uses. `temperature` is validated and ignored (decoding is
/// greedy); `prompt` is accepted and ignored; `language` is echoed in verbose_json (the models detect the language).
public struct TranscriptionOptions: Equatable {
    /// Empty: the current dictation model.
    public var model: String
    public var language: String?
    public var prompt: String?
    public var format: TranscriptFormat
    public var temperature: Double?
    public var granularities: [String]
    public init(model: String = "", language: String? = nil, prompt: String? = nil, format: TranscriptFormat = .json,
                temperature: Double? = nil, granularities: [String] = []) {
        self.model = model; self.language = language; self.prompt = prompt; self.format = format
        self.temperature = temperature; self.granularities = granularities
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
        if let raw = try one("language"), !raw.isEmpty {
            guard raw.count <= 16, raw.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else {
                throw APIError(400, "language must be an ISO-639-1 code such as en", param: "language")
            }
            options.language = raw.lowercased()
        }
        if let raw = try one("prompt") {
            guard raw.utf8.count <= 16 * 1024 else { throw APIError(400, "prompt is too long", param: "prompt") }
            options.prompt = raw
        }
        if let raw = try one("temperature"), !raw.isEmpty {
            guard let value = Double(raw), value.isFinite, (0...1).contains(value) else {
                throw APIError(400, "temperature must be a number between 0 and 1", param: "temperature")
            }
            options.temperature = value
        }
        let granularities = (fields["timestamp_granularities[]"] ?? []) + (fields["timestamp_granularities"] ?? [])
        for value in granularities where !["word", "segment"].contains(value) {
            throw APIError(400, "timestamp_granularities must be word or segment", param: "timestamp_granularities")
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
        for (key, value) in object where key != "path" {
            switch value {
            case let s as String: fields[key] = [s]
            case let n as NSNumber: fields[key] = [CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue]
            case let a as [String] where key == "timestamp_granularities": fields[key] = a
            case is NSNull: continue
            default: throw APIError(400, "\(key) has an unsupported type", param: key)
            }
        }
        guard let path = object["path"] as? String, path.hasPrefix("/") else {
            throw APIError(400, "a JSON request needs path: an absolute path to a local audio file (or upload it as multipart/form-data)", param: "path")
        }
        return (path, try validate(fields))
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
    public static func render(_ format: TranscriptFormat, text: String, segments: [TranscriptSegment], duration: Double,
                              language: String?) -> (contentType: String, body: Data) {
        let usage: [String: Any] = ["type": "duration", "seconds": Int(duration.rounded(.up))]
        switch format {
        case .json:
            return ("application/json", jsonData(["text": text, "usage": usage]))
        case .verbose_json:
            let items: [[String: Any]] = segments.map {
                ["id": $0.id, "seek": 0, "start": round3($0.start), "end": round3($0.end), "text": $0.text, "tokens": [Int](), "temperature": 0.0]
            }
            return ("application/json", jsonData(["task": "transcribe", "language": language ?? "unknown", "duration": round3(duration),
                                                  "text": text, "segments": items, "usage": usage]))
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
