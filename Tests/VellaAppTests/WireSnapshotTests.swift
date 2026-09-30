import Foundation
import XCTest
import VellaTestSupport

/// The exact bytes both recognition helpers write on their stdio protocol, against Tests/Fixtures/wire. The app, the
/// `vella` command and lab scripts parse these lines, so a typed rewrite of the protocol must reproduce them: key order,
/// ASCII escaping, number formatting, null fields, `test_hooks` only when set. Volatile values (pid, timings, memory,
/// host chip, temporary paths) are replaced by placeholders; everything else is compared byte for byte.
///
/// Needs built helpers (stub models, no GPU work): `VELLA_TEST_WIRE_HELPERS` names a directory holding `VellaWorker` and
/// `VellaStreamingWorker` (e.g. `dist/Vella.app/Contents/MacOS`); otherwise the release build that scripts/build.sh
/// leaves in Worker/.build is used, and the test skips when there is none. `VELLA_RECORD_WIRE=1` rewrites the fixtures.
final class WireSnapshotTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Tests/Fixtures/wire")
    static let id = "6f1c2a4e-8d3b-4c1a-9e7f-2b5d8c0a1e34"
    static let volatile = ["pid", "load_s", "footprint_mb", "mlx_active_mb", "mlx_cache_mb", "loadSeconds", "loadPeakMLXBytes",
                           "cleanupSeconds", "inferenceSeconds", "requestSeconds", "processFootprintBytes", "processPeakFootprintBytes",
                           "processPeakRSSBytes", "processRSSBytes", "peakMLXBytes", "activeMLXBytes", "cacheMLXBytes"]

    func helpers() throws -> URL {
        try Integration.require()
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["VELLA_TEST_WIRE_HELPERS"].map { URL(fileURLWithPath: $0) },
                          Self.root.appendingPathComponent("Worker/.build/arm64-apple-macosx/release")].compactMap { $0 }
        for dir in candidates where ["VellaWorker", "VellaStreamingWorker"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent($0).path) }) { return dir }
        throw XCTSkip("built helpers required: set VELLA_TEST_WIRE_HELPERS or run scripts/build.sh")
    }

    /// Runs `executable` with `lines` on stdin (then EOF) and returns its stdout.
    func exchange(_ executable: URL, _ lines: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        // The streaming helper exits after an error reply; a later line then meets a closed pipe (EPIPE, not a crash:
        // the throwing write, with SIGPIPE ignored for this write).
        let previous = signal(SIGPIPE, SIG_IGN)
        try? input.fileHandleForWriting.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try? input.fileHandleForWriting.close()
        signal(SIGPIPE, previous)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func normalized(_ text: String, replacing paths: [String: String]) throws -> String {
        var out = text
        for (path, name) in paths.sorted(by: { $0.key.count > $1.key.count }) { out = out.replacingOccurrences(of: path, with: name) }
        for key in Self.volatile {
            let regex = try NSRegularExpression(pattern: "\"\(key)\":-?[0-9][0-9.eE+-]*")
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\"\(key)\":0")
        }
        let chip = try NSRegularExpression(pattern: #""gpu":\{"chip":"[^"]*","family":"[^"]*"\}"#)
        return chip.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: #""gpu":{"chip":"CHIP","family":"FAMILY"}"#)
    }

    func check(_ name: String, _ actual: String) throws {
        let url = Self.fixtures.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["VELLA_RECORD_WIRE"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(actual, expected, name)
        if actual != expected {
            for (a, e) in zip(actual.components(separatedBy: "\n"), expected.components(separatedBy: "\n")) where a != e {
                print("wire \(name)\n  actual:   \(a)\n  expected: \(e)")
            }
        }
    }

    /// A 0.1-s 16-kHz mono WAV and a stub model folder in a fresh directory.
    func scratch() throws -> (dir: URL, model: URL, audio: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vella-wire-\(UUID().uuidString)").resolvingSymlinksInPath()
        let model = dir.appendingPathComponent("stub-model"), data = dir.appendingPathComponent("data")
        for folder in [model, data] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("{\"model_type\": \"stub\"}\n".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("stub weights\n".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        var wav = Data()
        func u16(_ v: Int) { wav.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16) }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + 3200); wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(3200)
        for i in 0..<1600 { u16(i % 2 == 0 ? 1000 : 0xfc18) }
        let audio = dir.appendingPathComponent("clip.wav")
        try wav.write(to: audio)
        return (dir, model, audio)
    }

    func testDictationHelperWire() throws {
        let bin = try helpers()
        let (dir, model, audio) = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data")
        let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VELLA_STUB_MODELS": "1", "VELLA_WORKER_DATA_DIR": data.path]
        let id = Self.id
        let lines = [
            #"{"id":"\#(id)","op":"status"}"#,
            #"{"id":"\#(id)","op":"load","model":"\#(model.path)"}"#,
            #"{"id":"\#(id)","op":"load","model":"\#(model.path)"}"#,
            #"{"id":"\#(id)","model":"\#(model.path)","audio":"\#(audio.path)"}"#,
            #"{"id":"\#(id)","op":"trim"}"#,
            #"{"id":"\#(id)","op":"unload"}"#,
            #"{"id":"\#(id)","op":"bogus"}"#,
            #"{"id":"\#(id)","op":"load","model":"\#(dir.path)/missing"}"#,
            #"{"id":"\#(id)","op":"status","extra":1}"#,
            #"{"id":"not-a-uuid","op":"status"}"#,
            "not json",
        ]
        let output = try exchange(bin.appendingPathComponent("VellaWorker"), lines, environment: environment)
        try check("dictation.txt", try normalized(output, replacing: ["/private" + dir.path: "$SCRATCH", dir.path: "$SCRATCH"]))
    }

    func testDictationHelperFailures() throws {
        let bin = try helpers()
        let (dir, model, audio) = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VELLA_STUB_MODELS": "1",
                           "VELLA_WORKER_DATA_DIR": dir.appendingPathComponent("data").path, "VELLA_TEST_LOAD_FAULT": "stub-model"]
        let id = Self.id
        let lines = [
            #"{"id":"\#(id)","op":"load","model":"\#(model.path)"}"#,
            #"{"id":"\#(id)","model":"\#(model.path)","audio":"\#(audio.path)"}"#,
        ]
        let output = try exchange(bin.appendingPathComponent("VellaWorker"), lines, environment: environment)
        try check("dictation-load-failed.txt", try normalized(output, replacing: ["/private" + dir.path: "$SCRATCH", dir.path: "$SCRATCH"]))
    }

    func testStreamingHelperWire() throws {
        let bin = try helpers()
        let (dir, model, _) = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VELLA_WORKER_DATA_DIR": dir.appendingPathComponent("data").path]
        let id = Self.id
        let executable = bin.appendingPathComponent("VellaStreamingWorker")
        // Each exchange ends the process (an error reply is fatal for the streaming helper), so one case per run.
        var output = try exchange(executable, [#"{"id":"\#(id)","op":"unload"}"#, #"{"id":"\#(id)","op":"bogus"}"#], environment: environment)
        output += try exchange(executable, ["not json"], environment: environment)
        output += try exchange(executable, [#"{"id":"\#(id)","op":"load","model":"\#(model.path)"}"#], environment: environment)
        output += try exchange(executable, [#"{"id":"\#(id)","op":"load","model":"\#(model.path)","extra":1}"#], environment: environment)
        try check("streaming.txt", try normalized(output, replacing: ["/private" + dir.path: "$SCRATCH", dir.path: "$SCRATCH"]))
    }
}
