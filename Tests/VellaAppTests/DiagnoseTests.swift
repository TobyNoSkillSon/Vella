import XCTest
import Foundation
@testable import Vella
@testable import VellaCore

/// `vella diagnose` against the stub API (fake worker, isolated support dir), and the menu's Copy Diagnostics.
final class DiagnoseCLITests: XCTestCase {
    @MainActor private func vella(_ support: URL, _ arguments: [String]) async throws -> (Int32, String, String) {
        let env = ["VELLA_SUPPORT_DIR": support.path, "VELLA_NO_LAUNCH": "1", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        return try await APIClientTests.run(APIClientTests.cli, arguments, environment: env)
    }

    @MainActor func testDiagnoseTimesLoadedModelsOnlyAndLoadsWhenAsked() async throws {
        guard FileManager.default.isExecutableFile(atPath: APIClientTests.cli.path) else { throw XCTSkip("vella-cli not built") }
        let api = try await APIFixture()
        defer { api.close() }
        let support = api.runtime.support
        let gate = support.appendingPathComponent("Worker/FastPath")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["status": "stock", "workerVersion": "native-kernels-8", "model": "fake-b",
                                                    "reason": "self-test timed out (45 s)"]).write(to: gate.appendingPathComponent("k1.json"))
        try JSONSerialization.data(withJSONObject: ["status": "fast", "workerVersion": "native-kernels-8"]).write(to: gate.appendingPathComponent("k2.json"))

        var (code, out, err) = try await vella(support, ["diagnose"])
        XCTAssertEqual(code, 0, err)
        XCTAssertTrue(out.hasPrefix("vella diagnose\nvella dev · app test · API 1"), out)
        XCTAssertTrue(out.contains("no model loaded: nothing timed. `vella diagnose --load` loads the dictation model (fake-a) and times it."), out)
        XCTAssertTrue(out.contains("gate verdicts: 1 optimized, 1 stock (fake-b: self-test timed out (45 s))"), out)
        XCTAssertTrue(out.contains("\nreport it (a prefilled GitHub bug report; add what you saw): https://github.com/TobyNoSkillSon/Vella/issues/new?template=bug_report.yml&title="), out)
        XCTAssertEqual(api.runtime.status.models.count, 0, "diagnose loads nothing by default")

        (code, out, err) = try await vella(support, ["diagnose", "--load", "--json"])
        XCTAssertEqual(code, 0, err)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(json["loaded_for_diagnosis"] as? String, "fake-a")
        XCTAssertEqual(json["running"] as? Bool, true)
        let model = try XCTUnwrap((json["models"] as? [[String: Any]])?.first)
        XCTAssertEqual(model["id"] as? String, "fake-a")
        XCTAssertEqual(model["engine"] as? String, "mlx")
        XCTAssertEqual(model["fallbacks"] as? [String], ["stock MLX (no reason reported)"])
        let run = try XCTUnwrap(model["run"] as? [String: Any])
        let clips = try XCTUnwrap(run["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.map { $0["clip"] as? String }, ["clip-a", "clip-b", "clip-c", "clip-d", "clip-e"])
        XCTAssertEqual(clips.first?["text"] as? String, "fake-a heard 3.38 s.", "the bundled clip went through the API")
        XCTAssertTrue(run["reference"] is NSNull, "no reference for a fake model")
        XCTAssertEqual((run["pass_s"] as? [Double])?.count, Diagnose.timedPasses)
        XCTAssertGreaterThan(run["speed_x"] as? Double ?? 0, 0)
        XCTAssertEqual((json["host"] as? [String: Any])?["chip"] as? String, "Fake M", "the worker's chip")
        XCTAssertEqual(api.leftovers(), [], "no clip copies or job folders are left")

        (code, out, err) = try await vella(support, ["diagnose"])
        XCTAssertEqual(code, 0, err)
        XCTAssertTrue(out.contains("fake-a: MLX · 8b · on demand\n  fallbacks: stock MLX (no reason reported)\n  clips: 5 transcribed, no reference for 8b on this path · 22.9 s of audio at "), out)

        (code, out, err) = try await vella(support, ["diagnose", "extra"])
        XCTAssertEqual(code, 1); XCTAssertEqual(out, ""); XCTAssertEqual(err, "error: unexpected argument extra\n")
    }

    @MainActor func testDiagnoseWhenVellaIsNotRunning() async throws {
        guard FileManager.default.isExecutableFile(atPath: APIClientTests.cli.path) else { throw XCTSkip("vella-cli not built") }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vella-diagnose-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try JSONSerialization.data(withJSONObject: ["app_pid": 999_999, "api": 1, "api_port": 1, "updated": 0]).write(to: empty.appendingPathComponent("worker-status.json"))
        let (code, out, err) = try await vella(empty, ["diagnose"])
        XCTAssertEqual(code, 0, err)
        XCTAssertTrue(out.contains("\nMac: "), out)
        XCTAssertTrue(out.contains("Vella is not running: start it from Applications and run `vella diagnose` again."), out)
        XCTAssertTrue(out.contains("Vella%20not%20running"), "the issue title says so")
    }
}

final class DiagnosticsCopierTests: XCTestCase {
    func testParseKeepsTheWholeReportAndFindsTheLink() {
        let output = "vella diagnose\nMac: M1\n\nreport it (a prefilled GitHub bug report; add what you saw): \(Diagnose.repository)/issues/new?template=bug_report.yml&title=x\n"
        let report = DiagnosticsCopier.parse(output)
        XCTAssertEqual(report.text, output.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(report.issue?.absoluteString, "\(Diagnose.repository)/issues/new?template=bug_report.yml&title=x")
        XCTAssertNil(DiagnosticsCopier.parse("no link").issue)
    }

    @MainActor func testRunsTheHelperOnceAndReportsItsError() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vella-copier-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("vella")
        try "#!/bin/sh\n[ \"$1\" = diagnose ] && [ \"$VELLA_NO_LAUNCH\" = 1 ] || { echo 'error: bad call' >&2; exit 1; }\necho 'vella diagnose'\necho 'report it: \(Diagnose.repository)/issues/new?template=bug_report.yml&title=t'\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let copier = DiagnosticsCopier()
        copier.helper = helper
        copier.environment = ["PATH": "/usr/bin:/bin"]
        let report = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DiagnosticsCopier.Report, Error>) in
            copier.run { continuation.resume(with: $0) }
            XCTAssertTrue(copier.running)
            copier.run { _ in XCTFail("a second run while one is going is ignored") }
        }
        XCTAssertFalse(copier.running)
        XCTAssertTrue(report.text.hasPrefix("vella diagnose\n"))
        XCTAssertNotNil(report.issue)

        try "#!/bin/sh\necho 'error: Vella is not running' >&2\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
        let failure = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            copier.run { result in
                if case .failure(let error) = result { continuation.resume(returning: error.localizedDescription) } else { continuation.resume(returning: "succeeded") }
            }
        }
        XCTAssertEqual(failure, "error: Vella is not running")

        copier.helper = dir.appendingPathComponent("missing")
        let missing = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            copier.run { result in if case .failure = result { continuation.resume(returning: true) } else { continuation.resume(returning: false) } }
        }
        XCTAssertTrue(missing)
    }
}
