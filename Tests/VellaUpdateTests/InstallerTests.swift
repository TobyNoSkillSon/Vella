import Foundation
import XCTest
import VellaCore
@testable import VellaUpdate

/// The hand-off install: swap, readiness, rollback. Launching, quitting and the app's status file are simulated; the
/// swap itself runs for real on fixture bundles in a temporary directory, with a fake clock.
final class InstallerTests: XCTestCase {
    var root: URL!, applications: URL!, destination: URL!, support: URL!, stagedDirectory: URL!
    var clock = Date(timeIntervalSince1970: 0)
    var launched: [String] = []
    var terminated = 0

    override func setUpWithError() throws {
        root = try ReleaseFixture.temporaryRoot()
        applications = root.appendingPathComponent("Applications")
        destination = try ReleaseFixture.app(at: applications.appendingPathComponent("Vella.app"), version: "1.0.0", sign: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("Contents/old-marker"))
        support = root.appendingPathComponent("Library/Application Support/Vella")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        stagedDirectory = root.appendingPathComponent("staged")
        try ReleaseFixture.app(at: stagedDirectory.appendingPathComponent("Vella.app"), version: "1.0.1", sign: false)
        clock = Date(timeIntervalSince1970: 0); launched = []; terminated = 0
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// `status(elapsed)`: the app's worker-status.json at that many seconds into the install.
    func makeInstaller(status: @escaping (TimeInterval) -> Data?) -> UpdateInstaller {
        let staged = StagedUpdate(version: "1.0.1", directory: stagedDirectory.path, app: stagedDirectory.appendingPathComponent("Vella.app").path, sha256: "")
        let plan = InstallPlan(staged: staged, destination: destination.path, from: "1.0.0", waitForPID: 999_999, supportDirectory: support.path)
        let installer = UpdateInstaller(plan: plan, env: [:])
        installer.configure = {
            $0.verify = { _ in .init("adhoc") }; $0.stop = { _ in false }
        }
        installer.isAlive = { _ in false }
        installer.isInstalledApp = { pid, _ in pid == 4242 }
        installer.launch = { [unowned self] app in self.launched.append(Updater.bundleVersion(app) ?? "?") }
        installer.terminate = { [unowned self] _ in self.terminated += 1 }
        installer.now = { [unowned self] in self.clock }
        installer.sleep = { [unowned self] in self.clock += $0 }
        installer.readStatus = { [unowned self] _ in status(self.clock.timeIntervalSince1970) }
        return installer
    }

    func status(
        pid: Int32 = 4242, loading: String? = nil, models: [String] = [], launchSet: [String] = [], error: String? = nil,
        refused: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "app_pid": pid, "models": Dictionary(uniqueKeysWithValues: models.map { ($0, ["precision": "4b"]) }),
            "launch_set": launchSet
        ]
        if let loading { object["loading"] = loading }
        if let error { object["error"] = error }
        if let refused { object["refused"] = ["model": refused, "message": "needs 3 GB, 1 GB free", "at": 0] }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    var installedVersion: String? { Updater.bundleVersion(destination) }
    var hasOldMarker: Bool { FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/old-marker").path) }
    var leftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []).filter { $0 != "Vella.app" } }
    var result: UpdateResult? { UpdateResult.take(support: support) }

    func assertRolledBack(_ text: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.hasSuffix("Vella 1.0.0 was restored"), error.localizedDescription, file: file, line: line)
        }
        XCTAssertEqual(installedVersion, "1.0.0", file: file, line: line); XCTAssertTrue(hasOldMarker, file: file, line: line)
        XCTAssertEqual(launched, ["1.0.1", "1.0.0"], "the new version, then the restored one", file: file, line: line)
        XCTAssertEqual(terminated, 1, file: file, line: line)
        XCTAssertEqual(leftovers, [], file: file, line: line)
        let written = result
        XCTAssertEqual(written?.ok, false, file: file, line: line); XCTAssertEqual(written?.to, "1.0.1", file: file, line: line)
        XCTAssertTrue(written?.message.contains(text) == true, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path), file: file, line: line)
    }

    func testReadyVersionReplacesThePreviousApp() throws {
        try makeInstaller { _ in self.status() }.run()
        XCTAssertEqual(installedVersion, "1.0.1"); XCTAssertFalse(hasOldMarker)
        XCTAssertEqual(launched, ["1.0.1"]); XCTAssertEqual(terminated, 0)
        XCTAssertEqual(leftovers, [], "the previous app is deleted once the new one is ready")
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
    }

    func testReadyAfterLoadingTheLaunchSet() throws {
        try makeInstaller { t in
            t < 30
                ? self.status(loading: "parakeet-v3", launchSet: ["parakeet-v3"])
                : self.status(models: ["parakeet-v3"], launchSet: ["parakeet-v3"])
        }.run()
        XCTAssertEqual(installedVersion, "1.0.1"); XCTAssertEqual(leftovers, [])
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, 30)
    }

    func testNoAnswerRollsBack() {
        assertRolledBack("Vella 1.0.1 did not start (no answer after 120 s)") { try makeInstaller { _ in nil }.run() }
    }

    func testStatusFromTheOldAppIsNoAnswer() {
        assertRolledBack("no answer after 120 s") { try makeInstaller { _ in self.status(pid: 1111) }.run() }
    }

    func testExitAfterStartingRollsBack() {
        assertRolledBack("the new version exited") {
            try makeInstaller { t in t < 5 ? self.status(loading: "parakeet-v3", launchSet: ["parakeet-v3"]) : nil }.run()
        }
    }

    func testFailingLaunchSetModelRollsBackAfterSettling() {
        assertRolledBack("parakeet-v3 not loaded: worker crashed") {
            try makeInstaller { _ in self.status(launchSet: ["parakeet-v3"], error: "worker crashed") }.run()
        }
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, 60, "failures inside the settle time are retried by the app")
    }

    func testLoadingTooLongRollsBack() {
        let installer = makeInstaller { _ in self.status(loading: "parakeet-v3", launchSet: ["parakeet-v3"]) }
        installer.loadTimeout = 600
        assertRolledBack("still loading parakeet-v3 after 10 min") { try installer.run() }
    }

    func testMemoryRefusalKeepsTheNewVersion() throws {
        try makeInstaller { _ in self.status(launchSet: ["qwen3-asr"], refused: "qwen3-asr") }.run()
        XCTAssertEqual(installedVersion, "1.0.1"); XCTAssertEqual(leftovers, []); XCTAssertNil(result)
    }

    /// A dictation started after the app handed off: nothing is swapped, the previous version is started again.
    func testBusyDictationRefusesAndRelaunchesThePreviousVersion() throws {
        try Data(#"{"phase":"recording"}"#.utf8).write(to: support.appendingPathComponent("dictation-status.json"))
        XCTAssertThrowsError(try makeInstaller { _ in self.status() }.run()) { XCTAssertTrue($0.localizedDescription.contains("Finish dictation")) }
        XCTAssertEqual(installedVersion, "1.0.0"); XCTAssertTrue(hasOldMarker)
        XCTAssertEqual(launched, ["1.0.0"]); XCTAssertEqual(leftovers, [])
        XCTAssertTrue(result?.message.contains("Finish dictation") == true)
    }

    func testIdentityMismatchAtTheSwapRelaunchesThePreviousVersion() throws {
        let installer = makeInstaller { _ in self.status() }
        let destination = self.destination!
        installer.configure = { native in
            native.verify = { app in app.standardizedFileURL == destination.standardizedFileURL ? .init("designated => cert") : .init("adhoc") }
            native.stop = { _ in false }
        }
        XCTAssertThrowsError(try installer.run()) { XCTAssertTrue($0.localizedDescription.contains("signing identity differs")) }
        XCTAssertEqual(installedVersion, "1.0.0"); XCTAssertEqual(launched, ["1.0.0"])
    }

    func testAppThatDoesNotQuitIsLeftAlone() {
        let installer = makeInstaller { _ in self.status() }
        installer.isAlive = { _ in true }
        XCTAssertThrowsError(try installer.run()) { XCTAssertTrue($0.localizedDescription.contains("did not quit")) }
        XCTAssertEqual(installedVersion, "1.0.0"); XCTAssertEqual(launched, []); XCTAssertEqual(terminated, 0)
        XCTAssertNil(result, "the running app reports this itself")
    }

    func testPlanRoundTrip() throws {
        let plan = makeInstaller { _ in nil }.plan
        XCTAssertEqual(try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan)), plan)
    }
}
