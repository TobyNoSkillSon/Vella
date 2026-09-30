import XCTest
import Foundation
import AVFoundation
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// A worker stand-in for API tests: like FakeWorker, but the text names the segment's length (so timing is checkable),
/// `slow` model folders take 0.3 s per request, and every request is logged (start/end, model) for ordering checks.
enum APIFakeWorker {
    static let script = #"""
#!/usr/bin/env python3
import json,sys,os,time
model=None
log=os.environ.get('FAKE_LOG')
def push(event):
    st={'worker':'dictation','pid':os.getpid(),'event':event,'model':model,'engine':'mlx','engine_reason':None,
        'optimizations':{},'load_s':0.01,'memory':{'footprint_mb':1000.0 if model else 50.0},'gpu':{'chip':'Fake M','family':'apple9'}}
    print(json.dumps({'status':st}),flush=True)
def note(kind, name):
    if log:
        with open(log,'a') as f: f.write('%s %s %.4f\n'%(kind,name,time.time()))
for line in sys.stdin:
    r=json.loads(line); op=r.get('op')
    if op=='load':
        model=r['model']; push('load'); print(json.dumps({'id':r['id'],'loaded':True}),flush=True); continue
    if op in ('unload','status','trim'):
        if op=='unload': model=None
        push(op); print(json.dumps({'id':r['id'],'ok':True}),flush=True); continue
    name=r['model'].split('/')[-1]
    note('start',name)
    if 'slow' in name: time.sleep(0.3)
    frames=(os.path.getsize(r['audio'])-44)//2
    note('end',name)
    print(json.dumps({'id':r['id'],'text':'%s heard %.2f s.'%(name,frames/16000.0),'metrics':{}}),flush=True)
"""#
}

@MainActor final class StubModels: APIModelSource {
    var list: [APIModel]
    init(_ list: [APIModel]) { self.list = list }
    func models() -> [APIModel] { list }
    func unavailableReason(_ id: String) -> String? {
        id == "stream-x" ? "Stream X is a Streaming model; the API transcribes files with Dictation models (see GET /v1/models)." : nil
    }
    func prepare(_ model: APIModel) throws -> APIModel { model }
}

/// One isolated API: temp support dir, isolated runtime, fake worker, real listener on an ephemeral loopback port.
@MainActor final class APIFixture {
    let root: URL
    let runtime: Runtime
    let backend: Backend
    let transcriber: APITranscriber
    let service: APIService
    let server: APIServer
    let models: StubModels
    var port = 0
    let log: URL
    var dictationActive = false

    /// `helper`/`modelPaths`: a real VellaWorker and real model folders (opt-in smokes) instead of the fake.
    init(availableMB: Double = 100_000, models names: [String] = ["fake-a", "fake-b"], helper realHelper: URL? = nil, modelPaths: [String] = []) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = root.appendingPathComponent("requests.log")
        setenv("FAKE_LOG", log.path, 1)
        runtime = try Runtime.isolated(root, availableMB: availableMB)
        let helper = realHelper ?? root.appendingPathComponent("api-fake-worker.py")
        if realHelper == nil {
            try APIFakeWorker.script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        backend = Backend(helper: helper, requestTimeout: realHelper == nil ? 10 : 3600, runtime: runtime)
        runtime.dictation = backend
        runtime.resolver = { path, mode in
            let id = URL(fileURLWithPath: path).lastPathComponent
            return ModelRef(id: id, precision: "8b", path: path, mode: mode, name: id, memoryMB: 1000, precisionOptions: ["8b"])
        }
        var list: [APIModel] = []
        for (i, name) in names.enumerated() {
            let folder = root.appendingPathComponent("models/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            list.append(APIModel(id: name, name: name.uppercased(), precision: "8b", path: folder.path, languages: ["en"], current: i == 0))
        }
        for (i, path) in modelPaths.enumerated() {
            let id = URL(fileURLWithPath: path).lastPathComponent
            list.append(APIModel(id: id, name: id, precision: "", path: path, current: list.isEmpty && i == 0))
        }
        models = StubModels(list)
        let api = runtime.support.appendingPathComponent("API")
        transcriber = APITranscriber(backend: backend, root: api.appendingPathComponent("jobs"))
        transcriber.pollNanoseconds = 5_000_000
        service = APIService(transcriber: transcriber, models: models, scratch: api.appendingPathComponent("files"), version: "test")
        server = try APIServer(uploads: api.appendingPathComponent("uploads"), handler: service)
        transcriber.dictationActive = { [unowned self] in self.dictationActive }
        let runtime = self.runtime
        runtime.apiToken = "test-token"
        port = await withCheckedContinuation { continuation in
            server.start { port in runtime.apiPort = port; continuation.resume(returning: port ?? 0) }
        }
    }
    func close() { server.stop(); backend.shutdown(); try? FileManager.default.removeItem(at: root) }
    var base: String { "http://127.0.0.1:\(port)" }
    /// Everything the API may leave behind: spooled uploads, copied files, job directories.
    func leftovers() -> [String] {
        let api = runtime.support.appendingPathComponent("API")
        return ["uploads", "files", "jobs"].flatMap { sub in
            ((try? FileManager.default.contentsOfDirectory(atPath: api.appendingPathComponent(sub).path)) ?? []).map { "\(sub)/\($0)" }
        }
    }
    func requests() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    // MARK: Clients

    func get(_ path: String) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
        return ((response as! HTTPURLResponse).statusCode, data)
    }
    func post(fields: [String: String], file: URL?, filename: String? = nil, extra: [(String, String)] = []) async throws -> (Int, String, Data) {
        let boundary = "vella-test-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8)
        }
        for (k, v) in extra { body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
        if let file {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename ?? file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            body += try Data(contentsOf: file) + Data("\r\n".utf8)
        }
        body += Data("--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: URL(string: base + "/v1/audio/transcriptions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer sk-local", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", data)
    }
    /// Exact bytes on a socket (URLSession normalizes Host and merges repeated headers). Returns the status code.
    nonisolated static func raw(_ port: Int, _ request: String) async -> Int {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { return -1 }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 12 else { return -2 }
            return Int(String(decoding: buffer[9..<12], as: UTF8.self)) ?? -3
        }.value
    }
}

/// Speech-like test audio: 44.1 kHz stereo 16-bit (resampling and downmix are exercised): tone bursts separated by
/// silences, so the app's segmentation cuts at the pauses.
func writeTestWAV(_ url: URL, bursts: [Double] = [6, 7, 4], gap: Double = 0.8, rate: Double = 44_100) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    for burst in bursts {
        for (seconds, loud) in [(burst, true), (gap, false)] {
            let frames = AVAudioFrameCount(seconds * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = loud ? Float(0.3 * sin(Double(i) * 2 * .pi * 220 / rate)) : 0 } }
            try file.write(from: buffer)
        }
    }
}

final class APITests: XCTestCase {
    private var audio: URL!
    override func setUpWithError() throws {
        audio = FileManager.default.temporaryDirectory.appendingPathComponent("vella-api-\(UUID().uuidString).wav")
        try writeTestWAV(audio)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: audio) }

    @MainActor func testStatusAndModelsRoutes() async throws {
        let api = try await APIFixture()
        defer { api.close() }
        let (code, data) = try await api.get("/status")
        XCTAssertEqual(code, 200)
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(status["api"] as? Int, 1)
        XCTAssertEqual(status["port"] as? Int, api.port)
        XCTAssertEqual(status["dictation"] as? String, "idle")
        XCTAssertEqual((status["dictation_model"] as? [String: Any])?["id"] as? String, "fake-a")
        let file = try XCTUnwrap(WorkerStatus.read(api.runtime.statusURL))
        XCTAssertEqual(file.api, 1); XCTAssertEqual(file.api_port, api.port); XCTAssertEqual(file.app_pid, getpid())
        XCTAssertEqual(file.api_token, "test-token")
        XCTAssertNil(status["api_token"], "the token is in the file only, never served")

        let (listCode, listData) = try await api.get("/v1/models")
        XCTAssertEqual(listCode, 200)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: listData) as? [String: Any])
        XCTAssertEqual(list["object"] as? String, "list")
        XCTAssertEqual((list["data"] as? [[String: Any]])?.map { $0["id"] as? String }, ["fake-a", "fake-b"])
        XCTAssertEqual((list["data"] as? [[String: Any]])?.first?["object"] as? String, "model")
        let (one, oneData) = try await api.get("/v1/models/fake-b")
        XCTAssertEqual(one, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: oneData) as? [String: Any])?["id"] as? String, "fake-b")
        let (missing, missingData) = try await api.get("/v1/models/nope")
        XCTAssertEqual(missing, 404)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: missingData) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "model_not_found")
        XCTAssertTrue(api.runtime.status.models.isEmpty, "listing loads nothing")
    }

    @MainActor func testTranscribeEveryFormatThenCleanUp() async throws {
        let api = try await APIFixture()
        defer { api.close() }
        let recordings = api.runtime.support.appendingPathComponent("Recordings")
        let (code, type, data) = try await api.post(fields: ["model": "whisper-1"], file: audio)
        XCTAssertEqual(code, 200, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(type, "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try XCTUnwrap(json["text"] as? String)
        XCTAssertTrue(text.hasPrefix("fake-a heard "), text)
        XCTAssertEqual((json["usage"] as? [String: Any])?["seconds"] as? Int, 20) // 17 s tone + 2.4 s gaps = 19.4 s
        XCTAssertEqual(api.runtime.status.models["fake-a"]?.residency, "on_demand", "an API request is an on-demand load")

        let (vCode, _, vData) = try await api.post(fields: ["model": "fake-b", "response_format": "verbose_json", "language": "en"], file: audio,
                                                    extra: [("timestamp_granularities[]", "segment")])
        XCTAssertEqual(vCode, 200)
        let verbose = try XCTUnwrap(JSONSerialization.jsonObject(with: vData) as? [String: Any])
        let segments = try XCTUnwrap(verbose["segments"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(segments.count, 2, "cut at the pauses")
        XCTAssertEqual(segments.first?["start"] as? Double, 0)
        XCTAssertEqual(try XCTUnwrap(segments.last?["end"] as? Double), try XCTUnwrap(verbose["duration"] as? Double), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(verbose["duration"] as? Double), 19.4, accuracy: 0.01)
        XCTAssertEqual(verbose["language"] as? String, "en")
        for pair in zip(segments, segments.dropFirst()) { XCTAssertEqual(pair.0["end"] as? Double, pair.1["start"] as? Double) }
        // Each segment's text names the audio its worker request carried (≤ 25 s, 16 kHz mono).
        for segment in segments {
            let heard = Double((segment["text"] as! String).components(separatedBy: " ")[2])!
            XCTAssertLessThanOrEqual(heard, 25.0)
            XCTAssertEqual(heard, (segment["end"] as! Double) - (segment["start"] as! Double), accuracy: 0.6)
        }

        for (format, check) in [("text", "fake-a heard"), ("srt", "1\n00:00:00,000 --> "), ("vtt", "WEBVTT\n\n00:00:00.000 --> ")] {
            let (fCode, fType, fData) = try await api.post(fields: ["response_format": format], file: audio)
            XCTAssertEqual(fCode, 200); XCTAssertEqual(fType, "text/plain; charset=utf-8")
            XCTAssertTrue(String(decoding: fData, as: UTF8.self).hasPrefix(check), format)
        }
        XCTAssertEqual(api.leftovers(), [], "uploads and job audio are removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path), "the recordings journal is untouched")
        XCTAssertEqual(api.transcriber.completed, 5)
    }

    @MainActor func testLocalPathJSONAndOtherContainers() async throws {
        let api = try await APIFixture()
        defer { api.close() }
        var files: [URL] = []
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        for (ext, format) in [("m4a", "m4af"), ("flac", "flac"), ("caf", "caff"), ("aiff", "AIFF")] {
            let out = audio.deletingPathExtension().appendingPathExtension(ext)
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", format, "-d", ext == "m4a" ? "aac" : ext == "flac" ? "flac" : ext == "aiff" ? "BEI16" : "LEI16", audio.path, out.path]
            try convert.run(); convert.waitUntilExit()
            XCTAssertEqual(convert.terminationStatus, 0, ext); files.append(out)
        }
        for file in files {
            var request = URLRequest(url: URL(string: api.base + "/v1/audio/transcriptions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("test-token", forHTTPHeaderField: "X-Vella-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["path": file.path, "model": "fake-b", "response_format": "verbose_json"])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200, file.pathExtension + String(decoding: data, as: UTF8.self))
            let duration = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["duration"] as? Double)
            XCTAssertEqual(duration, 19.4, accuracy: 0.1, file.pathExtension)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path), "a local path is read, never moved or deleted")
        XCTAssertEqual(api.leftovers(), [])
    }

    /// Bad requests change nothing: no worker starts, no model loads, no file stays.
    @MainActor func testMalformedRequestsHaveNoSideEffects() async throws {
        let api = try await APIFixture()
        defer { api.close() }
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID()).wav")
        try Data("this is not audio".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        let cases: [([String: String], URL?, Int, String?)] = [
            ([:], nil, 400, "file"),
            (["response_format": "mp3"], audio, 400, "response_format"),
            (["temperature": "7"], audio, 400, "temperature"),
            (["model": "nope"], audio, 404, "model"),
            (["model": "stream-x"], audio, 404, "model"),
            (["stream": "true"], audio, 400, "stream"),
            ([:], text, 400, "file"),
        ]
        for (fields, file, expected, param) in cases {
            let (code, _, data) = try await api.post(fields: fields, file: file)
            XCTAssertEqual(code, expected, "\(fields) \(String(decoding: data, as: UTF8.self))")
            let error = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            XCTAssertEqual(error?["param"] as? String, param, "\(fields)")
            XCTAssertNotNil(error?["message"] as? String)
        }
        let (streamCode, _, streamData) = try await api.post(fields: ["model": "stream-x"], file: audio)
        XCTAssertEqual(streamCode, 404)
        XCTAssertTrue(String(decoding: streamData, as: UTF8.self).contains("Streaming model"))
        // Broken framing and JSON bodies.
        let boundary = "b"
        let broken = "--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1"
        let malformed = await APIFixture.raw(api.port, "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(api.port)\r\nContent-Type: multipart/form-data; boundary=\(boundary)\r\nContent-Length: \(broken.utf8.count)\r\n\r\n\(broken)")
        XCTAssertEqual(malformed, 400)
        for body in [#"{"path":"relative.wav"}"#, #"{"path":"/no/such/file.wav"}"#, "not json", #"{"path":"\#(audio.path)","response_format":"xml"}"#] {
            let code = await APIFixture.raw(api.port, "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(api.port)\r\nContent-Type: application/json\r\nX-Vella-Token: test-token\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            XCTAssertEqual(code, 400, body)
        }
        // A local path without the status file's token (a sandboxed app cannot read it) is refused.
        for token in ["", "X-Vella-Token: wrong\r\n"] {
            let body = #"{"path":"\#(audio.path)"}"#
            let code = await APIFixture.raw(api.port, "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(api.port)\r\nContent-Type: application/json\r\n\(token)Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
            XCTAssertEqual(code, 403, token)
        }
        XCTAssertNil(api.backend.processID, "no worker started")
        XCTAssertTrue(api.runtime.status.models.isEmpty)
        XCTAssertEqual(api.leftovers(), [])
        XCTAssertEqual(api.requests(), [])
    }

    /// Refused before the body is read: web pages (Origin), DNS rebinding (Host), simple POSTs, repeated headers, size.
    @MainActor func testLoopbackSecurityRefusals() async throws {
        let api = try await APIFixture()
        defer { api.close() }
        let p = api.port
        let body = "--x\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--x--\r\n"
        func post(_ headers: String, body: String = body) -> String {
            "POST /v1/audio/transcriptions HTTP/1.1\r\n\(headers)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        let host = "Host: 127.0.0.1:\(p)", multipart = "Content-Type: multipart/form-data; boundary=x"
        let cases: [(String, Int)] = [
            (post("\(host)\r\n\(multipart)\r\nOrigin: https://evil.example"), 403),
            (post("Host: evil.example:\(p)\r\n\(multipart)"), 403),
            (post("Host: 127.0.0.1\r\n\(multipart)"), 403),
            (post("\(host)\r\n\(host)\r\n\(multipart)"), 403),
            (post("\(host)\r\nContent-Type: text/plain"), 415),
            (post("\(host)\r\nContent-Type: application/x-www-form-urlencoded", body: "model=whisper-1"), 415),
            (post("\(host)\r\n\(multipart)\r\nContent-Type: application/json"), 400),
            ("POST /v1/audio/transcriptions HTTP/1.1\r\n\(host)\r\n\(multipart)\r\nContent-Length: 999999999\r\n\r\n", 413),
            ("POST /v1/audio/transcriptions HTTP/1.1\r\n\(host)\r\n\(multipart)\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 411),
            ("GET /v1/audio/transcriptions HTTP/1.1\r\n\(host)\r\n\r\n", 405),
            ("GET /v1/secret HTTP/1.1\r\n\(host)\r\n\r\n", 404),
            ("GET /status HTTP/1.1\r\n\(host)\r\nOrigin: http://localhost\r\n\r\n", 403),
            ("GARBAGE\r\n\r\n", 400),
        ]
        for (request, expected) in cases {
            let code = await APIFixture.raw(p, request)
            XCTAssertEqual(code, expected, request.components(separatedBy: "\r\n").prefix(4).joined(separator: " | "))
        }
        // The same checks through curl, the way a user would try them.
        // Never block the main actor while curl runs: the API's handler runs there.
        func curl(_ args: [String]) async throws -> String {
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10"] + args
            process.standardOutput = out
            try process.run()
            while process.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let url = "http://127.0.0.1:\(p)/v1/audio/transcriptions"
        do { let code = try await curl(["-H", "Origin: https://evil.example", "-F", "file=@\(audio.path)", url]); XCTAssertEqual(code, "403") }
        do { let code = try await curl(["-H", "Host: evil.example", "-F", "file=@\(audio.path)", url]); XCTAssertEqual(code, "403") }
        do { let code = try await curl(["-H", "Content-Type: text/plain", "--data-binary", "@\(audio.path)", url]); XCTAssertEqual(code, "415") }
        do { let code = try await curl(["-d", "model=whisper-1", url]); XCTAssertEqual(code, "415") }
        do { let code = try await curl(["-F", "file=@\(audio.path)", "-F", "model=fake-b", "-H", "Authorization: Bearer anything", url]); XCTAssertEqual(code, "200") }
        XCTAssertEqual(Set(api.requests().map { $0.components(separatedBy: " ")[1] }), ["fake-b"], "only the valid curl call reached the worker")
        XCTAssertEqual(api.leftovers(), [])
    }

    /// Dictation goes first: API segments wait while a dictation is active, and a dictation that finishes during an API
    /// segment waits for that one segment instead of failing.
    @MainActor func testDictationHasPriority() async throws {
        let api = try await APIFixture(models: ["slow-a", "slow-b"])
        defer { api.close() }
        api.dictationActive = true
        let job = Task { try await api.post(fields: ["model": "slow-b"], file: audio) }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(api.requests(), [], "no API work while dictation is active")
        XCTAssertNil(api.runtime.status.models["slow-b"], "not even a model load")
        api.dictationActive = false
        // Let the job start its segments, then a dictation arrives mid-segment.
        while !api.requests().contains(where: { $0.hasPrefix("start slow-b") }) { try await Task.sleep(nanoseconds: 5_000_000) }
        api.dictationActive = true
        let segment = api.root.appendingPathComponent("dictation.wav")
        try Self.monoWAV(segment, seconds: 2)
        let config = Configuration(model: api.models.list[0].path)
        let started = Date()
        let text = try await api.backend.transcribe(segment, config: config)
        let waited = Date().timeIntervalSince(started)
        api.dictationActive = false
        XCTAssertTrue(text.hasPrefix("slow-a heard 2.00"), text)
        XCTAssertLessThan(waited, 1.5, "waits for at most one API segment (0.3 s) plus a load")
        let (code, _, data) = try await job.value
        XCTAssertEqual(code, 200, String(decoding: data, as: UTF8.self))
        // The dictation request ran between API segments, never inside one.
        let log = api.requests()
        let dictationStart = try XCTUnwrap(log.firstIndex { $0.hasPrefix("start slow-a") })
        XCTAssertTrue(log[dictationStart - 1].hasPrefix("end slow-b"), log.joined(separator: "\n"))
        XCTAssertTrue(log[dictationStart + 1].hasPrefix("end slow-a"))
    }

    /// An API load never evicts the dictation model; it is refused with the memory numbers instead (507).
    @MainActor func testAPILoadNeverEvictsTheDictationModel() async throws {
        let api = try await APIFixture(availableMB: 100_000)
        defer { api.close() }
        let current = api.models.list[0]
        _ = try await api.backend.transcribe({ let u = api.root.appendingPathComponent("d.wav"); try Self.monoWAV(u, seconds: 1); return u }(),
                                             config: Configuration(model: current.path))
        XCTAssertNotNil(api.runtime.status.models["fake-a"])
        try api.runtime.setAvailableMB(1_600) // room for one model only if fake-a were evicted
        let (code, _, data) = try await api.post(fields: ["model": "fake-b"], file: audio)
        XCTAssertEqual(code, 507, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "insufficient_memory")
        XCTAssertNotNil(api.runtime.status.models["fake-a"], "the dictation model stays loaded")
        XCTAssertNil(api.runtime.status.models["fake-b"])
        XCTAssertEqual(api.leftovers(), [])
    }

    @MainActor func testQueueLimit() async throws {
        let api = try await APIFixture(models: ["slow-a"])
        defer { api.close() }
        api.transcriber.maxWaiting = 0
        api.dictationActive = true // hold the first job in the queue
        let first = Task { try await api.post(fields: [:], file: audio) }
        while api.transcriber.running == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        let (code, _, _) = try await api.post(fields: [:], file: audio)
        XCTAssertEqual(code, 429)
        api.dictationActive = false
        let (firstCode, _, _) = try await first.value
        XCTAssertEqual(firstCode, 200)
    }

    /// Opt-in: the real VellaWorker on the MLX CPU device (no GPU) with a real model, through the API end to end.
    /// VELLA_MLX_DEVICE=cpu VELLA_TEST_API_HELPER=<.app>/Contents/MacOS/VellaWorker VELLA_TEST_API_MODEL=<model dir>
    @MainActor func testRealWorkerOnCPUDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VELLA_MLX_DEVICE"] == "cpu", let helper = env["VELLA_TEST_API_HELPER"], let model = env["VELLA_TEST_API_MODEL"] else {
            throw XCTSkip("opt-in: VELLA_MLX_DEVICE=cpu, VELLA_TEST_API_HELPER and VELLA_TEST_API_MODEL")
        }
        // Refuse a worker that predates the CPU-device override: it would run on the GPU.
        let binary = try Data(contentsOf: URL(fileURLWithPath: helper), options: .alwaysMapped)
        guard binary.range(of: Data("VELLA_MLX_DEVICE".utf8)) != nil else { XCTFail("this VellaWorker ignores VELLA_MLX_DEVICE; it would use the GPU"); return }
        let api = try await APIFixture(models: [], helper: URL(fileURLWithPath: helper), modelPaths: [model])
        defer { api.close() }
        let speech = Repository.root
            .appendingPathComponent("Resources/Calibration/speech.wav")
        let m4a = api.root.appendingPathComponent("speech.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", speech.path, m4a.path]
        try convert.run(); convert.waitUntilExit()
        let started = Date()
        let (code, _, data) = try await api.post(fields: ["model": "whisper-1", "response_format": "verbose_json"], file: m4a)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(code, 200, body)
        let text = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String)
        print("real worker (CPU device) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(body)")
        XCTAssertTrue(text.lowercased().contains("the sea unbroken all round"), text)
        print("status test_hooks: \(api.runtime.status.test_hooks ?? [:])")
        XCTAssertEqual(api.runtime.status.test_hooks?["VELLA_MLX_DEVICE"], "cpu", "the worker reported the CPU device")
        XCTAssertEqual(api.leftovers(), [])
    }

    static func monoWAV(_ url: URL, seconds: Double) throws {
        let frames = Int(seconds * 16_000)
        var data = Data("RIFF".utf8)
        func u32(_ n: UInt32) { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + frames * 2)); data += Data("WAVEfmt ".utf8); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data += Data("data".utf8); u32(UInt32(frames * 2)); data += Data(count: frames * 2)
        try data.write(to: url)
    }
}
