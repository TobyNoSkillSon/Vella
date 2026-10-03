import CryptoKit
import Foundation
import XCTest
import VellaTestSupport

final class DMGPackageTests: XCTestCase {
    func testPackagedImageVerifiesItsCopiedAndMountedAppBeforePublishing() throws {
        try Integration.require()
        for refuseMountedSignature in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-dmg-positive-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appendingPathComponent("Vella.app")
            let contents = app.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/Vella")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
            let info: [String: Any] = [
                "CFBundleExecutable": "Vella", "CFBundleIdentifier": "test.vella.dmg",
                "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            func run(_ executable: String, _ args: [String], environment: [String: String]? = nil) throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
                if let environment { process.environment = environment }
                process.standardOutput = FileHandle.nullDevice
                let diagnostics = root.appendingPathComponent("stderr")
                FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
                let errorFile = try FileHandle(forWritingTo: diagnostics)
                defer { try? errorFile.close() }
                process.standardError = errorFile
                try process.run(); process.waitUntilExit()
                return process.terminationStatus
            }
            // Disposable ad-hoc signature only: never the release identity or installed app.
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path]), 0)
            let zip = root.appendingPathComponent("Vella-2.0.0-arm64.zip")
            XCTAssertEqual(try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.path, zip.path]), 0)
            let hash = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            let sums = Data((hash + "  " + zip.lastPathComponent + "\n").utf8)
            try sums.write(to: root.appendingPathComponent("SHA256SUMS"))
            let tools = root.appendingPathComponent("tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let verificationLog = root.appendingPathComponent("verifications")
            let shim = tools.appendingPathComponent("codesign")
            let script = """
                #!/bin/bash
                echo "$*" >> "\(verificationLog.path)"
                if [[ "$*" == *'/mounted/Vella.app'* ]]; then
                  store="$(dirname "${@: -1}")/.DS_Store"
                  /usr/bin/python3 -c 'import sys; assert b"hiexbool" + bytes([1]) in open(sys.argv[1], "rb").read()' "$store" || exit 2
                  echo "hidden-extension:DS_Store" >> "\(verificationLog.path)"
                fi
                if [[ "\(refuseMountedSignature)" == true && "$*" == *'/mounted/Vella.app'* ]]; then exit 1; fi
                exec /usr/bin/codesign "$@"
                """
            try script.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            let env = ProcessInfo.processInfo.environment.merging(["PATH": tools.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
            let result = try run("/bin/bash", [Repository.root.appendingPathComponent("scripts/package-dmg.sh").path, root.path, "2.0.0"], environment: env)
            let checks = (try? String(contentsOf: verificationLog, encoding: .utf8)) ?? ""
            let diagnostics = (try? String(contentsOf: root.appendingPathComponent("stderr"), encoding: .utf8)) ?? ""
            XCTAssertFalse(checks.isEmpty, diagnostics)
            XCTAssertTrue(checks.contains("/image/Vella.app"), "Verify the post-copy app")
            XCTAssertTrue(checks.contains("/mounted/Vella.app"), "Verify the app inside the finished image")
            XCTAssertTrue(checks.contains("hidden-extension:DS_Store"), "Finder extension metadata survives packaging: " + diagnostics)
            let output = root.appendingPathComponent("Vella-2.0.0.dmg")
            if refuseMountedSignature {
                XCTAssertNotEqual(result, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("SHA256SUMS")), sums)
            } else {
                XCTAssertEqual(result, 0, diagnostics)
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
                XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("SHA256SUMS"), encoding: .utf8).contains(output.lastPathComponent))
            }
        }
    }

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
