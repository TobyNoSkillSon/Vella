import XCTest
import VellaTestSupport
@testable import VellaCLI

final class CLIReleaseTests: XCTestCase {
    func testCatalogLinesUseTheTableDTypeAndCorrectMode() {
        let model: [String: Any] = [
            "id": "stream", "name": "Stream", "dtype": "bf16", "mode": "Streaming", "current": true, "action": "Load",
            "selection": ["tier": "16", "path": "standard", "mode": "fast"]
        ]
        XCTAssertEqual(VellaCLI.modelLine(model), "stream  Stream · bf16 · Standard · current streaming model · Load")
    }

    func testHelpPutsTheMeasuredChipBoundaryImmediatelyAfterSynopsis() {
        XCTAssertTrue(usage.components(separatedBy: "\n")[0].hasPrefix("vella:"))
        XCTAssertEqual(
            usage.components(separatedBy: "\n")[1],
            "Standard is optimized for your Mac through MLX; Optimized adds our custom kernels, measured on M5 Max so far")
    }

    func testVersionNeedsNoAppOrAPI() async {
        var lines: [String] = []
        let cli = VellaCLI(environment: ["VELLA_NO_LAUNCH": "1"], write: { lines.append($0) }, warn: { _ in })
        let code = await cli.run(["--version"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(lines, ["Vella 2.0.0"])
    }

    func testAgentDocumentsPinTheSameChipLine() throws {
        let claim = "Standard is optimized for your Mac through MLX; Optimized adds our custom kernels, measured on M5 Max so far"
        for path in ["Resources/SKILL.md", "Resources/AGENT_GUIDE.md"] {
            let text = try String(contentsOf: Repository.root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.components(separatedBy: "\n").contains(claim), path)
        }
    }

    func testSkillNamesTheEuropeanLanguageDefaultAndGetProgress() throws {
        let text = try String(contentsOf: Repository.root.appendingPathComponent("Resources/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("Start with `parakeet-v3-ultra` at `bf16`, Optimized Fast"))
        XCTAssertTrue(text.contains("best for English and 24 other European languages; for other languages choose `whisper-large-v3-turbo`"))
        let data = try Data(contentsOf: Repository.root.appendingPathComponent("Resources/models.json"))
        let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let families = catalog["families"] as! [[String: Any]]
        let ultra = try XCTUnwrap(families.first { $0["id"] as? String == "parakeet-v3-ultra" })
        let languages = try XCTUnwrap(ultra["languages"] as? [String])
        XCTAssertEqual(languages.count, 25); XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(families.contains { $0["id"] as? String == "whisper-large-v3-turbo" })
        XCTAssertTrue(text.contains("Get prints download byte progress on stderr"))
    }
    func testRedirectedProgressReportsOnlyTenPercentOrFifteenSecondsAndPhaseChanges() {
        var throttle = GetProgressThrottle()
        let start = Date(timeIntervalSince1970: 100)
        func progress(_ bytes: Int, _ phase: String = "Downloading from Hugging Face…") -> [String: Any] {
            ["received_bytes": bytes, "total_bytes": 1000, "message": phase + " \(bytes) of 1000"]
        }
        XCTAssertTrue(throttle.shouldReport(progress(0), terminal: false, now: start))
        for second in 1..<10 {
            XCTAssertFalse(throttle.shouldReport(progress(second * 10), terminal: false, now: start.addingTimeInterval(Double(second))))
        }
        XCTAssertTrue(throttle.shouldReport(progress(100), terminal: false, now: start.addingTimeInterval(10)))
        XCTAssertFalse(throttle.shouldReport(progress(101), terminal: false, now: start.addingTimeInterval(24)))
        XCTAssertTrue(throttle.shouldReport(progress(102), terminal: false, now: start.addingTimeInterval(25)))
        XCTAssertTrue(throttle.shouldReport(progress(102, "Verifying downloaded file…"), terminal: false, now: start.addingTimeInterval(26)))
    }

    func testTerminalProgressIsLimitedToOneLinePerSecond() {
        var throttle = GetProgressThrottle()
        let start = Date(timeIntervalSince1970: 100)
        let progress: [String: Any] = ["message": "Downloading", "received_bytes": 0, "total_bytes": 100]
        XCTAssertTrue(throttle.shouldReport(progress, terminal: true, now: start))
        XCTAssertFalse(throttle.shouldReport(progress, terminal: true, now: start.addingTimeInterval(0.5)))
        XCTAssertTrue(throttle.shouldReport(progress, terminal: true, now: start.addingTimeInterval(1)))
    }

}
