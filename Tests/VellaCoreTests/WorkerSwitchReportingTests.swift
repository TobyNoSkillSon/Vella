import XCTest
@testable import VellaCore

/// Every environment switch a worker reads must show up in status `test_hooks`, so a diagnostic run
/// (a forced stock path, an F32 Qwen encoder, a profiler) can never look like the shipping defaults.
/// The worker package needs MLX to build, so its switch lists are checked from source here.
final class WorkerSwitchReportingTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let gate = "Worker/Sources/MLXAudioSTT/FastPathGate.swift"

    func source(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }

    /// The string literals of a `static let name = …` declaration that spans lines up to its closing bracket.
    func literals(of name: String, in text: String) throws -> [String] {
        let start = try XCTUnwrap(text.range(of: "static let \(name) = "), name)
        let rest = text[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "]"), name)
        return matches(#""([A-Z0-9_]+)""#, in: String(rest[..<end.upperBound]))
    }

    func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testEveryWorkerEnvironmentSwitchIsReported() throws {
        let gate = try source(Self.gate)
        let reported = Set(try literals(of: "componentSwitches", in: gate) + literals(of: "reportedSwitches", in: gate))
        let prefixes = try literals(of: "componentSwitchPrefixes", in: gate)
        XCTAssertTrue(reported.contains("VELLA_FORCE_STOCK"), "parsed \(reported.sorted())")

        let sources = Self.root.appendingPathComponent("Worker/Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var read = Set<String>()
        for file in files {
            read.formUnion(matches(#"environment\["(VELLA_[A-Z0-9_]+)"\]"#, in: try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertTrue(read.contains("VELLA_QWEN_ENC_BF16"), "parsed \(read.sorted())")
        let hidden = read.filter { name in !reported.contains(name) && !prefixes.contains { name.hasPrefix($0) } }
        XCTAssertEqual(hidden.sorted(), [], "worker switches missing from reportedSwitches")
    }

    /// `vella diagnose` counts gate verdicts of the bundled reference's gate version when no model is loaded, so the
    /// reference must name the version the workers write.
    func testDiagnoseReferenceNamesTheWorkersGateVersion() throws {
        let gate = try source(Self.gate)
        let version = try XCTUnwrap(matches(#"static let version = "([a-z0-9-]+)""#, in: gate).first)
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/diagnose-reference.json"))
        XCTAssertEqual(DiagnoseReference.decode(data)?.gate_version, version)
    }

    func testQwenEncoderOverrideIsReportedByTheApp() {
        XCTAssertEqual(activeTestHooks(["VELLA_QWEN_ENC_BF16": "0", "HOME": "/x"]), ["VELLA_QWEN_ENC_BF16": "0"])
    }

    func testWhisperEncoderOverrideIsReportedByTheApp() {
        XCTAssertEqual(activeTestHooks(["VELLA_WHISPER_ENC_F16": "0", "HOME": "/x"]), ["VELLA_WHISPER_ENC_F16": "0"])
    }

    func testWhisperFusedDecodeSwitchIsReportedByTheApp() {
        XCTAssertEqual(activeTestHooks(["VELLA_WHISPER_FUSED": "0", "HOME": "/x"]), ["VELLA_WHISPER_FUSED": "0"])
    }

    func testParakeetFrontendSwitchIsReportedByTheApp() {
        XCTAssertEqual(activeTestHooks(["VELLA_PARAKEET_FP32_FRONTEND": "1", "HOME": "/x"]), ["VELLA_PARAKEET_FP32_FRONTEND": "1"])
    }
}
