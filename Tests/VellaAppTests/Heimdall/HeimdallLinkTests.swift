import XCTest
import AppKit
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// An in-memory notification bus: records posts, delivers to observers on demand.
@MainActor final class MemoryHeimdallBus: HeimdallBus {
    var posts: [(name: String, object: String, info: [String: Any]?)] = []
    var handlers: [String: @MainActor ([AnyHashable: Any]?) -> Void] = [:]
    func post(_ name: String, object: String, userInfo: [String: Any]?) { posts.append((name, object, userInfo)) }
    func observe(_ name: String, object: String?, _ handler: @escaping @MainActor ([AnyHashable: Any]?) -> Void) { handlers[name] = handler }
    func deliver(_ name: String, _ info: [AnyHashable: Any]? = nil) { handlers[name]?(info) }
    func states() -> [[String: Any]] { posts.filter { $0.name == HeimdallNames.dictationState }.compactMap(\.info) }
    /// The fake server runs in this process, so the default pid passes the peer check.
    func ready(_ socket: String, pid: Int = Int(getpid())) {
        deliver(HeimdallNames.asr, ["v": 1, "state": "ready", "socket": socket, "model": "parakeet-v3-ultra", "pid": pid, "sent": 1.0])
    }
    func gone(pid: Int = Int(getpid())) { deliver(HeimdallNames.asr, ["v": 1, "state": "gone", "socket": "", "model": "parakeet-v3-ultra", "pid": pid]) }
}

private final class TestRegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws { registered = config }
    func unregister() { registered = nil }
}

@MainActor final class HeimdallLinkTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-heimdall-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Channel 1

    func testLaunchAsksForHeimdallsModelAndSaysHelloAndAnswersItsQuery() {
        let bus = MemoryHeimdallBus()
        let link = HeimdallLink(bus: bus, announcesDictation: true)
        link.start()
        XCTAssertTrue(bus.posts.contains { $0.name == HeimdallNames.asrQuery && $0.object == "dev.vella.dictation" })
        XCTAssertEqual(bus.states().map { $0["reason"] as? String }, ["hello"])
        XCTAssertEqual(bus.posts.first { $0.name == HeimdallNames.dictationState }?.object, "dev.vella.dictation")
        bus.deliver(HeimdallNames.vellaQuery)
        XCTAssertEqual(bus.states().map { $0["reason"] as? String }, ["hello", "hello"])
        XCTAssertEqual(bus.states().last?["state"] as? String, "off")
    }
    func testAQAOrLabInstanceNeverSpeaksForTheUsersVella() {
        let bus = MemoryHeimdallBus()
        let link = HeimdallLink(bus: bus, announcesDictation: false)
        link.start()
        bus.deliver(HeimdallNames.vellaQuery)
        XCTAssertTrue(bus.states().isEmpty)
        XCTAssertNil(bus.handlers[HeimdallNames.vellaQuery])
        XCTAssertTrue(bus.posts.contains { $0.name == HeimdallNames.asrQuery }, "it still borrows Heimdall's model")
    }
    func testHelloOnShortcutChange() {
        let bus = MemoryHeimdallBus()
        let link = HeimdallLink(bus: bus, announcesDictation: true)
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: TestRegistrar())
        link.announcer?.shortcut = { shortcutSignalFields(manager.workingConfiguration) }
        manager.onBindingChange = { link.announcer?.shortcutMayHaveChanged() }
        link.start()
        let hold = ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .right), behavior: .holdToTalk)
        XCTAssertTrue(manager.apply(hold))
        let states = bus.states()
        XCTAssertEqual(states.map { $0["reason"] as? String }, ["hello", "hello"])
        XCTAssertEqual(try JSONDecoder().decode(ShortcutConfiguration.self, from: Data((states.last?["shortcut"] as? String ?? "").utf8)), hold)
        XCTAssertEqual(states.last?["shortcutLabel"] as? String, ShortcutLabels.display(hold))
        XCTAssertTrue(manager.apply(hold))
        XCTAssertEqual(bus.states().count, 2, "re-applying the same binding sends no hello")
    }

    private func controller(request: SessionTranscriber.Request? = nil) throws -> DictationController {
        let permission = InsertionPermission(isTrusted: { true }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        return DictationController(
            insertionPermission: permission, pasteboard: NSPasteboard.withUniqueName(), stopCapture: { _ in }, transcriptionRequest: request,
            configurationURL: root.appendingPathComponent("config.json"), captureDestination: { { "test: no destination" } },
            backend: Backend(runtime: try Runtime.isolated(root)), monitorDefaultInput: false)
    }

    func testControllerPhasesDriveTheSignal() throws {
        let bus = MemoryHeimdallBus()
        let link = HeimdallLink(bus: bus, announcesDictation: true)
        let model = try controller(); defer { model.shutdown() }
        model.heimdall = link
        link.start()
        // A Get or a recovery prepares too: not a dictation.
        model.update(.preparing, "Getting a model")
        model.update(.idle, "")
        // A press: preparing (on at once), recording, then Finish (off before transcription).
        model.beginCaptureSignal()
        model.update(.preparing, "Checking microphone permission…")
        model.update(.recording, "")
        model.update(.transcribing, "")
        model.update(.success, "")
        let reasons = bus.states().map { $0["reason"] as? String }
        XCTAssertEqual(reasons, ["hello", "start", "stop"])
        let start = bus.states()[1], stop = bus.states()[2]
        XCTAssertEqual(start["state"] as? String, "on"); XCTAssertEqual(stop["state"] as? String, "off")
        XCTAssertEqual(start["session"] as? String, stop["session"] as? String)
        XCTAssertEqual(start["mode"] as? String, "dictation")
        // A press that cannot record (no microphone permission): on, then off.
        model.beginCaptureSignal()
        model.update(.preparing, "")
        model.update(.failed, "Allow Vella under System Settings → Privacy & Security → Microphone.")
        XCTAssertEqual(bus.states().suffix(2).map { $0["reason"] as? String }, ["start", "stop"])
        // Quit while recording: stop, then quit.
        model.beginCaptureSignal(); model.update(.preparing, ""); model.update(.recording, "")
        model.cancel()
        link.announcer?.quit()
        XCTAssertEqual(bus.states().suffix(3).map { $0["reason"] as? String }, ["start", "stop", "quit"])
    }

    // MARK: Channel 2

    /// A finished one-segment dictation recorded with `model` (a path; empty: none selected).
    private func session(model: String = "/models/parakeet-ultra", seconds: Double = 1) throws -> RecordingSession {
        let session = try RecordingSession(root: root.appendingPathComponent("Recordings"), config: Configuration(model: model))
        let writer = try SegmentedPCMWriter(session: session)
        let samples = (0..<Int(seconds * 16_000)).map { Float(0.1 * sin(Double($0) * 0.17)) }
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        return session
    }
    /// Counts the requests Vella's own model served.
    final class OwnModel {
        var calls = 0
        var request: SessionTranscriber.Request { { _, _ in self.calls += 1; return "own model text" } }
    }
    struct Rig {
        let bus: MemoryHeimdallBus
        let link: HeimdallLink
        let model: DictationController
        let own: OwnModel
        let lastDictation: () -> LastDictationStatus?
        let borrowChanges: () -> [String?]
    }
    private func rig(family: String = "parakeet-v3-ultra", timeout: Double? = nil) throws -> Rig {
        let bus = MemoryHeimdallBus()
        let link = HeimdallLink(bus: bus, announcesDictation: false)
        link.familyOf = { _ in family }
        link.currentConfiguration = { Configuration(model: "/models/parakeet-ultra") }
        link.acceptSocket = { _ in true } // the fake server lives in /tmp, not Heimdall's support folder
        if let timeout { link.exchange = { try await HeimdallASRClient.transcribe(socket: $0, samples: $1, timeout: timeout, peer: $2) } }
        var last: LastDictationStatus?
        var changes: [String?] = []
        link.onLastDictation = { last = $0 }
        link.onBorrowChange = { now, _ in changes.append(now) }
        let own = OwnModel()
        let model = try controller(request: own.request)
        model.heimdall = link
        link.start()
        return Rig(bus: bus, link: link, model: model, own: own, lastDictation: { last }, borrowChanges: { changes })
    }
    private func dictate(_ rig: Rig, model path: String = "/models/parakeet-ultra") async throws {
        let s = try session(model: path)
        rig.model.labTranscribe(s)
        for _ in 0..<1000 where rig.model.phase == .transcribing || rig.model.phase == .preparing { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testWithoutHeimdallVellasOwnModelServesAndNothingElseChanges() async throws {
        let r = try rig(); defer { r.model.shutdown() }
        try await dictate(r)
        XCTAssertEqual(r.model.phase, .success)
        XCTAssertEqual(r.model.lastText, "own model text")
        XCTAssertEqual(r.own.calls, 1)
        XCTAssertEqual(r.lastDictation()?.path, "vella")
        XCTAssertNil(r.lastDictation()?.fallback)
        XCTAssertEqual(r.link.borrow.label, "absent")
        XCTAssertEqual(r.borrowChanges(), [], "no residency change")
    }
    func testReadyHeimdallServesUltraDictations() async throws {
        let server = try FakeHeimdallServer(reply: .ok("  borrowed   text ")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.bus.ready(server.path)
        XCTAssertEqual(r.borrowChanges(), ["parakeet-v3-ultra"], "Vella's own copy is released")
        try await dictate(r)
        XCTAssertEqual(r.model.phase, .success)
        XCTAssertEqual(r.model.lastText, "borrowed text")
        XCTAssertEqual(r.own.calls, 0, "Vella's own model is never asked")
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.samples, 16_000, "the segment's 16 kHz mono audio")
        XCTAssertEqual(r.lastDictation()?.path, "heimdall")
        XCTAssertEqual(r.lastDictation()?.model, "parakeet-v3-ultra")
    }
    /// Speech with pauses, cut by the recorder at the first pause after 5 s: several segments.
    private func segmentedSession() throws -> RecordingSession {
        let session = try RecordingSession(root: root.appendingPathComponent("Recordings"), config: Configuration(model: "/models/parakeet-ultra"))
        let writer = try SegmentedPCMWriter(session: session)
        var samples: [Float] = []
        for _ in 0..<3 {
            samples += (0..<(6 * 16_000)).map { Float(0.1 * sin(Double($0) * 0.17)) }
            samples += [Float](repeating: 0, count: 16_000)
        }
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        return session
    }
    /// The whole dictation is one round trip: no request per segment, no overlap sent twice, nothing before it.
    func testOneRequestPerDictation() async throws {
        let server = try FakeHeimdallServer(reply: .ok("whole dictation")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.bus.ready(server.path)
        let s = try segmentedSession()
        XCTAssertGreaterThan(s.manifest.segments.count, 2, "the fixture must cut into several segments")
        let newFrames = s.manifest.segments.enumerated().reduce(0) { $0 + ($1.offset == 0 ? $1.element.frames : $1.element.frames - $1.element.overlapFrames) }
        XCTAssertTrue(r.model.labTranscribe(s))
        for _ in 0..<1000 where r.model.phase == .transcribing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(r.model.phase, .success)
        XCTAssertEqual(r.model.lastText, "whole dictation")
        XCTAssertEqual(server.requests.count, 1, "one connection, one request")
        XCTAssertEqual(server.requests.first?.samples, newFrames, "every sample once")
        XCTAssertEqual(r.model.lastRoute?.requests, 1)
        XCTAssertEqual(r.own.calls, 0)
        XCTAssertEqual(s.manifest.state, "transcribed")
    }
    func testOtherModelsAndStreamingAreUnaffected() async throws {
        let server = try FakeHeimdallServer(reply: .ok("borrowed")); defer { server.stop() }
        let r = try rig(family: "parakeet-v3"); defer { r.model.shutdown() }
        r.bus.ready(server.path)
        try await dictate(r)
        XCTAssertEqual(r.own.calls, 1)
        XCTAssertTrue(server.requests.isEmpty)
        var streaming = Configuration(model: "/models/nemotron"); streaming.mode = .streaming
        r.link.familyOf = { _ in "parakeet-v3-ultra" }
        XCTAssertNil(r.link.socket(for: streaming), "streaming never borrows")
    }
    private func assertFallsBack(_ reply: FakeHeimdallServer.Reply, code: String, timeout: Double? = nil) async throws {
        let server = try FakeHeimdallServer(reply: reply); defer { server.stop() }
        let r = try rig(timeout: timeout); defer { r.model.shutdown() }
        r.bus.ready(server.path)
        try await dictate(r)
        XCTAssertEqual(r.model.phase, .success, "\(code): the dictation still completes")
        XCTAssertEqual(r.model.lastText, "own model text")
        XCTAssertEqual(r.own.calls, 1)
        XCTAssertEqual(r.lastDictation()?.path, "vella")
        XCTAssertEqual(r.lastDictation()?.fallback, code)
        XCTAssertEqual(r.link.borrow.label, "unavailable")
        XCTAssertEqual(r.borrowChanges(), ["parakeet-v3-ultra", nil], "normal residency returns")
        // Unavailable until the next ready: the next dictation does not try Heimdall.
        server.setReply(.ok("borrowed again"))
        try await dictate(r)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(r.own.calls, 2)
        r.bus.ready(server.path)
        try await dictate(r)
        XCTAssertEqual(r.model.lastText, "borrowed again")
        XCTAssertEqual(server.requests.count, 2)
    }
    func testBusyFallsBack() async throws { try await assertFallsBack(.error("busy"), code: "busy") }
    func testGarbageFallsBack() async throws { try await assertFallsBack(.garbage, code: "invalid_reply") }
    func testSilenceFallsBackAfterTheDeadline() async throws { try await assertFallsBack(.silence, code: "timeout", timeout: 0.3) }
    func testHeimdallQuittingMidRequestFallsBack() async throws { try await assertFallsBack(.close, code: "invalid_reply") }
    func testAStaleSocketFallsBack() async throws {
        let r = try rig(); defer { r.model.shutdown() }
        r.bus.ready("/tmp/vh-stale-\(UUID().uuidString.prefix(6)).sock")
        try await dictate(r)
        XCTAssertEqual(r.model.phase, .success)
        XCTAssertEqual(r.lastDictation()?.fallback, "connect")
        XCTAssertEqual(r.own.calls, 1)
    }
    func testHeimdallGoneMidSession() async throws {
        let server = try FakeHeimdallServer(reply: .ok("borrowed")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.bus.ready(server.path)
        try await dictate(r)
        XCTAssertEqual(r.lastDictation()?.path, "heimdall")
        r.bus.gone()
        XCTAssertEqual(r.borrowChanges(), ["parakeet-v3-ultra", nil])
        XCTAssertEqual(r.link.borrow.label, "absent")
        try await dictate(r)
        XCTAssertEqual(r.lastDictation()?.path, "vella")
        XCTAssertNil(r.lastDictation()?.fallback, "gone is not a failure")
        XCTAssertEqual(server.requests.count, 1)
    }
    func testWithoutAModelOfItsOwnVellaBorrowsInsteadOfOfferingADownload() async throws {
        let server = try FakeHeimdallServer(reply: .ok("first words")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.bus.ready(server.path)
        try await dictate(r, model: "")
        XCTAssertEqual(r.model.phase, .success)
        XCTAssertEqual(r.model.lastText, "first words")
        XCTAssertNil(r.model.pendingModelRequest)
        // When Heimdall then fails, the recording waits for a model as it did before.
        server.setReply(.error("unavailable"))
        r.bus.ready(server.path)
        try await dictate(r, model: "")
        XCTAssertEqual(r.model.phase, .failed)
        XCTAssertEqual(r.model.savedSession?.manifest.failureCode, "no_model")
        XCTAssertEqual(r.own.calls, 0)
    }

    func testAnotherProcessCannotPoseAsHeimdall() async throws {
        let server = try FakeHeimdallServer(reply: .ok("forged")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.link.acceptSocket = { heimdallSocketAcceptable($0, expected: HeimdallLink.defaultSocket) }
        r.bus.ready(server.path)
        XCTAssertEqual(r.link.borrow.label, "absent", "a socket outside Heimdall's folder is ignored")
        XCTAssertFalse(heimdallSocketAcceptable(server.path, expected: server.path + ".other"))
        XCTAssertTrue(heimdallSocketAcceptable(server.path, expected: server.path), "the real socket: user-owned, 0600")
        // A socket whose peer is not the announcing process.
        r.link.acceptSocket = { _ in true }
        r.bus.ready(server.path, pid: 1)
        try await dictate(r)
        XCTAssertEqual(r.lastDictation()?.fallback, "connect")
        XCTAssertEqual(r.model.lastText, "own model text")
    }
    func testAFailureFromAnEarlierHeimdallLeavesTheNewOneAvailable() async throws {
        let server = try FakeHeimdallServer(reply: .ok("new")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.bus.ready("/tmp/vh-old.sock", pid: Int(getpid()))
        // The request to the old socket fails while the new Heimdall announces.
        var calls = 0
        r.link.exchange = { [bus = r.bus, path = server.path] socket, samples, peer in
            calls += 1
            guard calls > 1 else { bus.ready(path); throw HeimdallASRError.connect("closed") }
            return try await HeimdallASRClient.transcribe(socket: socket, samples: samples, peer: peer)
        }
        try await dictate(r)
        XCTAssertEqual(r.link.borrow.label, "ready", "the newer Heimdall is not marked unavailable")
        XCTAssertEqual(r.lastDictation()?.path, "heimdall", "and it serves the rest of the dictation")
        XCTAssertEqual(r.model.lastText, "new")
    }
    func testAfterAFailureVellaAsksHeimdallAgainLater() async throws {
        let server = try FakeHeimdallServer(reply: .error("busy")); defer { server.stop() }
        let r = try rig(); defer { r.model.shutdown() }
        r.link.requeryDelay = { _ in 0.1 }
        r.bus.ready(server.path)
        let before = r.bus.posts.filter { $0.name == HeimdallNames.asrQuery }.count
        try await dictate(r)
        XCTAssertEqual(r.link.borrow.label, "unavailable")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(r.bus.posts.filter { $0.name == HeimdallNames.asrQuery }.count, before + 1)
    }

    // MARK: Residency

    func testBorrowedFamilyStaysUnloadedButKeepsItsLaunchSetEntry() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "BF16")
        XCTAssertEqual(f.runtime.settings.launchSet.map(\.id), ["alpha"])
        var borrowed: String? = "alpha"
        f.runtime.borrowedFamily = { borrowed }
        await f.runtime.releaseBorrowed("alpha")
        XCTAssertFalse(f.runtime.isLoaded("alpha"))
        XCTAssertEqual(f.runtime.settings.launchSet.map(\.id), ["alpha"], "the entry stays for when Heimdall is gone")
        XCTAssertTrue(f.runtime.status.evictions?.last?.reason.hasPrefix("heimdall:") == true)
        await f.runtime.loadLaunchSet()
        XCTAssertFalse(f.runtime.isLoaded("alpha"), "the launch set skips the borrowed family")
        borrowed = nil
        await f.runtime.loadLaunchSet()
        XCTAssertTrue(f.runtime.isLoaded("alpha"), "normal residency returns")
    }
    func testABusyModelIsReleasedOnlyOnceIdle() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "BF16")
        f.runtime.borrowReleaseDelay = 0.2
        f.runtime.borrowedFamily = { "alpha" }
        f.runtime.pin("alpha")
        await f.runtime.releaseBorrowed("alpha")
        XCTAssertTrue(f.runtime.isLoaded("alpha"), "never unloaded while it serves")
        f.runtime.unpin("alpha")
        XCTAssertTrue(f.runtime.isLoaded("alpha"), "not at once: an API job's next segment would reload it")
        for _ in 0..<100 where f.runtime.isLoaded("alpha") { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(f.runtime.isLoaded("alpha"))
        XCTAssertEqual(f.runtime.settings.launchSet.map(\.id), ["alpha"])
    }
    func testStatusCarriesHeimdallAndTheLastPath() throws {
        let runtime = try Runtime.isolated(root)
        runtime.heimdall = HeimdallStatus(state: "ready", socket: "/s", model: "parakeet-v3-ultra", borrowing: true)
        runtime.lastDictation = LastDictationStatus(path: "heimdall", at: 1)
        let file = try XCTUnwrap(WorkerStatus.read(runtime.statusURL))
        XCTAssertEqual(file.heimdall?.borrowing, true)
        XCTAssertEqual(file.last_dictation?.path, "heimdall")
    }
    func testSettleWaitsOnlyWhenHeimdallsSocketExists() async throws {
        let link = HeimdallLink(bus: MemoryHeimdallBus(), announcesDictation: false)
        var start = Date()
        await link.settle(socketPath: "/tmp/vh-none-\(UUID().uuidString.prefix(6))", wait: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        let server = try FakeHeimdallServer(reply: .ok("")); defer { server.stop() }
        let other = HeimdallLink(bus: MemoryHeimdallBus(), announcesDictation: false)
        start = Date()
        await other.settle(socketPath: server.path, wait: 0.3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "waits for the answer to its query")
    }

    // MARK: Menu

    func testMenuHeaderNamesHeimdallWhileBorrowing() throws {
        let model = try controller(); defer { model.shutdown() }
        let delegate = AppDelegate(
            model: model,
            shortcutManager: ShortcutManager(
                engine: ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false })),
                store: ShortcutStore(), registrar: TestRegistrar()))
        // An isolated Models catalog, so the header never reads this Mac's settings.
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("Support/models-installed.json")
        delegate.modelsMenu = delegate.makeModelsMenu(
            controller: ModelsController(
                dictation: ModelLibrary(
                    mode: .dictation, resources: resources, registryURL: registry,
                    calibration: CalibrationStore(directory: root.appendingPathComponent("Cal"), resources: resources)),
                streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                configURL: root.appendingPathComponent("config.json")))
        let bus = MemoryHeimdallBus()
        delegate.startHeimdall(bus: bus, announcesDictation: false)
        let link = try XCTUnwrap(delegate.heimdall)
        link.familyOf = { _ in "parakeet-v3-ultra" }
        link.familyName = { _ in "Parakeet v3 Ultra" }
        link.currentConfiguration = { Configuration(model: "") }
        link.acceptSocket = { _ in true }
        bus.ready("/tmp/vh-menu.sock")
        delegate.rebuildMenu()
        XCTAssertTrue(delegate.menu.items.first?.title.hasSuffix(" · Parakeet v3 Ultra via Heimdall") == true, delegate.menu.items.first?.title ?? "")
        bus.gone()
        delegate.rebuildMenu()
        XCTAssertFalse(delegate.menu.items.first?.title.contains("Heimdall") == true)
    }
}
