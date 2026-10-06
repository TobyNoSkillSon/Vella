import Foundation
import XCTest
import VellaTestSupport

/// The primary installer forwards verification-only mode instead of silently performing an installation.
final class InstallScriptArgumentsTests: XCTestCase {
    func testReleaseDownloadFailureHasValidUTF8AndLeavesTheAppUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-installer-offline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in ["curl": "echo fixture-offline >&2; printf 000; exit 7", "sysctl": "echo 1", "uname": "echo Darwin", "sw_vers": "echo 26.6"] {
            let file = bin.appendingPathComponent(name)
            try Data(("#!/bin/bash\n" + body + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for (path, args) in [("scripts/install-release.sh", ["2.0.0", "--dry-run"]), ("scripts/install-public.sh", ["--dry-run"])] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [Repository.root.appendingPathComponent(path).path] + args
            process.environment = [
                "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
                "TMPDIR": root.path + "/", "VELLA_RELEASE_BASE_URL": "https://fixture.invalid",
                "VELLA_DESTINATION_APP": root.appendingPathComponent("Vella.app").path,
                "VELLA_SUPPORT_DIR": root.appendingPathComponent("support").path
            ]
            process.standardOutput = output; process.standardError = output
            try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8), "installer output must be valid UTF-8")
            XCTAssertNotEqual(process.terminationStatus, 0)
            XCTAssertTrue(text.contains("Downloading Vella 2.0.0…"), path)
            XCTAssertTrue(text.contains("the installed app is unchanged"), text)
            XCTAssertFalse(text.contains("unbound variable"), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Vella.app").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("support").path))
        }
    }

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
        for path in ["scripts/install.sh", "scripts/install-release.sh", "scripts/install-public.sh"] {
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
        try Data("#!/bin/bash\nprintf '<%s>\\n' \"$@\"\nprintf 'retry: %s\\n' \"$VELLA_INSTALL_RETRY_COMMAND\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let cases: [([String], String)] = [
            ([], "<2.0.0>\n"), (["2.0.1", "--allow-downgrade"], "<2.0.1>\n<--allow-downgrade>\n"), (["--dry-run"], "<2.0.0>\n<--dry-run>\n"),
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
            XCTAssertEqual(
                text, expected + "retry: scripts/install.sh \(args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "2.0.0") --migrate-signing\n", args.joined(separator: " "))
        }
    }
    func testShellGuardsProtectEvenReleasesWithOlderInstallerTools() throws {
        let script = #"""
            import os, pathlib, subprocess, sys, tempfile
            root = pathlib.Path(sys.argv[1])
            with tempfile.TemporaryDirectory(prefix='vella-shell-version-') as temp:
                base = pathlib.Path(temp); app = base/'prepared/Vella.app'; dest = base/'custom/Vella.app'
                for folder in [app,dest]: (folder/'Contents').mkdir(parents=True)
                for route in ['scripts/install-public.sh','scripts/install-prepared.sh']:
                    text = (root/route).read_text()
                    guard = text[text.index('check_version() {'):text.index('\n}\n', text.index('check_version() {'))+3]
                    guard = guard.replace('/usr/libexec/PlistBuddy','buddy')
                    setup = '''buddy() { case "$2" in *ShortVersionString*) if [[ $3 == "$DEST"/* ]]; then echo "$FIX_OLD"; else echo "$FIX_NEW"; fi;; *CFBundleVersion*) if [[ $3 == "$DEST"/* ]]; then echo "$OB"; else echo "$NB"; fi;; *) return 2;; esac; }; '''
                    for old,new,ob,nb,allow,exitcode in [
                        ('2.1.0','2.0.0','35','36',0,1), ('2.0.10','2.0.9','1','100',0,1),
                        ('2.0.0','2.0.0','36','35',0,1), ('2.0.0','2.0.0','36','35',1,0),
                        ('2.0.0','2.0.1','36','1',0,0), ('2.0.0','2.0.0','35','35',0,0),
                        ('bad','2.0.0','35','35',1,1)]:
                        env = dict(os.environ, APP=str(app),DEST=str(dest),FIX_OLD=old,FIX_NEW=new,OB=ob,NB=nb,ALLOW=str(allow))
                        result = subprocess.run(['/bin/bash','-c','set -euo pipefail; '+setup+guard+'\ncheck_version "$APP" "$DEST" "$ALLOW"'],env=env,capture_output=True,text=True,timeout=5)
                        assert result.returncode == exitcode, (route,old,new,ob,nb,allow,result.stderr)
                    assert text.index('check_version "$APP" "$DEST"') < text.index('OUTPUT="$("$TOOL" install'), route
                print('shell downgrade guards passed: numeric versions/builds, explicit override, malformed metadata and pre-tool ordering')
            """#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, Repository.root.path]
        process.standardOutput = output; process.standardError = output
        try process.run(); let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("shell downgrade guards passed"), text)
    }

}
