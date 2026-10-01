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

    func testSkillNamesTheSmallGeneralPurposeDefaultAndGetProgress() throws {
        let text = try String(contentsOf: Repository.root.appendingPathComponent("Resources/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("Start with `parakeet-v3-ultra` at `bf16`, Optimized Fast"))
        XCTAssertTrue(text.contains("Get prints download byte progress on stderr"))
    }
}
