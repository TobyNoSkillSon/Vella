import XCTest
import AppKit
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// The "from Heimdall" row (docs/HEIMDALL.md) through the real bridge, runtime and fake stdio workers: its three
/// states, the explicit choice, switching both ways, failed switches, and a dictation in flight during a switch.
/// Nothing is installed, downloaded or opened; no model inference.
@MainActor final class HeimdallRowTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-heimdall-row-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    final class Counters {
        var own = 0
        var fetches = 0
        var hold: CheckedContinuation<Void, Never>?
        var holding = false
    }
    struct Env {
        let f: TwoFamilyFixture
        let bus: MemoryHeimdallBus
        let link: HeimdallLink
        let model: DictationController
        let counts: Counters
        var installed: Bool
    }
    private func env(installed: Bool = true) throws -> Env {
        let f = try TwoFamilyFixture(root)
        let counts = Counters()
        let backend = f.backend
        let permission = InsertionPermission(isTrusted: { true }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(
            insertionPermission: permission, pasteboard: NSPasteboard.withUniqueName(), stopCapture: { _ in },
            transcriptionRequest: { url, config in
                counts.own += 1
                if counts.holding { await withCheckedContinuation { counts.hold = $0 } }
                return try await backend.transcribe(url, config: config)
            }, configurationURL: f.runtime.configURL, streamingBackend: f.stream, captureDestination: { { "test: no destination" } },
            backend: backend, monitorDefaultInput: false)
        f.bridge.attach(controller: f.controller, model: model)
        model.fetchModel = { (_: DictationController.ModelOffer) async throws -> String in counts.fetches += 1; throw CancellationError() }
        let bus = MemoryHeimdallBus()
        let link = HeimdallLink(bus: bus, announcesDictation: false)
        link.findInstalled = { installed }
        link.acceptSocket = { _ in true }
        f.bridge.attachHeimdall(link)
        model.heimdall = link
        link.start()
        return Env(f: f, bus: bus, link: link, model: model, counts: counts, installed: installed)
    }
    /// A one-second dictation recorded with the current choice, transcribed as Finish does.
    @discardableResult private func dictate(_ e: Env) async throws -> RecordingSession {
        var config = try e.f.config()
        if !config.model.isEmpty { config = try config.forRecording() }
        config = e.link.recordingConfiguration(config)
        let session = try RecordingSession(root: root.appendingPathComponent("Recordings"), config: config)
        let writer = try SegmentedPCMWriter(session: session)
        try (0..<16_000).map { Float(0.1 * sin(Double($0) * 0.17)) }.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        XCTAssertTrue(e.model.labTranscribe(session))
        for _ in 0..<1000 where e.model.phase == .transcribing || e.model.phase == .preparing { try await Task.sleep(nanoseconds: 5_000_000) }
        return session
    }
    private var source: (Env) throws -> DictationSource? { { try $0.f.config().dictationSource } }

    func testThreeStatesKeepTheTableStill() throws {
        let e = try env(installed: false); defer { e.f.close() }
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .absent, chosen: false))
        let height = ModelTable.height(e.f.controller)
        e.link.findInstalled = { true }
        e.link.refreshInstalled()
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .offline, chosen: true), "installed, never chose: the default, offline")
        e.bus.ready("/tmp/vh-row.sock")
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .present, chosen: true))
        e.bus.gone()
        XCTAssertEqual(e.f.controller.heimdall?.presence, .offline)
        XCTAssertEqual(ModelTable.height(e.f.controller), height, "no row appears, disappears or moves")
        XCTAssertNil(try e.f.config().dictationSource, "a default is never written as a choice")
    }
    func testClicksAndTheUnsetProjectLink() throws {
        let e = try env(installed: false); defer { e.f.close() }
        let c = e.f.controller
        var opened: [URL] = [], used = 0
        c.openURL = { opened.append($0) }
        c.useHeimdall = { used += 1 }
        XCTAssertNil(c.heimdallProjectURL, "no public page yet")
        c.performHeimdall()
        XCTAssertEqual(opened, [], "absent, unset URL: nothing opens")
        c.heimdallProjectURL = URL(string: "https://example.com/heimdall")
        c.performHeimdall()
        XCTAssertEqual(opened, [URL(string: "https://example.com/heimdall")!])
        c.heimdall = .init(presence: .offline, chosen: false); c.performHeimdall()
        c.heimdall = .init(presence: .present, chosen: true); c.performHeimdall()
        XCTAssertEqual(used, 0, "offline or already chosen: nothing")
        c.heimdall = .init(presence: .present, chosen: false); c.performHeimdall()
        XCTAssertEqual(used, 1)
        XCTAssertEqual(opened.count, 1)
    }
    func testBorrowingThenOwnThenBorrowing() async throws {
        let server = try FakeHeimdallServer(reply: .ok("borrowed")); defer { server.stop() }
        let e = try env(); defer { e.f.close() }
        e.bus.ready(server.path)
        try await dictate(e)
        XCTAssertEqual(e.model.lastText, "borrowed")
        XCTAssertEqual(e.counts.own, 0)
        XCTAssertTrue(e.f.runtime.status.models.isEmpty, "the borrowed row loads nothing of Vella's")
        // An own model through its normal Load: it becomes the explicit choice and borrowing detaches.
        try await e.f.load(e.f.alpha, "BF16")
        XCTAssertEqual(try source(e), .own)
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .present, chosen: false))
        XCTAssertNil(e.link.borrowingFamily)
        try await dictate(e)
        XCTAssertEqual(e.counts.own, 1)
        XCTAssertEqual(server.requests.count, 1, "no further socket request")
        // Back to Heimdall's row: one action; Vella's own model is released, nothing is asked of Heimdall.
        try await e.f.bridge.useHeimdall()
        XCTAssertEqual(try source(e), .heimdall)
        XCTAssertFalse(e.f.runtime.isLoaded("alpha"))
        XCTAssertFalse(e.f.runtime.settings.launchSet.contains { $0.id == "alpha" })
        try await dictate(e)
        XCTAssertEqual(e.model.lastText, "borrowed")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(e.counts.own, 1)
        XCTAssertTrue(e.f.runtime.status.models.isEmpty)
    }
    func testAnExplicitOwnChoiceSurvivesHeimdallComingAndGoingAndARestart() async throws {
        let e = try env(); defer { e.f.close() }
        try await e.f.load(e.f.alpha, "BF16")
        e.bus.ready("/tmp/vh-row.sock"); e.bus.gone(); e.bus.ready("/tmp/vh-row.sock")
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .present, chosen: false))
        XCTAssertNil(e.link.socket(for: try e.f.config().forRecording()))
        let restarted = HeimdallLink(bus: MemoryHeimdallBus(), announcesDictation: false)
        restarted.findInstalled = { true }
        restarted.currentConfiguration = { try? e.f.config() }
        XCTAssertFalse(restarted.heimdallChosen)
    }
    func testFailedOwnLoadOrGetKeepsHeimdall() async throws {
        let e = try env(); defer { e.f.close() }
        e.bus.ready("/tmp/vh-row.sock")
        try await e.f.bridge.useHeimdall()
        try e.f.runtime.setAvailableMB(0) // admission refuses: the load fails
        do {
            try await e.f.bridge.loadAndSelectThrowing(e.f.bridge.ref(e.f.alpha, "BF16", path: e.f.path(e.f.alpha, "BF16")))
            XCTFail("the load must be refused")
        } catch {}
        XCTAssertEqual(try source(e), .heimdall, "a failed Load changes nothing")
        XCTAssertEqual(e.f.controller.heimdall?.chosen, true)
        // Get: the first-dictation offer, whose download fails.
        try e.f.runtime.setAvailableMB(100_000)
        e.bus.gone()
        try await dictate(e) // offline, no own Ultra: the recording waits with the offer
        XCTAssertEqual(e.model.savedSession?.manifest.failureCode, "no_model")
        e.model.getRecommendedModel()
        for _ in 0..<200 where e.model.phase == .preparing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(try source(e), .heimdall, "a failed Get changes nothing")
    }
    func testOfflineWithoutVellasOwnUltraOffersInsteadOfDownloading() async throws {
        let e = try env(); defer { e.f.close() }
        e.bus.ready("/tmp/vh-row.sock")
        try await e.f.bridge.useHeimdall()
        e.bus.gone()
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .offline, chosen: true), "still the choice while offline")
        try await dictate(e)
        XCTAssertEqual(e.model.phase, .failed)
        XCTAssertEqual(e.model.savedSession?.manifest.failureCode, "no_model")
        XCTAssertEqual(e.counts.fetches, 0, "never a silent download")
        XCTAssertEqual(e.counts.own, 0, "never another model")
        XCTAssertTrue(e.f.runtime.status.models.isEmpty)
        XCTAssertEqual(try source(e), .heimdall)
    }
    func testOfflineWithVellasOwnUltraUsesIt() async throws {
        let e = try env(); defer { e.f.close() }
        let ownUltra = try e.f.path(e.f.alpha, "BF16") // stands in for Vella's downloaded Parakeet v3 Ultra
        e.link.ownSharedModelPath = { ownUltra }
        e.bus.ready("/tmp/vh-row.sock")
        try await e.f.bridge.useHeimdall()
        e.bus.gone()
        try await dictate(e)
        XCTAssertEqual(e.model.phase, .success)
        XCTAssertEqual(e.counts.own, 1)
        XCTAssertEqual(try source(e), .heimdall, "the fallback does not change the choice")
    }
    func testChoosingHeimdallClearsOwnDictationModelsFromTheLaunchSetAndStartWorkerLoadsNone() async throws {
        let e = try env(); defer { e.f.close() }
        try await e.f.load(e.f.alpha, "BF16")
        await e.f.runtime.evict("alpha", reason: "idle: test") // idle-unloaded, still in the launch set
        XCTAssertEqual(e.f.runtime.settings.launchSet.map(\.id), ["alpha"])
        e.bus.ready("/tmp/vh-row.sock")
        try await e.f.bridge.useHeimdall()
        XCTAssertTrue(e.f.runtime.settings.launchSet.isEmpty, "it would come back at the next launch")
        e.bus.gone() // offline: Start Worker must still not start an own dictation model
        e.f.bridge.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(e.f.runtime.status.models.isEmpty)
        XCTAssertNil(e.f.runtime.status.loading)
    }
    func testAFailedOrRepeatedSwitchIsReported() async throws {
        let e = try env(); defer { e.f.close() }
        e.bus.ready("/tmp/vh-row.sock")
        e.f.runtime.beginSelection() // a Load in progress
        do { try await e.f.bridge.useHeimdall(); XCTFail("refused while a Load runs") } catch {}
        e.f.runtime.endSelection()
        e.f.controller.heimdall = .init(presence: .present, chosen: false)
        e.f.runtime.beginSelection()
        e.f.controller.performHeimdall()
        for _ in 0..<100 where e.f.controller.lastError == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(e.f.controller.lastError, "a refused switch says so")
        e.f.runtime.endSelection()
    }
    // MARK: Upgrade rule: a pre-existing selection of Vella's own Ultra (Alpha stands in for it here) moves to Heimdall.

    /// Alpha loaded and selected as a build before this one left it: no explicit-choice marker.
    private func preexisting(_ e: Env, _ family: ModelFamily) async throws {
        try await e.f.load(family, "BF16")
        var config = try e.f.config(); config.dictationSource = nil
        try JSONEncoder().encode(config).write(to: e.f.runtime.configURL)
        e.link.isSharedModel = { $0.contains("alpha") }
    }
    private func settle(_ e: Env) async throws {
        for _ in 0..<100 where try e.f.config().dictationSource == nil && e.link.presence == .present {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    func testUpgradeMovesAPreexistingUltraSelectionToHeimdall() async throws {
        let e = try env(); defer { e.f.close() }
        try await preexisting(e, e.f.alpha)
        e.bus.ready("/tmp/vh-row.sock")
        try await settle(e)
        XCTAssertEqual(try source(e), .heimdall)
        XCTAssertFalse(e.f.runtime.isLoaded("alpha"), "Vella's own copy released")
        XCTAssertEqual(e.counts.fetches, 0, "no download")
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .present, chosen: true))
        XCTAssertNotNil(e.link.socket(for: try e.f.config().forRecording()))
    }
    func testUpgradeLeavesAnyOtherPreexistingSelection() async throws {
        let e = try env(); defer { e.f.close() }
        try await preexisting(e, e.f.zeta) // Qwen, Parakeet v3, Whisper… anything but Ultra
        e.bus.ready("/tmp/vh-row.sock")
        try await settle(e)
        XCTAssertNil(try source(e), "unchanged, no marker written")
        XCTAssertTrue(e.f.runtime.isLoaded("zeta"))
        XCTAssertEqual(e.f.controller.heimdall?.chosen, false)
        XCTAssertNil(e.link.socket(for: try e.f.config().forRecording()))
    }
    func testUpgradeWaitsUntilHeimdallIsPresent() async throws {
        let e = try env(installed: false); defer { e.f.close() }
        try await preexisting(e, e.f.alpha)
        e.link.reevaluate()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(try source(e), "Heimdall absent: unchanged")
        XCTAssertTrue(e.f.runtime.isLoaded("alpha"))
        e.bus.ready("/tmp/vh-row.sock")
        try await settle(e)
        XCTAssertEqual(try source(e), .heimdall, "the first time Heimdall is present")
        XCTAssertFalse(e.f.runtime.isLoaded("alpha"))
    }
    func testAnExplicitOwnUltraAfterTheUpgradeStaysOwn() async throws {
        let e = try env(); defer { e.f.close() }
        try await preexisting(e, e.f.alpha)
        e.bus.ready("/tmp/vh-row.sock")
        try await settle(e)
        XCTAssertEqual(try source(e), .heimdall)
        try await e.f.load(e.f.alpha, "BF16") // the user picks Vella's own Ultra through the new flow
        XCTAssertEqual(try source(e), .own)
        e.bus.gone(); e.bus.ready("/tmp/vh-row.sock")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try source(e), .own, "an explicit choice wins forever")
        XCTAssertTrue(e.f.runtime.isLoaded("alpha"))
    }

    func testHeimdallGoingOfflineMidSwitchLeavesAConsistentChoice() async throws {
        let e = try env(); defer { e.f.close() }
        try await e.f.load(e.f.alpha, "BF16")
        e.bus.ready("/tmp/vh-row.sock")
        let switching = Task { try await e.f.bridge.useHeimdall() }
        e.bus.gone()
        try await switching.value
        XCTAssertEqual(try source(e), .heimdall)
        XCTAssertEqual(e.f.controller.heimdall, .init(presence: .offline, chosen: true))
        XCTAssertFalse(e.f.runtime.isLoaded("alpha"))
        XCTAssertNil(e.link.borrowingFamily)
    }
    func testADictationInFlightDuringASwitchIsTranscribedOnce() async throws {
        let server = try FakeHeimdallServer(reply: .ok("borrowed")); defer { server.stop() }
        let e = try env(); defer { e.f.close() }
        try await e.f.load(e.f.alpha, "BF16")
        e.bus.ready(server.path)
        e.counts.holding = true
        let flight = Task { try await self.dictate(e) }
        for _ in 0..<400 where e.counts.hold == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(e.counts.hold, "the own model is mid-request")
        do { try await e.f.bridge.useHeimdall(); XCTFail("a switch waits for the dictation, like Load") } catch {}
        XCTAssertEqual(try source(e), .own)
        e.counts.holding = false
        e.counts.hold?.resume()
        let session = try await flight.value
        XCTAssertEqual(e.model.phase, .success)
        XCTAssertEqual(e.counts.own, 1, "one transcription")
        XCTAssertEqual(server.requests.count, 0, "not also sent to Heimdall")
        XCTAssertEqual(session.manifest.state, "transcribed")
        XCTAssertFalse(e.model.lastText.isEmpty)
        XCTAssertEqual(e.f.runtime.status.models.count, 1, "no second load")
        try await e.f.bridge.useHeimdall()
        XCTAssertEqual(try source(e), .heimdall)
    }
}
