import XCTest
import Foundation
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// The `vella` command and the OpenAI Python SDK against a stub API (fake worker, isolated support dir).
final class APIClientTests: XCTestCase {
    private var audio: URL!
    override func setUpWithError() throws {
        audio = FileManager.default.temporaryDirectory.appendingPathComponent("vella-cli-\(UUID().uuidString).wav")
        try writeTestWAV(audio)
        try Integration.require() // runs the vella binary; last, because tearDown runs after a skip too
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: audio) }

    static var cli: URL { Bundle(for: APIClientTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vella-cli") }

    /// Runs a program without blocking the main actor (the API's handler runs there).
    @MainActor static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async throws -> (Int32, String, String) {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment
        process.standardOutput = out; process.standardError = err
        try process.run()
        // Drain both pipes concurrently so a large transcript cannot fill a pipe and stall the child.
        let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
        let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
        while process.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        return (process.terminationStatus, String(decoding: await stdout.value, as: UTF8.self), String(decoding: await stderr.value, as: UTF8.self))
    }
    @MainActor private func vella(_ api: APIFixture?, _ arguments: [String], support: URL? = nil) async throws -> (Int32, String, String) {
        let env = ["VELLA_SUPPORT_DIR": (support ?? api!.runtime.support).path, "VELLA_NO_LAUNCH": "1", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        return try await Self.run(Self.cli, arguments, environment: env)
    }

    @MainActor func testCLIPrintsOneLinePerResult() async throws {
        let api = try await APIFixture()
        defer { api.close() }
        let (code, out, _) = try await vella(api, ["status"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, "Vella test running (pid \(getpid())), no model loaded · dictation model FAKE-A (8) · API http://127.0.0.1:\(api.port)/v1\n")

        let (mCode, models, _) = try await vella(api, ["models"])
        XCTAssertEqual(mCode, 0)
        XCTAssertEqual(models, "fake-a  FAKE-A · 8 · current dictation model\nfake-b  FAKE-B · 8\n")

        let (tCode, text, tErr) = try await vella(api, ["transcribe", audio.path])
        XCTAssertEqual(tCode, 0, tErr)
        // The 0.2 s final segment is recognized with its predecessor (one 5.2 s request).
        XCTAssertEqual(text, "fake-a heard 6.40 s. fake-a heard 7.80 s. fake-a heard 5.20 s.\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "the input file is left alone")

        let (sCode, srt, _) = try await vella(api, ["transcribe", audio.path, "--model", "fake-b", "--srt"])
        XCTAssertEqual(sCode, 0)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:06,400\nfake-b heard 6.40 s.\n\n2\n"), srt)

        let (jCode, json, _) = try await vella(api, ["transcribe", audio.path, "--json"])
        XCTAssertEqual(jCode, 0)
        XCTAssertEqual(json.filter { $0 == "\n" }.count, 1, "JSON is one line")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        let (sAfter, statusLine, _) = try await vella(api, ["status"])
        XCTAssertEqual(sAfter, 0)
        XCTAssertTrue(statusLine.contains("fake-a 8, fake-b 8 loaded"), statusLine)

        let (uCode, url, _) = try await vella(api, ["url"])
        XCTAssertEqual(uCode, 0); XCTAssertEqual(url, "http://127.0.0.1:\(api.port)/v1\n")
        let (hCode, help, _) = try await vella(api, ["--help"])
        XCTAssertEqual(hCode, 0)
        XCTAssertEqual(help.components(separatedBy: "\n").first, "Standard is optimized for your Mac through MLX; Optimized adds our custom kernels, measured on M5 Max so far")
        XCTAssertTrue(help.contains("vella transcribe FILE [--model ID] [--language CODE] [--text | --json | --verbose-json | --srt | --vtt]"), help)

        // Errors: one line on stderr, exit 1, no stdout.
        for (args, message) in [
            (["transcribe", audio.path, "--model", "nope"], "error: unknown model nope; see GET /v1/models\n"),
            (["transcribe", "/no/such.wav"], "error: no such file: /no/such.wav\n"),
            (["transcribe", audio.path, "--srt", "--vtt"], "error: choose one of --text, --json, --verbose-json, --srt, --vtt\n"),
            (["transcribe", NSTemporaryDirectory()], "error: \(NSTemporaryDirectory()) is a directory; give an audio file\n"),
            (["frobnicate"], "error: unknown command frobnicate; see vella --help\n")
        ] {
            let (eCode, eOut, eErr) = try await vella(api, args)
            XCTAssertEqual(eCode, 1, "\(args)"); XCTAssertEqual(eOut, ""); XCTAssertEqual(eErr, message)
        }
        XCTAssertEqual(api.leftovers(), [])
    }

    @MainActor func testCLIWhenVellaIsNotRunningAndSkill() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vella-cli-empty-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        // A status file whose app is gone (pid 999999) does not count as running; the isolated dir never launches the user's app.
        try JSONSerialization.data(withJSONObject: ["app_pid": 999_999, "api": 1, "api_port": 1, "updated": 0]).write(to: empty.appendingPathComponent("worker-status.json"))
        let (code, out, err) = try await vella(nil, ["status"], support: empty)
        XCTAssertEqual(code, 1); XCTAssertEqual(out, ""); XCTAssertEqual(err, "error: Vella is not running\n")
        let env = ["VELLA_SUPPORT_DIR": empty.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let (lCode, _, lErr) = try await Self.run(Self.cli, ["status"], environment: env)
        XCTAssertEqual(lCode, 1)
        XCTAssertEqual(lErr, "error: Vella is not running for VELLA_SUPPORT_DIR; set VELLA_APP to launch an app with it\n")
        let (mCode, _, mErr) = try await Self.run(Self.cli, ["status"], environment: env.merging(["VELLA_APP": empty.appendingPathComponent("Missing.app").path]) { $1 })
        XCTAssertEqual(mCode, 1)
        XCTAssertEqual(mErr, "error: Vella is not running and is not installed (looked for \(empty.path)/Missing.app)\n")

        let (sCode, skill, _) = try await vella(nil, ["skill"], support: empty)
        XCTAssertEqual(sCode, 0)
        let source = Repository.root
            .appendingPathComponent("Resources/SKILL.md")
        XCTAssertEqual(skill, try String(contentsOf: source, encoding: .utf8) + "\n")
        XCTAssertTrue(skill.hasPrefix("---\nname: transcribe\n"))
        XCTAssertEqual(Vella.skillText(bundle: Bundle(for: APIClientTests.self)), try String(contentsOf: source, encoding: .utf8), "the menu's Copy Skill copies the same file")
        let (iCode, wrote, _) = try await vella(nil, ["skill", "--install", empty.path], support: empty)
        XCTAssertEqual(iCode, 0)
        XCTAssertEqual(wrote, "wrote \(empty.path)/transcribe/SKILL.md\n")
        XCTAssertEqual(try String(contentsOf: empty.appendingPathComponent("transcribe/SKILL.md"), encoding: .utf8), try String(contentsOf: source, encoding: .utf8))
    }

    /// The official OpenAI Python SDK, unchanged, against the stub (opt-in: a venv with `openai` installed).
    /// VELLA_TEST_OPENAI_PYTHON=/path/to/venv/bin/python xcrun swift test --filter APIClientTests
    @MainActor func testOpenAIPythonSDK() async throws {
        guard let python = ProcessInfo.processInfo.environment["VELLA_TEST_OPENAI_PYTHON"] else { throw XCTSkip("set VELLA_TEST_OPENAI_PYTHON to a python with openai installed") }
        let api = try await APIFixture()
        defer { api.close() }
        let script = #"""
            import sys, openai
            from openai import OpenAI
            c = OpenAI(base_url=sys.argv[1], api_key="local", max_retries=0)
            path = sys.argv[2]
            ids = [m.id for m in c.models.list()]
            assert ids == ["fake-a", "fake-b"], ids
            assert c.models.retrieve("fake-b").id == "fake-b"
            with open(path, "rb") as f:
                t = c.audio.transcriptions.create(model="whisper-1", file=f)
            assert t.text.startswith("fake-a heard"), t
            with open(path, "rb") as f:
                v = c.audio.transcriptions.create(model="fake-b", file=f, response_format="verbose_json", timestamp_granularities=["segment"], language="en", temperature=0.0, prompt="Names: Vella.")
            assert v.segments and v.segments[0].start == 0 and abs(v.segments[-1].end - v.duration) < 1e-6, v
            with open(path, "rb") as f:
                s = c.audio.transcriptions.create(model="whisper-1", file=f, response_format="srt")
            assert isinstance(s, str) and s.startswith("1\n00:00:00,000 --> "), s
            with open(path, "rb") as f:
                x = c.audio.transcriptions.create(model="whisper-1", file=f, response_format="text")
            assert isinstance(x, str) and x.startswith("fake-a heard"), x
            try:
                with open(path, "rb") as f:
                    c.audio.transcriptions.create(model="nope", file=f)
                raise SystemExit("unknown model accepted")
            except openai.NotFoundError as e:
                assert e.code == "model_not_found", e
            print("openai", openai.__version__, "ok:", len(ids), "models,", len(v.segments), "segments")
            """#
        let file = api.root.appendingPathComponent("compat.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let (code, out, err) = try await Self.run(
            URL(fileURLWithPath: python), [file.path, api.base + "/v1", audio.path],
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "NO_PROXY": "*"])
        XCTAssertEqual(code, 0, out + err)
        XCTAssertTrue(out.contains("ok: 2 models"), out)
        print(out.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(api.leftovers(), [])
    }
}
