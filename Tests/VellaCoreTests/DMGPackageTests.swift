import Foundation
import XCTest
import VellaTestSupport

final class DMGPackageTests: XCTestCase {
    func testMissingInputsAndExistingOutputArePreservedWithoutPackaging() throws {
        try Integration.require()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-dmg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func run() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [Repository.root.appendingPathComponent("scripts/package-dmg.sh").path, root.path, "2.0.0"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertNotEqual(try run(), 0)
        let output = root.appendingPathComponent("Vella-2.0.0.dmg")
        let original = Data("preserve this image".utf8)
        try original.write(to: output)
        XCTAssertNotEqual(try run(), 0)
        XCTAssertEqual(try Data(contentsOf: output), original)
    }
    func testBadChecksumCannotProduceADMG() throws {
        try Integration.require()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-dmg-sha-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a release ZIP".utf8).write(to: root.appendingPathComponent("Vella-2.0.0-arm64.zip"))
        let sums = Data((String(repeating: "0", count: 64) + "  Vella-2.0.0-arm64.zip\n").utf8)
        try sums.write(to: root.appendingPathComponent("SHA256SUMS"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Repository.root.appendingPathComponent("scripts/package-dmg.sh").path, root.path, "2.0.0"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Vella-2.0.0.dmg").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("SHA256SUMS")), sums)
    }
}
