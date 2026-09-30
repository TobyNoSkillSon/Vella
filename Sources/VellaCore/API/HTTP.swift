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

/// Aggregate bounds on what unfinished requests may hold before the job queue sees them. Every connection, and every
/// upload spooled to disk, holds a reservation from accept or spool to its end; the budget refuses a new one past these
/// limits, so stalled or slow clients cannot use up the descriptors or the disk that recording needs.
public struct APIUploadLimits: Equatable, Sendable {
    /// Open connections at once (including ones still sending their head).
    public var maxConnections = 32
    /// Uploads spooled to disk at once: the transcription queue's size (one running, eight waiting).
    public var maxUploads = 9
    /// Bytes reserved for spooled uploads at once (each reserves its Content-Length).
    public var maxUploadBytes: Int64 = 1024 * 1024 * 1024
    /// Free space an upload must leave on the volume, so recordings can still be written.
    public var freeSpaceReserve: Int64 = 2 * 1024 * 1024 * 1024
    /// Seconds from accept to a complete request head.
    public var headSeconds: Double = 10
    /// Seconds a body may go without a byte arriving.
    public var bodyIdleSeconds: Double = 30
    public init() {}
}

/// Reservation accounting for `APIUploadLimits`; not thread-safe (the listener uses it on its one queue).
public struct APIUploadBudget: Equatable {
    public let limits: APIUploadLimits
    public private(set) var connections = 0
    public private(set) var uploads = 0
    public private(set) var reservedBytes: Int64 = 0
    public init(_ limits: APIUploadLimits) { self.limits = limits }

    public mutating func openConnection() -> Bool {
        guard connections < limits.maxConnections else { return false }
        connections += 1; return true
    }
    public mutating func closeConnection() { connections = max(0, connections - 1) }
    /// Reserves `bytes` for an upload, or the refusal to send instead (nothing is reserved then). `freeBytes` is the
    /// volume's free space (nil when unknown, which refuses: the reserve cannot be verified).
    public mutating func reserveUpload(_ bytes: Int64, freeBytes: Int64?) -> APIError? {
        guard uploads < limits.maxUploads, reservedBytes + bytes <= limits.maxUploadBytes else {
            return APIError(429, "Vella is already receiving \(uploads) uploads; try again when they finish.")
        }
        guard let freeBytes, freeBytes - reservedBytes - bytes >= limits.freeSpaceReserve else {
            return APIError(507, "not enough free disk space to store the upload and keep room for recordings")
        }
        uploads += 1; reservedBytes += bytes
        return nil
    }
    public mutating func releaseUpload(_ bytes: Int64) {
        uploads = max(0, uploads - 1); reservedBytes = max(0, reservedBytes - bytes)
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
        } else {
            length = 0
        }
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
