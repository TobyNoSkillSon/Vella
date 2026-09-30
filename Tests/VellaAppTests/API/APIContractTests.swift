import Darwin
import Foundation
import XCTest
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// The public API contract (OpenAI SDKs and the agent skill depend on it) against Tests/Fixtures/api/contract.json:
/// the key sets and value types of `GET /status`, `GET /v1/models`, one model, the error envelope for 400/404/413/503/
/// 507, and every `response_format`, plus the exact text formats on the fake worker. `VELLA_RECORD_API=1` rewrites it.
final class APIContractTests: XCTestCase {
    static let root = Repository.root
    static let fixture = root.appendingPathComponent("Tests/Fixtures/api/contract.json")
    private var audio: URL!
    private var observed: [String: Any] = [:]

    override func setUpWithError() throws {
        audio = FileManager.default.temporaryDirectory.appendingPathComponent("vella-contract-\(UUID().uuidString).wav")
        try writeTestWAV(audio)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: audio) }

    /// A value's type skeleton: objects keep their keys, arrays the union of their elements' skeletons, leaves a type name.
    static func shape(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]: return object.mapValues(shape)
        case let array as [Any]:
            var merged: [String: Any] = [:]
            var leaves = Set<String>()
            for element in array {
                if let object = shape(element) as? [String: Any] { merged.merge(object) { a, _ in a } } else { leaves.insert("\(shape(element))") }
            }
            return merged.isEmpty ? leaves.sorted() : [merged]
        case is NSNull: return "null"
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        default: return "\(type(of: value))"
        }
    }

    func record(_ name: String, _ value: Any) { observed[name] = value }

    func compare() throws {
        let data = try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["VELLA_RECORD_API"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.fixture)
        }
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        for key in Set(expected.keys).union(observed.keys).sorted() {
            let a = observed[key].map { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) } ?? nil
            let e = expected[key].map { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) } ?? nil
            XCTAssertEqual(a.map { String(decoding: $0, as: UTF8.self) }, e.map { String(decoding: $0, as: UTF8.self) }, key)
        }
    }

    /// The whole response (head and body) for exact request bytes.
    nonisolated static func exchange(_ port: Int, _ request: Data) async -> (Int, Data) {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { return (-1, Data()) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // The server may refuse at the head and close while the body is still being sent: no SIGPIPE.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                response.append(contentsOf: buffer[0..<n])
            }
            guard let split = response.range(of: Data("\r\n\r\n".utf8)), response.count > 12 else { return (-2, response) }
            let code = Int(String(decoding: response[response.startIndex + 9..<response.startIndex + 12], as: UTF8.self)) ?? -3
            return (code, response[split.upperBound...])
        }.value
    }

    func errorShape(_ code: Int, _ data: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self), file: file, line: line)
        let error = object["error"] as? [String: Any] ?? [:]
        record(
            name,
            [
                "status": code, "shape": Self.shape(object), "type": error["type"] ?? NSNull(), "code": error["code"] ?? NSNull(),
                "param": error["param"] ?? NSNull()
            ])
    }

    @MainActor func testAPIContract() async throws {
        let api = try await APIFixture()
        defer { api.close() }

        let (_, idle) = try await api.get("/status")
        record("GET /status (idle)", Self.shape(try JSONSerialization.jsonObject(with: idle)))
        let (_, models) = try await api.get("/v1/models")
        record("GET /v1/models", Self.shape(try JSONSerialization.jsonObject(with: models)))
        let (_, one) = try await api.get("/v1/models/fake-b")
        record("GET /v1/models/{id}", Self.shape(try JSONSerialization.jsonObject(with: one)))

        for format in ["json", "verbose_json", "text", "srt", "vtt"] {
            let (code, type, data) = try await api.post(fields: ["model": "fake-a", "response_format": format], file: audio)
            XCTAssertEqual(code, 200, String(decoding: data, as: UTF8.self))
            if format.hasSuffix("json") {
                record("POST transcriptions \(format)", ["contentType": type, "shape": Self.shape(try JSONSerialization.jsonObject(with: data))])
            } else {
                record("POST transcriptions \(format)", ["contentType": type, "body": String(decoding: data, as: UTF8.self)])
            }
        }
        let (_, loaded) = try await api.get("/status")
        record("GET /status (model loaded)", Self.shape(try JSONSerialization.jsonObject(with: loaded)))

        let (badFormat, _, badFormatData) = try await api.post(fields: ["response_format": "mp3"], file: audio)
        try errorShape(badFormat, badFormatData, "error 400 response_format")
        let (missing, missingData) = try await api.get("/v1/models/nope")
        try errorShape(missing, missingData, "error 404 model_not_found")
        let (badModel, _, badModelData) = try await api.post(fields: ["model": "nope"], file: audio)
        try errorShape(badModel, badModelData, "error 404 transcription model")
        // Refused from the head alone (Content-Length), before any body byte is read.
        let (tooLarge, tooLargeData) = await Self.exchange(
            api.port,
            Data(
                "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(api.port)\r\nContent-Type: application/json\r\nContent-Length: \(apiMaxJSONBytes + 1)\r\n\r\n".utf8))
        try errorShape(tooLarge, tooLargeData, "error 413 json body")

        // 503: a listener that is out of connections refuses before reading anything.
        let full = try APIServer(
            uploads: api.root.appendingPathComponent("full-uploads"), handler: api.service,
            limits: {
                var l = APIUploadLimits(); l.maxConnections = 0; return l
            }())
        let fullPort: Int = await withCheckedContinuation { continuation in full.start { continuation.resume(returning: $0 ?? 0) } }
        defer { full.stop() }
        let (busy, busyData) = await Self.exchange(fullPort, Data("GET /status HTTP/1.1\r\nHost: 127.0.0.1:\(fullPort)\r\n\r\n".utf8))
        try errorShape(busy, busyData, "error 503 connections")

        // 507: an API load that would need the dictation model evicted.
        let segment = api.root.appendingPathComponent("d.wav"); try APITests.monoWAV(segment, seconds: 1)
        _ = try await api.backend.transcribe(segment, config: Configuration(model: api.models.list[0].path))
        try api.runtime.setAvailableMB(1_600)
        let (memory, _, memoryData) = try await api.post(fields: ["model": "fake-b"], file: audio)
        try errorShape(memory, memoryData, "error 507 insufficient_memory")

        try compare()
    }

    /// The `vella` command refuses an app that speaks a newer API version than it knows.
    @MainActor func testCLIRefusesANewerAPI() async throws {
        try Integration.require()
        final class Newer: APIHandling {
            func handle(_ request: APIRequest) async -> APIResponse { .json(200, ["api": vellaAPIVersion + 1, "app": "Vella"]) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-newer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = Newer()
        let server = try APIServer(uploads: root.appendingPathComponent("uploads"), handler: handler)
        let port: Int = await withCheckedContinuation { continuation in server.start { continuation.resume(returning: $0 ?? 0) } }
        defer { server.stop() }
        var status = WorkerStatus()
        status.api = vellaAPIVersion + 1; status.api_port = port; status.app_pid = getpid()
        try JSONEncoder().encode(status).write(to: root.appendingPathComponent("worker-status.json"))
        let env = ["VELLA_SUPPORT_DIR": root.path, "VELLA_NO_LAUNCH": "1", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let (code, _, err) = try await APIClientTests.run(APIClientTests.cli, ["status"], environment: env)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(err.contains("this vella command knows API \(vellaAPIVersion) but the app speaks API \(vellaAPIVersion + 1); reinstall Vella"), err)
        withExtendedLifetime(handler) {}
    }
}
