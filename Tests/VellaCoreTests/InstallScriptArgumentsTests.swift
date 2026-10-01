import Foundation
import XCTest
import VellaTestSupport

/// The primary installer forwards verification-only mode instead of silently performing an installation.
final class InstallScriptArgumentsTests: XCTestCase {
    func testReleaseArgumentsAreForwarded() throws {
        try Integration.require()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-install-args-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts"), resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Repository.root.appendingPathComponent("scripts/install.sh"), to: scripts.appendingPathComponent("install.sh"))
        let plist: [String: String] = ["CFBundleShortVersionString": "2.0.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("Info.plist"))
        let stub = scripts.appendingPathComponent("install-release.sh")
        try Data("#!/bin/bash\nprintf '<%s>\\n' \"$@\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let cases: [([String], String)] = [
            ([], "<2.0.0>\n"), (["--dry-run"], "<2.0.0>\n<--dry-run>\n"),
            (["2.0.0", "--dry-run"], "<2.0.0>\n<--dry-run>\n")
        ]
        for (args, expected) in cases {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scripts.appendingPathComponent("install.sh").path] + args
            process.environment = ["PATH": "/usr/bin:/bin", "VELLA_BUILD": "release"]
            process.standardOutput = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(text, expected, args.joined(separator: " "))
        }
    }
}
