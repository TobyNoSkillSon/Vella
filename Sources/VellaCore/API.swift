import Foundation

// The local HTTP API's pure parts: request head parsing, loopback security, multipart parsing, OpenAI-compatible
// transcription options and response formatting. The listener (Network.framework) and the job runner live in the app.

/// Bumped on any breaking change to the API; reported as `"api"` in `GET /status` and the status file.
public let vellaAPIVersion = 1
/// Largest request body: an uploaded file plus its multipart framing.
public let apiMaxBodyBytes = 200 * 1024 * 1024
/// Largest JSON body (options and a local path; never audio).
public let apiMaxJSONBytes = 1024 * 1024
/// Largest request head (request line and headers).
public let apiMaxHeadBytes = 64 * 1024
/// Longest audio one request may transcribe.
public let apiMaxAudioSeconds = 3.0 * 3600
/// Largest local file a JSON `path` request may name (a 3 h WAV at 48 kHz stereo is ~2.1 GB).
public let apiMaxPathFileBytes: Int64 = 4 * 1024 * 1024 * 1024

/// An error in OpenAI's envelope: `{"error": {"message", "type", "param", "code"}}` with the HTTP status beside it.
public struct APIError: Error, Equatable {
    public var status: Int
    public var message: String
    public var type: String
    public var param: String?
    public var code: String?
    public init(_ status: Int, _ message: String, type: String? = nil, param: String? = nil, code: String? = nil) {
        self.status = status; self.message = message; self.param = param; self.code = code
        self.type = type ?? {
            switch status {
            case 403: return "permission_error"
            case 404: return code == "model_not_found" ? "invalid_request_error" : "not_found_error"
            case 429: return "rate_limit_error"
            case 500...: return "server_error"
            default: return "invalid_request_error"
            }
        }()
    }
    public var json: [String: Any] {
        ["error": ["message": message, "type": type, "param": param as Any? ?? NSNull(), "code": code as Any? ?? NSNull()]]
    }
}

// MARK: Request head

/// The request line and headers of one HTTP/1.1 request. Header names are lowercased; a repeated header is recorded
/// in `duplicates` (a repeated Origin, Host, Content-Type or Content-Length is never legitimate from a local client).
public struct HTTPHead: Equatable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [String: String]
    public var duplicates: Set<String>
    /// The target without its query string.
    public var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    /// Parses the bytes before the blank line (no trailing CRLFCRLF). Nil for a malformed request line.
    public static func parse(_ head: Data) -> HTTPHead? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:], duplicates: Set<String> = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil { duplicates.insert(name) } else { headers[name] = value }
        }
        return HTTPHead(method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers, duplicates: duplicates)
    }
    /// The media type of Content-Type, lowercased, without parameters.
    public var mediaType: String? {
        headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// The routes the API serves. Anything else is 404 before the body is read.
public enum APIRoute: Equatable {
    case status, models, model(String), transcriptions
    public static func match(_ path: String) -> APIRoute? {
        switch path {
        case "/status": return .status
        case "/v1/models": return .models
        case "/v1/audio/transcriptions": return .transcriptions
        default:
            let prefix = "/v1/models/"
            if path.hasPrefix(prefix), path.count > prefix.count {
                let id = String(path.dropFirst(prefix.count))
                return id.contains("/") ? nil : .model(id.removingPercentEncoding ?? id)
            }
            return nil
        }
    }
    public var method: String { self == .transcriptions ? "POST" : "GET" }
}

/// What a request may send, decided from its head alone: before the body is read and before anything changes.
public enum APIRequestCheck {
    /// Loopback is not a browser trust boundary. Local clients (the `vella` command, curl, the OpenAI SDKs) never send
    /// Origin, address the app as 127.0.0.1/localhost:<port>, and post multipart/form-data or JSON. Refuse a web page's
    /// request (Origin), DNS rebinding (foreign Host), and text/url-encoded "simple" POSTs that skip CORS preflight.
    /// An Authorization header is accepted and ignored (SDKs always send a key).
    public static func refusal(_ head: HTTPHead, port: Int) -> APIError? {
        if head.headers["origin"] != nil { return APIError(403, "cross-origin requests are not accepted") }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard !head.duplicates.contains("host"), let host = head.headers["host"]?.lowercased(), hosts.contains(host) else {
            return APIError(403, "Host must be 127.0.0.1:\(port) or localhost:\(port)")
        }
        for name in ["content-type", "content-length", "transfer-encoding", "authorization", "expect"] where head.duplicates.contains(name) {
            return APIError(400, "repeated \(name) header")
        }
        guard let route = APIRoute.match(head.path) else {
            if head.path.hasPrefix("/v1/audio/translations") { return APIError(404, "translation is not supported; use /v1/audio/transcriptions") }
            return APIError(404, "no route \(head.path); see GET /status, GET /v1/models, POST /v1/audio/transcriptions")
        }
        guard head.method == route.method else { return APIError(405, "\(head.path) takes \(route.method)") }
        if head.headers["transfer-encoding"] != nil { return APIError(411, "chunked request bodies are not supported; send Content-Length") }
        let length: Int
        if let raw = head.headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return APIError(400, "invalid Content-Length") }
            length = value
        } else { length = 0 }
        if route == .transcriptions {
            guard head.headers["content-length"] != nil else { return APIError(411, "send Content-Length") }
            switch head.mediaType {
            case "multipart/form-data":
                guard Multipart.boundary(head.headers["content-type"] ?? "") != nil else { return APIError(400, "multipart/form-data needs a boundary") }
                if length > apiMaxBodyBytes { return APIError(413, "request is \(length) bytes; the limit is \(apiMaxBodyBytes) bytes (200 MB)") }
            case "application/json":
                if length > apiMaxJSONBytes { return APIError(413, "JSON bodies are limited to 1 MB; upload audio as multipart/form-data") }
            default:
                return APIError(415, "Content-Type must be multipart/form-data or application/json")
            }
        } else if length > 0 {
            return APIError(400, "\(head.method) \(head.path) takes no body")
        }
        return nil
    }
    public static func contentLength(_ head: HTTPHead) -> Int { head.headers["content-length"].flatMap(Int.init) ?? 0 }
}

// MARK: Multipart

public struct MultipartPart: Equatable {
    public var name: String
    public var filename: String?
    public var contentType: String?
    /// Byte range of the part's body within the parsed data.
    public var range: Range<Int>
}

public enum Multipart {
    /// The boundary parameter of a multipart Content-Type, unquoted; nil when absent or invalid (RFC 2046: 1–70 chars).
    public static func boundary(_ contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return (1...70).contains(value.utf8.count) ? value : nil
        }
        return nil
    }

    /// Splits a multipart/form-data body into parts (ranges into `data`, no copies). Throws on malformed framing.
    public static func parse(_ data: Data, boundary: String) throws -> [MultipartPart] {
        let bad = APIError(400, "malformed multipart/form-data body")
        let base = data.startIndex
        let delimiter = Data("--\(boundary)".utf8)
        let separator = Data("\r\n--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8), blank = Data("\r\n\r\n".utf8)
        // The first delimiter starts the body or follows a preamble line.
        var cursor: Int
        if data.starts(with: delimiter) { cursor = base + delimiter.count }
        else if let first = data.range(of: separator) { cursor = first.upperBound }
        else { throw bad }
        var parts: [MultipartPart] = []
        while true {
            guard cursor + 2 <= data.endIndex else { throw bad }
            if data[cursor] == UInt8(ascii: "-"), data[cursor + 1] == UInt8(ascii: "-") { return parts }
            // Transport padding (spaces/tabs) may precede the CRLF after a delimiter.
            while cursor < data.endIndex, data[cursor] == 0x20 || data[cursor] == 0x09 { cursor += 1 }
            guard data[cursor..<min(data.endIndex, cursor + 2)] == crlf else { throw bad }
            cursor += 2
            guard let headEnd = data.range(of: blank, in: cursor..<data.endIndex), headEnd.lowerBound - cursor <= 16 * 1024 else { throw bad }
            let headText = String(decoding: data[cursor..<headEnd.lowerBound], as: UTF8.self)
            guard let next = data.range(of: separator, in: headEnd.upperBound..<data.endIndex) else { throw bad }
            var name: String?, filename: String?, type: String?
            for line in headText.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw bad }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "content-disposition" {
                    let params = dispositionParameters(value)
                    name = params["name"]; filename = params["filename"]
                } else if key == "content-type" { type = value }
            }
            guard let name else { throw bad }
            parts.append(MultipartPart(name: name, filename: filename, contentType: type, range: (headEnd.upperBound - base)..<(next.lowerBound - base)))
            cursor = next.upperBound
            if parts.count > 64 { throw APIError(400, "too many multipart fields") }
        }
    }

    /// `form-data; name="file"; filename="a b.wav"` → ["name": "file", "filename": "a b.wav"]. Quoted values may
    /// contain semicolons and escaped quotes.
    static func dispositionParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var chars = Array(value)[...]
        // Skip the disposition type.
        while let c = chars.first, c != ";" { chars = chars.dropFirst() }
        while !chars.isEmpty {
            chars = chars.drop { $0 == ";" || $0 == " " || $0 == "\t" }
            var key = ""
            while let c = chars.first, c != "=", c != ";" { key.append(c); chars = chars.dropFirst() }
            guard chars.first == "=" else { continue }
            chars = chars.dropFirst()
            var val = ""
            if chars.first == "\"" {
                chars = chars.dropFirst()
                while let c = chars.first {
                    chars = chars.dropFirst()
                    if c == "\\", let n = chars.first { val.append(n); chars = chars.dropFirst(); continue }
                    if c == "\"" { break }
                    val.append(c)
                }
            } else {
                while let c = chars.first, c != ";" { val.append(c); chars = chars.dropFirst() }
                val = val.trimmingCharacters(in: .whitespaces)
            }
            result[key.trimmingCharacters(in: .whitespaces).lowercased()] = val
        }
        return result
    }
}

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
