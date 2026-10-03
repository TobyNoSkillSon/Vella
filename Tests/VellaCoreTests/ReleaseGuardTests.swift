import Foundation
import XCTest
import VellaTestSupport

final class ReleaseGuardTests: XCTestCase {
    func testReferenceQualificationGuardFixtures() throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "scripts/check-diagnose-reference.swift", "--selftest"]
        process.currentDirectoryURL = Repository.root; process.standardOutput = output; process.standardError = output
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, result)
        XCTAssertTrue(result.contains("provisional/missing conditions refused; qualified fixture accepted"), result)
    }

    func testBothReleasePathsQualifyReferenceButLocalBuildDoesNot() throws {
        for script in ["release-check.sh", "package-release.sh"] {
            let text = try String(contentsOf: Repository.root.appendingPathComponent("scripts/" + script), encoding: .utf8)
            XCTAssertTrue(text.contains("check-diagnose-reference.swift"), script)
        }
        let local = try String(contentsOf: Repository.root.appendingPathComponent("scripts/build.sh"), encoding: .utf8)
        XCTAssertFalse(local.contains("check-diagnose-reference.swift"))
    }
}
