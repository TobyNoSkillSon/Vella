import AppKit
import XCTest
import VellaCore
import VellaUpdate
@testable import Vella

/// Answers the controller's requests from fixtures; nothing leaves the process (unrouted URLs answer 404).
final class StubReleaseServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    private static let lock = NSLock()
    static func reset() { lock.withLock { routes = [:]; requests = [] } }
    static func serve(_ url: String, _ body: Data) { lock.withLock { routes[url] = body } }
    static var requested: [String] { lock.withLock { requests } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body = Self.lock.withLock { () -> Data? in Self.requests.append(url.absoluteString); return Self.routes[url.absoluteString] }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UpdateControllerTests: XCTestCase {
    static let api = "https://releases.invalid/latest", base = "https://releases.invalid/download"
    let release = ReleaseInfo(tag: "v1.0.1", version: SemanticVersion("1.0.1")!, name: "Vella 1.0.1", body: "Faster loads.")
    var root: URL!
    var suite: String!
    var defaults: UserDefaults!

    override func setUpWithError() throws {
        StubReleaseServer.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-update-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "VellaUpdateTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        StubReleaseServer.reset()
    }

    @MainActor func controller(current: String = "1.0.0") -> UpdateController {
        let controller = UpdateController(current: current, defaults: defaults, enabled: true)
        controller.source = { UpdateSource(apiURL: URL(string: Self.api)!, baseURL: URL(string: Self.base)!) }
        controller.protocolClasses = [StubReleaseServer.self]
        controller.presentsAlerts = false
        controller.support = root.appendingPathComponent("support")
        controller.handOff = { _ in XCTFail("no hand-off expected") }
        return controller
    }

    @MainActor func testOrangeItemSitsUnderSupport() throws {
        let updates = controller()
        updates.preview(.available(release))
        let delegate = AppDelegate(model: DictationController(configurationURL: root.appendingPathComponent("config.json")), updates: updates)
        delegate.rebuildMenu()
        let items = delegate.menu.items
        let support = try XCTUnwrap(items.firstIndex { $0.title == "Support the developer…" })
        let item = items[support + 1]
        XCTAssertEqual(item.title, "Update to 1.0.1…")
        XCTAssertEqual(item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemOrange)
        XCTAssertTrue(item.isEnabled); XCTAssertNotNil(item.image)
        XCTAssertEqual(items[support + 2].title, "Quit Vella")
        updates.preview(.downloading(release)); delegate.rebuildMenu()
        let downloading = try XCTUnwrap(delegate.menu.items.first { $0.title == "Downloading 1.0.1…" })
        XCTAssertFalse(downloading.isEnabled)
        updates.preview(.idle); delegate.rebuildMenu()
        XCTAssertFalse(delegate.menu.items.contains { $0.title.hasPrefix("Update") || $0.title.hasPrefix("Downloading") })
    }

    @MainActor func testPopupNamesTheVersionAndNotes() {
        let alert = controller().confirmation(release)
        XCTAssertEqual(alert.messageText, "Update to Vella 1.0.1?")
        XCTAssertTrue(alert.informativeText.hasPrefix("You have 1.0.0. Settings, models and recordings are kept; Vella restarts."))
        XCTAssertTrue(alert.informativeText.hasSuffix("Faster loads."))
        XCTAssertEqual(alert.buttons.map(\.title), ["Update Now", "Later"])
    }

    @MainActor func testCheckOffersAndRemembersANewerRelease() async throws {
        StubReleaseServer.serve(Self.api, try JSONSerialization.data(withJSONObject: ["tag_name": "v1.0.1", "name": "Vella 1.0.1", "body": "Faster loads."]))
        let first = controller()
        await first.runCheck()
        XCTAssertEqual(first.machine.phase, .available(release))
        XCTAssertEqual(StubReleaseServer.requested, [Self.api])
        // Relaunch within 24 hours: the offer is back without a request.
        let relaunched = controller()
        relaunched.start()
        XCTAssertEqual(relaunched.machine.phase.menuTitle, "Update to 1.0.1…")
        XCTAssertEqual(StubReleaseServer.requested, [Self.api])
        // Updated meanwhile: the offer is dropped.
        let updated = controller(current: "1.0.1")
        updated.start()
        XCTAssertEqual(updated.machine.phase, .idle)
        XCTAssertNil(defaults.dictionary(forKey: UpdateController.offerKey))
    }

    @MainActor func testDisabledControllerNeverAsks() async {
        let disabled = UpdateController(current: "1.0.0", defaults: defaults, enabled: false)
        disabled.protocolClasses = [StubReleaseServer.self]
        disabled.start(); await disabled.runCheck()
        XCTAssertEqual(StubReleaseServer.requested, [])
        XCTAssertEqual(disabled.machine.phase, .idle)
    }

    @MainActor func testBusyRefusalDownloadsNothing() async {
        let updates = controller()
        updates.blocker = { "recording" }
        updates.preview(.available(release))
        await updates.install()
        XCTAssertEqual(updates.machine.phase, .available(release), "the offer stays")
        XCTAssertEqual(updates.machine.lastError, "Vella is recording")
        XCTAssertEqual(StubReleaseServer.requested, [], "nothing downloaded")
        XCTAssertEqual(updates.menuItem()?.toolTip, "Last attempt failed: Vella is recording")
    }

    @MainActor func testBlockerReasons() {
        let model = DictationController(configurationURL: root.appendingPathComponent("config.json"))
        let delegate = AppDelegate(model: model, updates: controller())
        delegate.runtimeLoading = { nil }
        XCTAssertNil(delegate.updateBlocker())
        for (phase, reason) in [(DictationController.Phase.recording, "recording"), (.preparing, "preparing a dictation"), (.transcribing, "transcribing"),
                                (.success, "pasting a transcript")] {
            model.phase = phase
            XCTAssertEqual(delegate.updateBlocker(), reason)
        }
        model.phase = .failed
        XCTAssertNil(delegate.updateBlocker(), "a failed dictation keeps its audio; it does not block an update")
        model.phase = .idle
        delegate.runtimeLoading = { "Parakeet v3" }
        XCTAssertEqual(delegate.updateBlocker(), "loading Parakeet v3")
        delegate.runtimeLoading = { nil }
        delegate.modelsMenu.controller.dictation.downloadingID = "parakeet-v3-4b"
        XCTAssertEqual(delegate.updateBlocker(), "downloading a model")
        delegate.modelsMenu.controller.dictation.downloadingID = nil
    }

    /// Download, verification and the wait for idle through the real updater, with a fixture release.
    @MainActor func testVerifiedDownloadWaitsUntilIdleThenHandsOff() async throws {
        let running = try fixtureApp(root.appendingPathComponent("installed/Vella.app"), version: "1.0.0")
        let staging = root.appendingPathComponent("release")
        try fixtureApp(staging.appendingPathComponent("Vella.app"), version: "1.0.1")
        let zip = staging.appendingPathComponent("Vella-1.0.1-arm64.zip")
        XCTAssertEqual(run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent",
                                              staging.appendingPathComponent("Vella.app").path, zip.path]), 0)
        let bytes = try Data(contentsOf: zip)
        let hash = try Updater.sha256(of: zip)
        StubReleaseServer.serve("\(Self.base)/Vella-1.0.1-arm64.zip", bytes)
        StubReleaseServer.serve("\(Self.base)/SHA256SUMS", Data("\(hash)  Vella-1.0.1-arm64.zip\n".utf8))

        let updates = controller()
        updates.runningApp = running
        updates.idlePollNanoseconds = 1_000_000
        var calls = 0
        updates.blocker = { calls += 1; return (2...4).contains(calls) ? "recording" : nil }     // busy right after the download
        var phases: [UpdatePhase] = []
        updates.onChange = { phases.append(updates.machine.phase) }
        var handed: StagedUpdate?
        updates.handOff = { handed = $0 }
        updates.preview(.available(release))
        await updates.install()
        let staged = try XCTUnwrap(handed)
        defer { try? FileManager.default.removeItem(atPath: staged.directory) }
        XCTAssertEqual(staged.version, "1.0.1"); XCTAssertEqual(staged.sha256, hash)
        XCTAssertEqual(phases, [.downloading(release), .waitingForIdle(release), .installing(release)])
        XCTAssertNil(updates.machine.lastError)
    }

    @discardableResult
    func fixtureApp(_ app: URL, version: String) throws -> URL {
        let contents = app.appendingPathComponent("Contents")
        for file in Updater.requiredExecutables {
            let path = contents.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: path)
        }
        let metallib = contents.appendingPathComponent(Updater.metallib)
        try FileManager.default.createDirectory(at: metallib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture shader".utf8).write(to: metallib)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.vella.dictation", "CFBundleExecutable": "Vella", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let helpers = Updater.requiredExecutables.filter { $0 != "MacOS/Vella" }.map { contents.appendingPathComponent($0).path }
        XCTAssertEqual(run("/usr/bin/codesign", ["--force", "--sign", "-"] + helpers), 0)
        XCTAssertEqual(run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]), 0)
        return app
    }

    func run(_ tool: String, _ arguments: [String]) -> Int32 { Updater.run(tool, arguments).status }
}
