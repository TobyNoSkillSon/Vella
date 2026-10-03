import Foundation
import Network
import OSLog
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

/// Carries the transport cancellation reason into the handler's download cancellation callback.
final class APIJobCancellation: @unchecked Sendable {
    @TaskLocal static var current: APIJobCancellation?
    private let lock = NSLock()
    private var reason = "request task"
    private var finished = false
    var source: String { lock.withLock { reason } }
    /// Records why the request is being cancelled; false once its handler has returned (nothing left to cancel).
    func mark(_ source: String) -> Bool { lock.withLock { if finished { return false }; reason = source; return true } }
    func finish() { lock.withLock { finished = true } }
}

/// The loopback HTTP listener, hosted in the app process (the inference workers stay offline). IPv4 loopback only,
/// ephemeral port. Each request's head is checked (`APIRequestCheck.refusal`) before any body byte is read, and the
/// handler sees only fully received, validated requests. One request per connection (`Connection: close`).
/// Open connections, spooled uploads, their bytes and the disk they leave free are bounded (`APIUploadLimits`), and a
/// client that stalls in its head or body is disconnected, so unfinished requests cannot pile up before the queue.
final class APIServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vella.api")
    private let uploads: URL
    private weak var handler: APIHandling?
    /// The bound port, for the Host check; set and read only on `queue`.
    private var port = 0
    /// Reservations of open connections and spooled uploads; used only on `queue`.
    private var budget: APIUploadBudget
    /// Handling tasks by connection, touched only on `queue`. EOF cancels the request.
    private struct Job {
        let task: Task<APIResponse, Never>
        let origin: APIJobCancellation
        let path: String
        func cancel(_ source: String) {
            // A client closing after its response arrived is not a cancellation.
            guard !task.isCancelled, origin.mark(source) else { return }
            Logger(subsystem: "dev.vella.dictation", category: "download").notice("API request \(path, privacy: .public) cancelled: \(source, privacy: .public)")
            task.cancel()
        }
    }
    private var jobs: [ObjectIdentifier: Job] = [:]
    /// Free space on the uploads volume (tests inject a value).
    var freeBytes: (URL) -> Int64? = { freeDiskBytes(at: $0) }

    init(uploads: URL, handler: APIHandling, port requested: UInt16 = 0, limits: APIUploadLimits = APIUploadLimits()) throws {
        self.uploads = uploads; self.handler = handler
        budget = APIUploadBudget(limits)
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
            guard self.budget.openConnection() else {
                self.send(connection, .error(APIError(503, "Vella has too many open API connections; try again shortly."))); return
            }
            let watchdog = Watchdog(connection, queue: self.queue)
            var open = true
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed:
                    self?.jobs[ObjectIdentifier(connection)]?.cancel("client transport failure")
                    connection.cancel()
                case .cancelled:
                    self?.jobs[ObjectIdentifier(connection)]?.cancel("client connection cancelled")
                    watchdog.disarm()
                    if open { open = false; self?.budget.closeConnection() }
                    connection.stateUpdateHandler = nil
                default: break
                }
            }
            watchdog.arm(self.budget.limits.headSeconds)
            self.readHead(connection, Data(), watchdog)
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
    /// Current reservations (for tests and diagnostics).
    func usage() -> (connections: Int, uploads: Int, bytes: Int64) {
        queue.sync { (budget.connections, budget.uploads, budget.reservedBytes) }
    }

    /// Disconnects a client that sends nothing for a while; re-armed as bytes arrive, disarmed once the request is in.
    private final class Watchdog {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private var item: DispatchWorkItem?
        init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
        func arm(_ seconds: Double) {
            item?.cancel()
            let item = DispatchWorkItem { [connection] in connection.cancel() }
            self.item = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
        func disarm() { item?.cancel(); item = nil }
    }
    /// Returns an upload's reservation exactly once, whichever way the request ends.
    private final class Reservation {
        private var release: (() -> Void)?
        init(_ release: @escaping () -> Void) { self.release = release }
        func end() { let action = release; release = nil; action?() }
    }

    // MARK: Connection

    private func readHead(_ connection: NWConnection, _ buffer: Data, _ watchdog: Watchdog) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in
            var data = buffer; if let chunk { data.append(chunk) }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || done { connection.cancel(); return }
                if data.count > apiMaxHeadBytes { send(connection, .error(APIError(431, "request headers are too large"))); return }
                readHead(connection, data, watchdog); return
            }
            watchdog.arm(budget.limits.bodyIdleSeconds)
            guard end.lowerBound <= apiMaxHeadBytes else { send(connection, .error(APIError(431, "request headers are too large"))); return }
            guard let head = HTTPHead.parse(data[..<end.lowerBound]) else { send(connection, .error(APIError(400, "malformed HTTP request"))); return }
            // Checked before waiting for the body: nothing is read, stored or run for a refused request.
            if let refusal = APIRequestCheck.refusal(head, port: port) { send(connection, .error(refusal)); return }
            let length = APIRequestCheck.contentLength(head)
            let early = data.subdata(in: end.upperBound..<data.count)
            guard early.count <= length else { send(connection, .error(APIError(400, "body longer than Content-Length"))); return }
            if length == 0 { watchdog.disarm(); dispatch(connection, APIRequest(head: head, body: .none)); return }
            let inMemory = head.mediaType == "application/json"
            // An upload reserves its slot, its bytes and free disk before a byte is written (and before 100 Continue).
            var reservation: Reservation?
            if !inMemory {
                if let refusal = budget.reserveUpload(Int64(length), freeBytes: freeBytes(uploads)) { send(connection, .error(refusal)); return }
                reservation = Reservation { [weak self] in self?.queue.async { self?.budget.releaseUpload(Int64(length)) } }
            }
            let proceed = { [self] in
                if let reservation { spool(connection, head, early, length, watchdog, reservation) } else { readMemory(connection, head, early, length, watchdog) }
            }
            if head.headers["expect"]?.lowercased() == "100-continue", early.count < length {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in proceed() })
            } else {
                proceed()
            }
        }
    }

    private func readMemory(_ connection: NWConnection, _ head: HTTPHead, _ buffer: Data, _ length: Int, _ watchdog: Watchdog) {
        if buffer.count >= length { watchdog.disarm(); dispatch(connection, APIRequest(head: head, body: .memory(buffer.prefix(length)))); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in
            var data = buffer; if let chunk { data.append(chunk); watchdog.arm(budget.limits.bodyIdleSeconds) }
            if data.count > length { send(connection, .error(APIError(400, "body longer than Content-Length"))); return }
            if data.count < length, error != nil || done { connection.cancel(); return }
            readMemory(connection, head, data, length, watchdog)
        }
    }

    /// Uploads go to a private file as they arrive, so a 200 MB body never sits in memory.
    private func spool(_ connection: NWConnection, _ head: HTTPHead, _ early: Data, _ length: Int, _ watchdog: Watchdog, _ reservation: Reservation) {
        let url = uploads.appendingPathComponent(UUID().uuidString + ".body")
        do {
            try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: early)
            receiveBody(connection, head, handle, url, early.count, length, watchdog, reservation)
        } catch {
            try? FileManager.default.removeItem(at: url)
            reservation.end()
            send(connection, .error(APIError(507, "Vella could not store the upload: \(error.localizedDescription)")))
        }
    }
    private func receiveBody(
        _ connection: NWConnection, _ head: HTTPHead, _ handle: FileHandle, _ url: URL, _ received: Int, _ length: Int,
        _ watchdog: Watchdog, _ reservation: Reservation
    ) {
        if received >= length {
            try? handle.close()
            watchdog.disarm()
            dispatch(connection, APIRequest(head: head, body: .file(url)), cleanup: url, reservation: reservation); return
        }
        // Every way out removes the partial file and returns its reservation.
        func abandon(_ response: APIResponse?) {
            try? handle.close(); try? FileManager.default.removeItem(at: url); reservation.end()
            if let response { send(connection, response) } else { connection.cancel() }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] chunk, _, done, error in
            var total = received
            if let chunk {
                total += chunk.count
                if total > length { abandon(.error(APIError(400, "body longer than Content-Length"))); return }
                do { try handle.write(contentsOf: chunk) } catch { abandon(.error(APIError(507, "Vella could not store the upload"))); return }
                watchdog.arm(budget.limits.bodyIdleSeconds)
            }
            if total < length, error != nil || done { abandon(nil); return }
            receiveBody(connection, head, handle, url, total, length, watchdog, reservation)
        }
    }

    // MARK: Handling

    private func dispatch(_ connection: NWConnection, _ request: APIRequest, cleanup: URL? = nil, reservation: Reservation? = nil) {
        let origin = APIJobCancellation()
        let task = Task { @MainActor [weak handler] () -> APIResponse in
            await APIJobCancellation.$current.withValue(origin) {
                guard let handler else { return .error(APIError(503, "Vella is shutting down")) }
                return await handler.handle(request)
            }
        }
        let job = Job(task: task, origin: origin, path: request.head.path)
        jobs[ObjectIdentifier(connection)] = job
        // A client EOF cancels its job: stop transcription and remove unfinished downloads/uploads.
        watchDisconnect(connection, job)
        Task {
            let response = await job.task.value
            origin.finish()
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            reservation?.end()
            queue.async { [self] in
                jobs.removeValue(forKey: ObjectIdentifier(connection))
                send(connection, response)
            }
        }
    }
    private func watchDisconnect(_ connection: NWConnection, _ job: Job) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            if done || error != nil { job.cancel(done ? "client EOF" : "client transport failure"); return }
            self?.watchDisconnect(connection, job) // bytes after the body are ignored
        }
    }

    static let reasons = [
        200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        409: "Conflict", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type",
        429: "Too Many Requests", 431: "Request Header Fields Too Large", 499: "Client Closed Request",
        500: "Internal Server Error", 503: "Service Unavailable", 507: "Insufficient Storage"
    ]
    private func send(_ connection: NWConnection, _ response: APIResponse) {
        let reason = Self.reasons[response.status] ?? "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}
