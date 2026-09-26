import Foundation
import Network
import VellaCore

/// One validated request: its head and body (none, small JSON in memory, or an upload spooled to a file).
struct APIRequest {
    enum Body { case none, memory(Data), file(URL) }
    var head: HTTPHead
    var body: Body
}

struct APIResponse {
    var status: Int
    var contentType: String
    var body: Data
    static func json(_ status: Int, _ object: Any) -> APIResponse {
        APIResponse(status: status, contentType: "application/json", body: TranscriptFormatter.jsonData(object))
    }
    static func error(_ error: APIError) -> APIResponse { json(error.status, error.json) }
}

@MainActor protocol APIHandling: AnyObject {
    func handle(_ request: APIRequest) async -> APIResponse
}

/// The loopback HTTP listener, hosted in the app process (the inference workers stay offline). IPv4 loopback only,
/// ephemeral port. Each request's head is checked (`APIRequestCheck.refusal`) before any body byte is read, and the
/// handler sees only fully received, validated requests. One request per connection (`Connection: close`).
final class APIServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vella.api")
    private let uploads: URL
    private weak var handler: APIHandling?
    private(set) var port = 0

    init(uploads: URL, handler: APIHandling, port requested: UInt16 = 0) throws {
        self.uploads = uploads; self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; `ready` runs on the main actor with the bound port (nil when the listener failed).
    func start(ready: @escaping @MainActor (Int?) -> Void) {
        try? FileManager.default.removeItem(at: uploads) // spooled bodies of an earlier launch
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.readHead(connection, Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = Int(self?.listener.port?.rawValue ?? 0)
                self?.port = port
                Task { @MainActor in ready(port) }
            case .failed:
                Task { @MainActor in ready(nil) }
            default: break
            }
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }

    // MARK: Connection

    private func readHead(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in
            var data = buffer; if let chunk { data.append(chunk) }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || done { connection.cancel(); return }
                if data.count > apiMaxHeadBytes { send(connection, .error(APIError(431, "request headers are too large"))); return }
                readHead(connection, data); return
            }
            guard end.lowerBound <= apiMaxHeadBytes else { send(connection, .error(APIError(431, "request headers are too large"))); return }
            guard let head = HTTPHead.parse(data[..<end.lowerBound]) else { send(connection, .error(APIError(400, "malformed HTTP request"))); return }
            // Checked before waiting for the body: nothing is read, stored or run for a refused request.
            if let refusal = APIRequestCheck.refusal(head, port: port) { send(connection, .error(refusal)); return }
            let length = APIRequestCheck.contentLength(head)
            let early = data.subdata(in: end.upperBound..<data.count)
            guard early.count <= length else { send(connection, .error(APIError(400, "body longer than Content-Length"))); return }
            let proceed = { [self] in
                if length == 0 { dispatch(connection, APIRequest(head: head, body: .none)); return }
                if head.mediaType == "application/json" { readMemory(connection, head, early, length); return }
                spool(connection, head, early, length)
            }
            if head.headers["expect"]?.lowercased() == "100-continue", early.count < length {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in proceed() })
            } else { proceed() }
        }
    }

    private func readMemory(_ connection: NWConnection, _ head: HTTPHead, _ buffer: Data, _ length: Int) {
        if buffer.count >= length { dispatch(connection, APIRequest(head: head, body: .memory(buffer.prefix(length)))); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in
            var data = buffer; if let chunk { data.append(chunk) }
            if data.count > length { send(connection, .error(APIError(400, "body longer than Content-Length"))); return }
            if data.count < length, error != nil || done { connection.cancel(); return }
            readMemory(connection, head, data, length)
        }
    }

    /// Uploads go to a private file as they arrive, so a 200 MB body never sits in memory.
    private func spool(_ connection: NWConnection, _ head: HTTPHead, _ early: Data, _ length: Int) {
        let url = uploads.appendingPathComponent(UUID().uuidString + ".body")
        do {
            try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: early)
            receiveBody(connection, head, handle, url, early.count, length)
        } catch {
            try? FileManager.default.removeItem(at: url)
            send(connection, .error(APIError(507, "Vella could not store the upload: \(error.localizedDescription)")))
        }
    }
    private func receiveBody(_ connection: NWConnection, _ head: HTTPHead, _ handle: FileHandle, _ url: URL, _ received: Int, _ length: Int) {
        if received >= length {
            try? handle.close()
            dispatch(connection, APIRequest(head: head, body: .file(url)), cleanup: url); return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] chunk, _, done, error in
            var total = received
            if let chunk {
                total += chunk.count
                if total > length { try? handle.close(); try? FileManager.default.removeItem(at: url); send(connection, .error(APIError(400, "body longer than Content-Length"))); return }
                do { try handle.write(contentsOf: chunk) }
                catch { try? handle.close(); try? FileManager.default.removeItem(at: url); send(connection, .error(APIError(507, "Vella could not store the upload"))); return }
            }
            if total < length, error != nil || done { try? handle.close(); try? FileManager.default.removeItem(at: url); connection.cancel(); return }
            receiveBody(connection, head, handle, url, total, length)
        }
    }

    // MARK: Handling

    private func dispatch(_ connection: NWConnection, _ request: APIRequest, cleanup: URL? = nil) {
        let job = Task { @MainActor [weak handler] () -> APIResponse in
            guard let handler else { return .error(APIError(503, "Vella is shutting down")) }
            return await handler.handle(request)
        }
        // A client that disconnects cancels its job (a transcription stops between segments; its files are removed).
        watchDisconnect(connection, job)
        Task {
            let response = await job.value
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            send(connection, response)
        }
    }
    private func watchDisconnect(_ connection: NWConnection, _ job: Task<APIResponse, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            if done || error != nil { job.cancel(); return }
            self?.watchDisconnect(connection, job) // bytes after the body are ignored
        }
    }

    static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                          409: "Conflict", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type",
                          429: "Too Many Requests", 431: "Request Header Fields Too Large", 499: "Client Closed Request",
                          500: "Internal Server Error", 503: "Service Unavailable", 507: "Insufficient Storage"]
    private func send(_ connection: NWConnection, _ response: APIResponse) {
        let reason = Self.reasons[response.status] ?? "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}
