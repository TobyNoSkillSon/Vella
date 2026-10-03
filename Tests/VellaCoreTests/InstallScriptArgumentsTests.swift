import Foundation
import XCTest
import VellaTestSupport

/// The primary installer forwards verification-only mode instead of silently performing an installation.
final class InstallScriptArgumentsTests: XCTestCase {
    func testSourceDryRunAndUnknownArgumentsRefuseBeforeBuilding() throws {
        for argument in ["--dry-run", "--unknown"] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [Repository.root.appendingPathComponent("scripts/install.sh").path, argument]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "VELLA_BUILD": "source"]
            process.standardOutput = output; process.standardError = output
            try process.run(); let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 2)
            XCTAssertTrue(text.contains("nothing built or installed")); XCTAssertFalse(text.contains("building Vella"))
        }
    }

    func testInstallersCheckHardwareNotRosettaProcessArchitecture() throws {
        for path in ["scripts/install.sh", "scripts/install-release.sh", "docs/install.sh"] {
            let text = try String(contentsOf: Repository.root.appendingPathComponent(path), encoding: .utf8)
            let guardLine = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains("hw.optional.arm64") })
            for (hardware, expected) in [("1", Int32(0)), ("0", Int32(1))] {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [
                    "-c", "uname() { [[ $1 == -s ]] && echo Darwin || echo x86_64; }; sysctl() { echo " + hardware + "; }; fail() { exit 1; }; " + guardLine + "; echo accepted"
                ]
                process.standardOutput = output; process.standardError = output
                try process.run(); _ = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, expected, path)
            }
        }
    }

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
            (["2.0.0", "--dry-run"], "<2.0.0>\n<--dry-run>\n"),
            (["--migrate-signing"], "<2.0.0>\n<--migrate-signing>\n")
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
