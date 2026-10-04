import XCTest
import Foundation
@testable import VellaCore
import VellaTestSupport

final class NativeInstallerTests: XCTestCase {
    private func fixture(pathSuffix: String = "") throws -> (NativeInstaller, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-native-install-\(UUID())\(pathSuffix)")
        let prepared = root.appendingPathComponent("prepared/Vella.app")
        let app = root.appendingPathComponent("Applications/Vella.app")
        let support = root.appendingPathComponent("Library/Application Support/Vella")
        for name in ["Vella", "VellaWorker", "VellaStreamingWorker", "VellaModelTool"] {
            let path = prepared.appendingPathComponent("Contents/MacOS/\(name)")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let metallib = prepared.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        try FileManager.default.createDirectory(at: metallib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture shader".utf8).write(to: metallib)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.vella.dictation"], format: .xml, options: 0)
        try info.write(to: prepared.appendingPathComponent("Contents/Info.plist"))
        let installer = NativeInstaller(preparedApp: prepared, destination: app, support: support)
        installer.verify = { _ in .init("adhoc") }
        installer.stop = { _ in false }; installer.launch = { _ in }
        return (installer, root, app, support)
    }
    private func existingApp(_ app: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.vella.dictation"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: app.appendingPathComponent(marker))
    }
    /// A real signed bundle must keep its sealed relative alias through copy, swap and a second update.
    func testSignedStreamingAliasSurvivesFreshInstallAndUpdate() throws {
        let (installer, root, app, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared/Vella.app")
        let contents = prepared.appendingPathComponent("Contents")
        for name in ["Vella", "VellaWorker", "VellaModelTool"] {
            let path = contents.appendingPathComponent("MacOS/\(name)")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: path)
            if name != "Vella" { XCTAssertEqual(try runTool("/usr/bin/codesign", ["--force", "--sign", "-", path.path]).status, 0) }
        }
        let alias = contents.appendingPathComponent("MacOS/VellaStreamingWorker")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "VellaWorker")
        let info: [String: Any] = ["CFBundleIdentifier": "dev.vella.dictation", "CFBundleExecutable": "Vella", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(try runTool("/usr/bin/codesign", ["--force", "--sign", "-", prepared.path]).status, 0)
        installer.verify = NativeInstaller.verifySignedBundle // do not stub signature checks
        installer.keepPrevious = true
        XCTAssertNil(try installer.install())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Contents/MacOS/VellaStreamingWorker").path), "VellaWorker")
        XCTAssertEqual(try NativeInstaller.verifySignedBundle(app), .init("adhoc"))
        let previous = try XCTUnwrap(installer.install())
        for copy in [app, previous] {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("Contents/MacOS/VellaStreamingWorker").path), "VellaWorker")
            XCTAssertEqual(try NativeInstaller.verifySignedBundle(copy), .init("adhoc"))
        }
    }
    /// The retired VellaModelTool is not required: a prepared bundle without it installs.
    func testInstallSucceedsWithoutTheRetiredModelTool() throws {
        let (installer, root, app, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("prepared/Vella.app/Contents/MacOS/VellaModelTool"))
        XCTAssertNil(try installer.install())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/VellaWorker").path))
    }
    func testFreshInstallDownloadsAndPredefinesNothing() throws {
        let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = support.appendingPathComponent("Runtimes/legacy/bin/python")
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retain".utf8).write(to: runtime)
        var launched: [URL] = []; installer.launch = { launched.append($0) }
        XCTAssertNil(try installer.install())
        XCTAssertEqual(launched, [app])
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path), "no predefined settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("models-installed.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Models").path), "nothing downloaded")
        XCTAssertEqual(try String(contentsOf: runtime), "retain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Vella").path))
    }
    func testBusyLoadingAndLinkedDestinationsRefuseBeforeMutation() throws {
        for cause in ["busy", "loading", "link"] {
            let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            switch cause {
            case "busy": try Data(#"{"phase":"recording"}"#.utf8).write(to: support.appendingPathComponent("dictation-status.json"))
            case "loading":
                try Data(#"{"app_pid":\#(getpid()),"loading":"parakeet-v3","models":{},"launch_set":[]}"#.utf8)
                    .write(to: support.appendingPathComponent(InstallReadiness.statusFileName))
            default:
                let external = root.appendingPathComponent("external"); try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Models"), withDestinationURL: external)
            }
            XCTAssertThrowsError(try installer.install(), cause) { error in
                if cause == "loading" { XCTAssertEqual(error.localizedDescription, "Vella is loading parakeet-v3. Try again in a moment; installation left unchanged.") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        }
    }
    func testStaleLoadingStatusFromDeadAppDoesNotBlock() throws {
        let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"app_pid":999999,"loading":"parakeet-v3"}"#.utf8).write(to: support.appendingPathComponent(InstallReadiness.statusFileName))
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }
    func testFailedSwapRestoresOldAppAndSettings() throws {
        let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try existingApp(app, marker: "old")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = support.appendingPathComponent("config.json")
        let original = Data(#"{"model":"/old","streamingModel":"/stream","custom":42,"port":8000}"#.utf8)
        try original.write(to: config)
        installer.afterSwap = { throw NativeInstallError.message("fixture swap failure") }
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("old")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Vella").path))
    }
    func testUpdateReplacesWholeBundleAndKeepsPreviousUntilReady() throws {
        let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try existingApp(app, marker: "Contents/Resources-inference_worker.py")
        installer.keepPrevious = true
        let previous = try XCTUnwrap(installer.install())
        XCTAssertTrue(previous.lastPathComponent.hasPrefix(".Vella.app.previous."))
        XCTAssertEqual(previous.deletingLastPathComponent(), app.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.appendingPathComponent("Contents/Resources-inference_worker.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources-inference_worker.py").path), "old-layout files never survive")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path).filter { $0.hasPrefix(".vella-update-") }
        XCTAssertEqual(leftovers, [])
        _ = support
    }
    func testExistingSettingsArePreservedAndOnlyLegacyPortDropped() throws {
        let (installer, root, _, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let saved: [String: Any] = ["model": "/external/model", "streamingModel": "/other/stream", "custom": 42, "preferredMicrophone": "Shure", "port": 8000]
        try JSONSerialization.data(withJSONObject: saved).write(to: support.appendingPathComponent("config.json"))
        try installer.install()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("config.json"))) as! [String: Any]
        for key in ["model", "streamingModel", "custom", "preferredMicrophone"] { XCTAssertEqual(String(describing: config[key]!), String(describing: saved[key]!)) }
        XCTAssertNil(config["port"])
    }
    func testVerifiedAdHocUpgradeRequiresConsentPreservesDataAndBackup() throws {
        let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = installer.preparedApp
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: prepared, to: app)
        let oldExecutable = app.appendingPathComponent("Contents/MacOS/Vella")
        try FileManager.default.removeItem(at: oldExecutable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: oldExecutable)
        let plist = ["CFBundleIdentifier": "dev.vella.dictation", "CFBundleExecutable": "Vella", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.8.8"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(try runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--deep", app.path]).status, 0)
        XCTAssertEqual(try NativeInstaller.verifySignedBundle(app), .init("adhoc"))
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Models"), withIntermediateDirectories: true)
        let kept = [
            "config.json": Data(#"{"model":"/fixture","custom":42}"#.utf8), "models-installed.json": Data("{}".utf8), "Models/weights": Data("weights".utf8),
            "history.json": Data("history".utf8)
        ]
        for (name, bytes) in kept { try bytes.write(to: support.appendingPathComponent(name)) }
        // The old app is genuinely ad-hoc signed; the replacement certificate identity is injected, never taken from a user's keychain.
        installer.verify = { url in
            url == app && !installer.didMigrateSigning ? try NativeInstaller.verifySignedBundle(url) : .init("designated => " + NativeInstaller.releaseRequirement)
        }
        installer.verifyMigrationTarget = { _ in } // actual release certificate is qualified by CI, not manufactured here
        var stopped = 0
        installer.stop = { _ in
            stopped += 1; return false
        }; installer.launch = { _ in }
        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertTrue(error.localizedDescription.contains("--migrate-signing"))
            XCTAssertTrue(error.localizedDescription.contains("Microphone and Accessibility"))
        }
        XCTAssertEqual(stopped, 0)
        for (name, bytes) in kept { XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(name)), bytes) }
        installer.allowSigningMigration = true
        let previous = try XCTUnwrap(installer.install())
        XCTAssertTrue(installer.didMigrateSigning); XCTAssertEqual(stopped, 1)
        XCTAssertEqual(try NativeInstaller.verifySignedBundle(previous), .init("adhoc"))
        for (name, bytes) in kept { XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(name)), bytes) }
    }
    /// Real ad-hoc seals exercise verification/copy/rollback without any keychain access. Only certificate
    /// metadata is injected, just as for the unavailable release identity in the ad-hoc migration test.
    func testDevelopmentAndSelfSignedUpgradeRequiresConsentAndKeepsBackup() throws {
        let identities = [
            #"designated => identifier "dev.vella.dictation" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Fixture""#,
            #"designated => identifier "dev.vella.dictation" and certificate leaf = H"0123456789012345678901234567890123456789""#
        ]
        let retry = "curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash -s -- --migrate-signing"
        for identity in identities {
            let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let prepared = installer.preparedApp
            for name in ["Vella", "VellaWorker", "VellaStreamingWorker", "VellaModelTool"] {
                let path = prepared.appendingPathComponent("Contents/MacOS/\(name)")
                try FileManager.default.removeItem(at: path)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: path)
            }
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "dev.vella.dictation", "CFBundleExecutable": "Vella", "CFBundlePackageType": "APPL"],
                format: .xml, options: 0
            ).write(to: prepared.appendingPathComponent("Contents/Info.plist"))
            XCTAssertEqual(try runTool("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", prepared.path]).status, 0)
            try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: prepared, to: app)
            installer.verify = { url in
                _ = try NativeInstaller.verifySignedBundle(url)
                return .init(url == app && !installer.didMigrateSigning ? identity : "designated => " + NativeInstaller.releaseRequirement)
            }
            installer.verifyMigrationTarget = { url in
                try NativeInstaller.verifyRequirement(url, #"identifier "dev.vella.dictation""#)
            }
            XCTAssertThrowsError(try NativeInstaller.verifyRequirement(prepared, #"identifier "another.app""#))
            XCTAssertThrowsError(try NativeInstaller.verifyRequirement(prepared, NativeInstaller.releaseRequirement))
            installer.signingRetryCommand = retry
            var stopped = 0
            installer.stop = { _ in
                stopped += 1; return false
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let settings = Data(#"{"custom":42}"#.utf8)
            try settings.write(to: support.appendingPathComponent("config.json"))
            XCTAssertThrowsError(try installer.install()) { error in
                guard case NativeInstallError.signingMigrationRequired = error else { return XCTFail("Wrong refusal: \(error)") }
                XCTAssertTrue(error.localizedDescription.contains(retry))
                XCTAssertTrue(error.localizedDescription.contains("Microphone and Accessibility"))
                XCTAssertTrue(error.localizedDescription.contains(identity.contains("subject.CN") ? "Apple Development: Fixture" : "0123456789012345678901234567890123456789"))
            }
            XCTAssertEqual(stopped, 0)
            installer.allowSigningMigration = true
            installer.afterSwap = { throw NativeInstallError.message("Fixture migration swap failure") }
            XCTAssertThrowsError(try installer.install())
            XCTAssertEqual(stopped, 1)
            XCTAssertEqual(try NativeInstaller.verifySignedBundle(app), .init("adhoc"), "old sealed app restored")
            XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("config.json")), settings)
            installer.afterSwap = {}
            let previous = try XCTUnwrap(installer.install())
            XCTAssertTrue(installer.didMigrateSigning)
            XCTAssertEqual(stopped, 2)
            XCTAssertEqual(try NativeInstaller.verifySignedBundle(previous), .init("adhoc"))
            XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("config.json")), settings)
        }
    }
    func testReleaseIdentityUpdateNeedsNoMigrationConsent() throws {
        let (installer, root, app, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try existingApp(app, marker: "old")
        installer.verify = { _ in .init("designated => " + NativeInstaller.releaseRequirement) }
        installer.verifyMigrationTarget = { _ in XCTFail("Same identity must not request migration") }
        XCTAssertNil(try installer.install())
        XCTAssertFalse(installer.didMigrateSigning)
        XCTAssertFalse(installer.keepPrevious)
    }
    func testSigningMigrationCannotTargetOtherCertificatesOrAnUnverifiedRelease() throws {
        let (installer, root, app, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try existingApp(app, marker: "old")
        installer.allowSigningMigration = true
        installer.verify = { url in .init(url == app ? "another certificate" : "designated => arbitrary replacement") }
        XCTAssertThrowsError(try installer.install())
        installer.verify = { url in .init(url == app ? "adhoc" : "designated => arbitrary replacement") }
        XCTAssertThrowsError(try installer.install())
        installer.verify = { url in .init(url == app ? "another certificate" : "designated => " + NativeInstaller.releaseRequirement) }
        installer.verifyMigrationTarget = { _ in throw NativeInstallError.message("Unverified release") }
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("old")), "old")
    }
    func testLaunchFailureReportsTheCommittedDestinationAndPreservedRollbackPath() throws {
        let (installer, root, app, _) = try fixture(pathSuffix: " quote's \"space\" $literal; untouched"); defer { try? FileManager.default.removeItem(at: root) }
        try existingApp(app, marker: "old")
        installer.keepPrevious = true
        installer.launch = { _ in throw NativeInstallError.message("fixture launch failed") }
        var rollback: String?
        XCTAssertThrowsError(try installer.install()) { error in
            guard let previous = installer.previousApp else { return XCTFail("Missing rollback path") }
            let message = error.localizedDescription
            let body = "Vella 2.0 was installed but didn't start (fixture launch failed). Your previous version is kept at \(previous.path). To go back, quit Vella and run:"
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            let command =
                "(app=\(quote(app.path)); backup=\(quote(previous.path)); "
                + "[ -d \"$backup\" ] || { printf '%s\\n' 'Rollback not performed: previous app backup is missing; nothing changed.' >&2; exit 1; }; "
                + "pgrep -x Vella >/dev/null 2>&1; case $? in 1) ;; 0) printf '%s\\n' 'Rollback not performed: Vella is running. Quit Vella and try again.' >&2; exit 1 ;; "
                + "*) printf '%s\\n' 'Rollback not performed: could not check whether Vella is running; nothing changed.' >&2; exit 1 ;; esac; "
                + "stamp=$(date +%Y%m%d-%H%M%S) || exit 1; failed=\"${app%.app}.failed.$stamp.$$.app\"; "
                + "[ ! -e \"$failed\" ] && [ ! -L \"$failed\" ] && mv -n -- \"$app\" \"$failed\" && [ ! -e \"$app\" ] && [ ! -L \"$app\" ] "
                + "&& mv -n -- \"$backup\" \"$app\" && [ ! -e \"$backup\" ] "
                + "|| { printf '%s\\n' 'Rollback stopped: bundles were kept; check the app and backup paths before retrying.' >&2; exit 1; })"
            XCTAssertEqual(message, body + "\n" + command)
            XCTAssertFalse(message.contains("previous:"))
            rollback = message.components(separatedBy: "\n").last
            if let directory = ProcessInfo.processInfo.environment["VELLA_RENDER_EXACT_TEXT_DIR"] {
                try? (message + "\n").write(to: URL(fileURLWithPath: directory).appendingPathComponent("installer-launch-failure.txt"), atomically: true, encoding: .utf8)
            }
            XCTAssertEqual(try? Data(contentsOf: previous.appendingPathComponent("old")), Data("old".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Vella").path))
        }
        let command = try XCTUnwrap(rollback)
        XCTAssertFalse(command.contains("\n"), "One raw copy-pasteable line")
        let installed = try bundleSnapshot(app)
        let first = try executeRollback(command)
        XCTAssertEqual(first.status, 0, first.output)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("old")), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(installer.previousApp).path))
        let failed = try FileManager.default.contentsOfDirectory(at: app.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Vella.failed.") }
        XCTAssertEqual(failed.count, 1)
        let retained = try XCTUnwrap(failed.first)
        XCTAssertNotNil(retained.lastPathComponent.range(of: #"^Vella\.failed\.\d{8}-\d{6}\.\d+\.app$"#, options: .regularExpression))
        XCTAssertEqual(try bundleSnapshot(retained), installed, "Keep every byte of the failed 2.0 app beside the restored app")
        let restored = try bundleSnapshot(app)
        let second = try executeRollback(command)
        XCTAssertEqual(second.status, 1)
        XCTAssertEqual(second.output, "Rollback not performed: previous app backup is missing; nothing changed.\n")
        XCTAssertEqual(try bundleSnapshot(app), restored, "A second paste must leave the restored app intact")
        XCTAssertEqual(try bundleSnapshot(retained), installed)
    }

    /// Inject only the read-only process check. All printed moves run against disposable bundles;
    /// no real Vella process is queried, launched, stopped or touched.
    private func executeRollback(_ command: String, processStatus: Int = 1) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "pgrep() { [ \"$*\" = '-x Vella' ] || return 2; return \(processStatus); }; rm() { exit 99; }; " + command]
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func bundleSnapshot(_ bundle: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: bundle.path))
        for case let relative as String in enumerator {
            let path = bundle.appendingPathComponent(relative)
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[relative] = try Data(contentsOf: path) }
        }
        return result
    }

    func testPrintedRollbackRefusesMissingBackupRunningAppAndProcessCheckFailureWithoutMovingAnything() throws {
        for cause in ["missing", "running", "process-check"] {
            let (installer, root, app, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try existingApp(app, marker: "old"); installer.keepPrevious = true
            installer.launch = { _ in throw NativeInstallError.message("fixture launch failed") }
            var command: String?
            XCTAssertThrowsError(try installer.install()) { error in command = error.localizedDescription.components(separatedBy: "\n").last }
            let previous = try XCTUnwrap(installer.previousApp)
            let old = try bundleSnapshot(previous), installed = try bundleSnapshot(app)
            // Preserve the fixture backup elsewhere to model absence without deleting it.
            if cause == "missing" { try FileManager.default.moveItem(at: previous, to: root.appendingPathComponent("preserved-backup")) }
            let names = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
            let result = try executeRollback(try XCTUnwrap(command), processStatus: cause == "running" ? 0 : (cause == "process-check" ? 2 : 1))
            XCTAssertEqual(result.status, 1, cause)
            let reason =
                cause == "missing"
                ? "previous app backup is missing; nothing changed."
                : (cause == "running" ? "Vella is running. Quit Vella and try again." : "could not check whether Vella is running; nothing changed.")
            XCTAssertEqual(result.output, "Rollback not performed: " + reason + "\n")
            XCTAssertEqual(try bundleSnapshot(app), installed, cause)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path), names, "No moves on refusal")
            XCTAssertEqual(try bundleSnapshot(cause == "missing" ? root.appendingPathComponent("preserved-backup") : previous), old)
        }
    }

    func testSigningMismatchAndMalformedConfigArePreserved() throws {
        for cause in ["signature", "config"] {
            let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if cause == "signature" {
                try existingApp(app, marker: "old")
                installer.verify = { path in .init(path == app ? "designated => other certificate" : "adhoc") }
            } else {
                try Data("{invalid".utf8).write(to: support.appendingPathComponent("config.json"))
            }
            XCTAssertThrowsError(try installer.install())
            if cause == "config" { XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("config.json")), "{invalid") }
            if cause == "signature" { XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("old")), "old") }
        }
    }
}

final class InstallReadinessTests: XCTestCase {
    private func state(_ json: String?, alive: Set<Int32> = [42]) -> InstallReadiness.State {
        InstallReadiness.evaluate(status: json.map { Data($0.utf8) }) { alive.contains($0) }
    }
    func testFreshInstallIsReadyWithNothingLoaded() {
        XCTAssertEqual(state(#"{"app_pid":42,"loading":null,"models":{},"launch_set":[]}"#), .ready("Vella running (pid 42), no model loaded"))
        XCTAssertTrue(state(#"{"app_pid":42}"#).isReady, "no launch set recorded")
    }
    func testLaunchSetWaitsForItsModels() {
        let waiting = #"{"app_pid":42,"loading":null,"models":{},"launch_set":["parakeet-v3"]}"#
        XCTAssertEqual(state(waiting), .waiting("waiting for parakeet-v3 to load"))
        XCTAssertEqual(
            state(#"{"app_pid":42,"models":{},"launch_set":["parakeet-v3"],"error":"Worker exited (code 1)."}"#),
            .failing("parakeet-v3 not loaded: Worker exited (code 1)."))
        // A refused configured-hot model is settled but degraded, never ready.
        XCTAssertEqual(
            state(#"{"app_pid":42,"models":{},"launch_set":["parakeet-v3"],"refused":{"model":"parakeet-v3","message":"needs ~2.1 GB; ~0.9 GB free"}}"#),
            .degraded("Vella running (pid 42), parakeet-v3 not loaded: needs ~2.1 GB; ~0.9 GB free"))
        XCTAssertEqual(
            state(#"{"app_pid":42,"models":{},"launch_set":["a","b"],"refused":{"model":"a","message":"m"}}"#),
            .waiting("waiting for a, b to load"), "a refusal settles only its own model")
        XCTAssertEqual(
            state(#"{"app_pid":42,"models":{"parakeet-v3":{"precision":"4b"}},"launch_set":["parakeet-v3"]}"#),
            .ready("Vella running (pid 42), model loaded: parakeet-v3 (4b)"))
    }
    // The ready command never turns a broken launch set into `ready`.
    func testWaitReportsFailingLaunchSetAsDegradedAfterSettleNeverReady() {
        var clock = Date(timeIntervalSince1970: 0)
        let failing = Data(#"{"app_pid":42,"models":{},"launch_set":["parakeet-v3"],"error":"Worker exited (code 1)."}"#.utf8)
        let result = InstallReadiness.wait(
            read: { failing }, isInstalledApp: { $0 == 42 }, timeout: 1800, interval: 5, settle: 60,
            now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        XCTAssertEqual(result.status, InstallReadiness.degradedExit)
        XCTAssertEqual(result.line, "degraded: Vella running, parakeet-v3 not loaded: Worker exited (code 1).")
        XCTAssertEqual(clock.timeIntervalSince1970, 60, "waits out the settle time for a restart first")
        let refused = Data(#"{"app_pid":42,"models":{},"launch_set":["a"],"refused":{"model":"a","message":"m"}}"#.utf8)
        XCTAssertEqual(
            InstallReadiness.wait(
                read: { refused }, isInstalledApp: { $0 == 42 }, timeout: 10, interval: 5, settle: 60,
                now: { clock }, sleep: { clock = clock.addingTimeInterval($0) }
            ).status, InstallReadiness.degradedExit)
        let ok = Data(#"{"app_pid":42,"models":{"a":{"precision":"4b"}},"launch_set":["a"]}"#.utf8)
        XCTAssertEqual(InstallReadiness.wait(read: { ok }, isInstalledApp: { $0 == 42 }, timeout: 10, interval: 5, settle: 60).status, InstallReadiness.readyExit)
        XCTAssertEqual(
            InstallReadiness.wait(
                read: { nil }, isInstalledApp: { _ in true }, timeout: 10, interval: 5, settle: 60,
                now: { clock }, sleep: { clock = clock.addingTimeInterval($0) }
            ).status, InstallReadiness.notReadyExit)
    }
    /// install-prepared.sh with a fake prepared app whose tool reports each readiness outcome.
    func testInstallScriptDeletesThePreviousAppOnlyWhenReady() throws {
        try Integration.require() // runs scripts/install-prepared.sh
        let script = Repository.root
            .appendingPathComponent("scripts/install-prepared.sh")
        for (readyStatus, accept, expectedExit, keepsPrevious) in [(0, false, 0, false), (3, false, 1, true), (1, false, 1, true), (3, true, 0, true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-install-script-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let helpers = root.appendingPathComponent("Prepared.app/Contents/Helpers")
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let previous = root.appendingPathComponent("Vella.previous.app")
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            let tool = helpers.appendingPathComponent("VellaInstallTool")
            try """
            #!/bin/bash
            case "$1" in
              install) echo "installed x"; echo "previous: \(previous.path)";;
              ready) [[ \(readyStatus) == 0 ]] && echo "ready: fixture"; [[ \(readyStatus) == 3 ]] && echo "degraded: fixture"; exit \(readyStatus);;
            esac
            """.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, root.appendingPathComponent("Prepared.app").path]
            var env = [
                "PATH": "/usr/bin:/bin", "HOME": root.path,
                "VELLA_DESTINATION_APP": root.appendingPathComponent("Vella.app").path, "VELLA_SUPPORT_DIR": root.appendingPathComponent("support").path
            ]
            if accept { env["VELLA_ACCEPT_DEGRADED"] = "1" }
            process.environment = env
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, Int32(expectedExit), "ready exit \(readyStatus), accept \(accept)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: previous.path), keepsPrevious, "ready exit \(readyStatus), accept \(accept)")
        }
    }

    func testNotReadyWhileLoading() {
        XCTAssertEqual(state(#"{"app_pid":42,"loading":"parakeet-v3","models":{},"launch_set":[]}"#), .waiting("loading parakeet-v3"))
    }
    func testNotReadyBeforeTheAppAnswers() {
        XCTAssertEqual(state(nil), .waiting("Vella has not written its status yet"))
        XCTAssertEqual(state("{\"app_pid\":"), .waiting("status file is incomplete"))
        XCTAssertEqual(state(#"{"app_pid":7,"models":{},"launch_set":[]}"#), .waiting("status is from an earlier launch"))
        XCTAssertEqual(state(#"{"models":{},"launch_set":[]}"#), .waiting("status is from an earlier launch"))
    }
    func testLaunchPassesOnlyANonDefaultSupportFolder() {
        let app = URL(fileURLWithPath: "/Users/x/Applications/Vella.app")
        XCTAssertEqual(NativeInstaller.launchArguments(app, support: nil), [app.path])
        XCTAssertEqual(NativeInstaller.launchArguments(app, support: NativeInstaller.defaultSupport), [app.path])
        XCTAssertEqual(
            NativeInstaller.launchArguments(app, support: URL(fileURLWithPath: "/tmp/iso/Vella/")),
            ["--env", "VELLA_SUPPORT_DIR=/tmp/iso/Vella", app.path])
    }
    func testOnlyApplicationsFoldersCountAsOtherInstallations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(NativeInstaller.isInstallLocation(URL(fileURLWithPath: "/Applications/Vella.app")))
        XCTAssertTrue(NativeInstaller.isInstallLocation(home.appendingPathComponent("Applications/Vella.app")))
        XCTAssertFalse(NativeInstaller.isInstallLocation(home.appendingPathComponent("src/Vella/.build/releases/1.0.0/Vella.app")))
        XCTAssertFalse(NativeInstaller.isInstallLocation(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x/Vella.app")))
    }
    func testRunsMatchesTheInstalledExecutableOnly() throws {
        XCTAssertFalse(InstallReadiness.runs(getpid(), app: URL(fileURLWithPath: "/nonexistent/Vella.app")))
        XCTAssertFalse(InstallReadiness.runs(999_999, app: URL(fileURLWithPath: "/Applications/Vella.app")))
    }
}
