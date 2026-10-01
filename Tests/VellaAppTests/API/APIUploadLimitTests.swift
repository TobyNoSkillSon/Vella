import XCTest
import Darwin
@testable import Vella
@testable import VellaCore

/// Unfinished uploads are bounded before the job queue sees them: a slot and the bytes are reserved before any body
/// is spooled, the disk keeps room for recordings, stalled clients are disconnected, and every exit returns its
/// reservation and removes its file. Loopback only; every test sends a few kilobytes.
final class APIUploadLimitTests: XCTestCase {
    @MainActor private final class Handler: APIHandling {
        var handled = 0
        var delay = false
        var cancelled = false
        func handle(_ request: APIRequest) async -> APIResponse {
            handled += 1
            if delay {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch {
                    cancelled = true; return .json(499, ["cancelled": true])
                }
            }
            return .json(200, ["ok": true])
        }
    }

    @MainActor func testWriteHalfCloseDoesNotCancelACompleteLongRequest() async throws {
        let (server, port, handler) = try await server(APIUploadLimits())
        defer { server.stop() }
        handler.delay = true
        let fd = try open(port, "GET /status HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        XCTAssertEqual(shutdown(fd, SHUT_WR), 0, "client finished writing but is still reading the response")
        var result: Int?
        try await waitUntil {
            result = self.status(fd); return result != nil
        }
        XCTAssertEqual(result, 200)
        XCTAssertFalse(handler.cancelled)
        XCTAssertEqual(handler.handled, 1)
    }

    @MainActor func testTCPResetStillCancelsTheHandlingTask() async throws {
        let (server, port, handler) = try await server(APIUploadLimits())
        defer { server.stop() }
        handler.delay = true
        let fd = try open(port, "GET /status HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        try await waitUntil { handler.handled == 1 }
        var reset = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)), 0)
        close(fd)
        try await waitUntil { handler.cancelled }
    }
    private var root: URL!
    private var sockets: [Int32] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-upload-limits-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for fd in sockets { Darwin.close(fd) }
        sockets = []
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor private func server(_ limits: APIUploadLimits, free: Int64? = 1 << 40) async throws -> (APIServer, Int, Handler) {
        let handler = Handler()
        let server = try APIServer(uploads: root.appendingPathComponent("uploads"), handler: handler, limits: limits)
        server.freeBytes = { _ in free }
        let port: Int = await withCheckedContinuation { c in server.start { c.resume(returning: $0 ?? 0) } }
        XCTAssertGreaterThan(port, 0)
        return (server, port, handler)
    }
    private var uploadFiles: Int { ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("uploads").path)) ?? []).count }

    /// Opens a connection and sends `text`; the socket stays open until the test closes it.
    private func open(_ port: Int, _ text: String) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        sockets.append(fd)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(connected, 0)
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = text.withCString { send(fd, $0, strlen($0), 0) }
        return fd
    }
    /// The response status the server sent on `fd` (nil while it is still waiting for the body); 0 when it closed.
    private func status(_ fd: Int32) -> Int? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buffer, buffer.count, 0)
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
        if n <= 0 { return 0 }
        guard n > 12 else { return nil }
        return Int(String(decoding: buffer[9..<12], as: UTF8.self))
    }
    private func close(_ fd: Int32) { Darwin.close(fd); sockets.removeAll { $0 == fd } }
    private func stalledUpload(_ port: Int, length: Int = 1024) -> String {
        "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: multipart/form-data; boundary=x\r\nContent-Length: \(length)\r\n\r\n--x\r\n"
    }
    /// Evaluates `condition` once per poll (a status read consumes the response), failing after 5 s.
    @MainActor private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not reached within 5 s", line: line)
    }

    @MainActor func testStalledUploadsAreLimitedToTheQueueSize() async throws {
        let (server, port, handler) = try await server(APIUploadLimits()); defer { server.stop() }
        let fds = try (0..<12).map { _ in try open(port, stalledUpload(port)) }
        try await waitUntil { server.usage().uploads == 9 && self.uploadFiles == 9 }
        let refused = fds.compactMap { status($0) }
        XCTAssertEqual(refused.filter { $0 == 429 }.count, 3, "the uploads past the queue's nine are refused: \(refused)")
        XCTAssertEqual(uploadFiles, 9)
        XCTAssertEqual(handler.handled, 0)
        for fd in fds { close(fd) }
        try await waitUntil { self.uploadFiles == 0 && server.usage() == (0, 0, 0) }
    }

    @MainActor func testUploadBytesAreBoundedInTotal() async throws {
        var limits = APIUploadLimits(); limits.maxUploadBytes = 2500
        let (server, port, _) = try await server(limits); defer { server.stop() }
        let first = try open(port, stalledUpload(port)), second = try open(port, stalledUpload(port))
        try await waitUntil { server.usage().bytes == 2048 }
        let third = try open(port, stalledUpload(port))
        try await waitUntil { self.status(third) == 429 }
        XCTAssertEqual(server.usage().uploads, 2)
        close(first); close(second)
        try await waitUntil { server.usage().bytes == 0 && self.uploadFiles == 0 }
    }

    @MainActor func testUploadMustLeaveTheFreeSpaceReserve() async throws {
        var limits = APIUploadLimits(); limits.freeSpaceReserve = 10_000
        let (server, port, _) = try await server(limits, free: 10_500); defer { server.stop() }
        let fd = try open(port, stalledUpload(port, length: 1024))
        try await waitUntil { self.status(fd) == 507 }
        XCTAssertEqual(uploadFiles, 0)
        XCTAssertEqual(server.usage().uploads, 0)
        server.freeBytes = { _ in nil }
        let unknown = try open(port, stalledUpload(port, length: 1024))
        try await waitUntil { self.status(unknown) == 507 }
    }

    @MainActor func testStalledClientsAreDisconnectedAndTheirFilesRemoved() async throws {
        var limits = APIUploadLimits(); limits.headSeconds = 0.3; limits.bodyIdleSeconds = 0.3
        let (server, port, _) = try await server(limits); defer { server.stop() }
        let body = try open(port, stalledUpload(port))
        let head = try open(port, "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1")
        try await waitUntil { self.uploadFiles == 1 }
        try await waitUntil { self.uploadFiles == 0 && server.usage() == (0, 0, 0) }
        XCTAssertEqual(status(body), 0, "the server closed the stalled body")
        XCTAssertEqual(status(head), 0, "the server closed the stalled head")
    }

    @MainActor func testConnectionsAreBounded() async throws {
        var limits = APIUploadLimits(); limits.maxConnections = 3
        let (server, port, _) = try await server(limits); defer { server.stop() }
        let held = try (0..<3).map { _ in try open(port, "GET /status HTTP/1.1\r\n") }
        try await waitUntil { server.usage().connections == 3 }
        let extra = try open(port, "")
        try await waitUntil { self.status(extra) == 503 }
        for fd in held { close(fd) }
        try await waitUntil { server.usage().connections == 0 }
    }

    @MainActor func testCompleteUploadStillReachesTheHandlerAndReleasesItsReservation() async throws {
        let (server, port, handler) = try await server(APIUploadLimits()); defer { server.stop() }
        let body = "--x\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--x--\r\n"
        let fd = try open(
            port,
            "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: multipart/form-data; boundary=x\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                + body)
        try await waitUntil { self.status(fd) == 200 }
        XCTAssertEqual(handler.handled, 1)
        try await waitUntil { self.uploadFiles == 0 && server.usage().uploads == 0 && server.usage().bytes == 0 }
    }
}
