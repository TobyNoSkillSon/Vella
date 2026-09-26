import XCTest
import Foundation
@testable import VellaCore

final class NativeInstallerTests: XCTestCase {
    private func fixture() throws -> (NativeInstaller, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-native-install-\(UUID())")
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
    func testSigningMismatchAndMalformedConfigArePreserved() throws {
        for cause in ["signature", "config"] {
            let (installer, root, app, support) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if cause == "signature" {
                try existingApp(app, marker: "old")
                installer.verify = { path in .init(path == app ? "designated => other certificate" : "adhoc") }
            } else { try Data("{invalid".utf8).write(to: support.appendingPathComponent("config.json")) }
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
        XCTAssertEqual(state(#"{"app_pid":42,"models":{},"launch_set":["parakeet-v3"],"error":"Worker exited (code 1)."}"#),
                       .failing("parakeet-v3 not loaded: Worker exited (code 1)."))
        XCTAssertEqual(state(#"{"app_pid":42,"models":{},"launch_set":["parakeet-v3"],"refused":{"model":"parakeet-v3","message":"needs ~2.1 GB; ~0.9 GB free"}}"#),
                       .ready("Vella running (pid 42), parakeet-v3 not loaded: needs ~2.1 GB; ~0.9 GB free"))
        XCTAssertEqual(state(#"{"app_pid":42,"models":{},"launch_set":["a","b"],"refused":{"model":"a","message":"m"}}"#),
                       .waiting("waiting for a, b to load"), "a refusal settles only its own model")
        XCTAssertEqual(state(#"{"app_pid":42,"models":{"parakeet-v3":{"precision":"4b"}},"launch_set":["parakeet-v3"]}"#),
                       .ready("Vella running (pid 42), model loaded: parakeet-v3 (4b)"))
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
        XCTAssertEqual(NativeInstaller.launchArguments(app, support: URL(fileURLWithPath: "/tmp/iso/Vella/")),
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
