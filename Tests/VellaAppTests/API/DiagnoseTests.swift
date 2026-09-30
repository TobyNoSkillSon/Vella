import XCTest
import Foundation
@testable import Vella
@testable import VellaCore

/// `vella diagnose` against the stub API (fake worker, isolated support dir). The menu has no Copy Diagnostics item
/// (Toby, 29 Sep): users file issues; the command stays for agents and the skill.
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
        try JSONSerialization.data(withJSONObject: [
            "status": "stock", "workerVersion": "native-kernels-10", "model": "fake-b",
            "reason": "self-test timed out (45 s)"
        ]).write(to: gate.appendingPathComponent("k1.json"))
        try JSONSerialization.data(withJSONObject: ["status": "fast", "workerVersion": "native-kernels-10"]).write(to: gate.appendingPathComponent("k2.json"))

        var (code, out, err) = try await vella(support, ["diagnose"])
        XCTAssertEqual(code, 0, err)
        XCTAssertTrue(out.hasPrefix("vella diagnose\nvella dev · app test · API 1"), out)
        XCTAssertTrue(out.contains("no model loaded: nothing timed. `vella diagnose --load` loads the dictation model (fake-a) and times it."), out)
        XCTAssertTrue(out.contains("gate verdicts: 1 optimized, 1 stock (fake-b: self-test timed out (45 s))"), out)
        XCTAssertTrue(
            out.contains("\nreport it (a prefilled GitHub bug report; add what you saw): https://github.com/TobyNoSkillSon/Vella/issues/new?template=bug_report.yml&title="), out)
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
        XCTAssertTrue(
            out.contains(
                "fake-a: MLX · 8b · on demand\n  fallbacks: stock MLX (no reason reported)\n  clips: 5 transcribed, no reference for 8b on this path · 22.9 s of audio at "), out)

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
