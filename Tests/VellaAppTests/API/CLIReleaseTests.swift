import XCTest
import VellaTestSupport
@testable import VellaCLI

final class CLIReleaseTests: XCTestCase {
    func testHelpLeadsWithTheMeasuredChipBoundary() {
        XCTAssertEqual(
            usage.components(separatedBy: "\n").first,
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
}
