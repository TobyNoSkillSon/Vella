import XCTest
import AppKit
import VellaCore
@testable import Vella

final class StreamingTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-stream-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func config() -> Configuration {
        Configuration(executable: "/usr/bin/python3", model: "/fixture/dictation", mode: .streaming, streamingModel: "/fixture/stream")
    }
    @MainActor private func worker(_ body: String = "", timeout: Double = 1, afterLoop: String = "") throws -> StreamingBackend {
        let script = try root().appendingPathComponent("worker.py")
        try """
        import sys,json,base64,time,signal,os
        assert os.environ.get('PYTHONDONTWRITEBYTECODE') == '1', 'Signed resources must remain immutable'
        frames=0
        for line in sys.stdin:
            q=json.loads(line)
            if q['op']=='audio': frames += len(base64.b64decode(q['pcm']))//4
            r={'id':q['id'],'frames':frames,'partial':'','committed':''}
            if q['op']=='audio': r['partial']='hello'
            if q['op']=='finish': r.update(done=True,committed='hello world')
            \(body)
            print(json.dumps(r),flush=True)
            if q['op']=='finish': break
        \(afterLoop)
        """.write(to: script, atomically: true, encoding: .utf8)
        return StreamingBackend(python: URL(fileURLWithPath: "/usr/bin/python3"), script: script, timeout: timeout)
    }
    func testCaptureQueueBoundAndFinalShortPacket() throws {
        let queue = StreamingPCMBuffer(capacity: 10_000)
        queue.append(Data(repeating: 0, count: 6000))
        XCTAssertNil(try queue.take())
        queue.append(Data(repeating: 0, count: 800))
        XCTAssertEqual(try queue.take()?.count, 6400)
        queue.close()
        XCTAssertEqual(try queue.take()?.count, 400)
        XCTAssertTrue(queue.isDrained)
        XCTAssertEqual(queue.totalFrames, 1700)
        let overflow = StreamingPCMBuffer(capacity: 64)
        overflow.append(Data(repeating: 0, count: 68))
        XCTAssertThrowsError(try overflow.take())
        XCTAssertFalse(overflow.isDrained)
    }
    @MainActor func testPartialBeforeFinishAndExactFinalAcknowledgement() async throws {
        let backend = try worker(); defer { backend.shutdown() }
        try await backend.start(config: config().forRecording())
        try await backend.feed(Data(repeating: 0, count: 6400))
        XCTAssertEqual(backend.partial, "hello")
        XCTAssertTrue(backend.committed.isEmpty)
        let final = try await backend.finish(expectedFrames: 1600)
        XCTAssertEqual(final, "hello world")
        try await backend.releaseAndWait()
        XCTAssertNil(backend.processID)
    }
    @MainActor func testWrongFrameAcknowledgementFailsClosed() async throws {
        let backend = try worker("if q['op']=='audio': r['frames']+=1")
        defer { backend.shutdown() }
        try await backend.start(config: config().forRecording())
        do { try await backend.feed(Data(repeating: 0, count: 4)); XCTFail("Accepted wrong acknowledgement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("acknowledgement")) }
        XCTAssertNil(backend.processID)
    }
    @MainActor func testRoamingSendsPendingWordsToNewFocusWithoutReplayingEarlierText() async throws {
        var current = "first", fields = ["first": "", "second": ""]
        let insertion = LiveInsertion(targetIsCurrent: { true }, send: { fields[current, default: ""] += $0 }, monitorUserInput: false)
        defer { insertion.cancel() }
        insertion.offer(committed: "", partial: "hello")
        current = "second" // Even already queued words deliberately follow focus.
        // Drain completion, not a scheduler-speed assumption, separates the two
        // focus changes. A loaded CI runner can legitimately exceed 180 ms.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fields["second"] != "hello", ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fields["first"], ""); XCTAssertEqual(fields["second"], "hello")
        current = "first"; fields["first"] = "manual edit: "
        insertion.offer(committed: "hello world", partial: "")
        await insertion.finishStream()
        XCTAssertEqual(fields["first"], "manual edit:  world")
        XCTAssertEqual(fields["second"], "hello")
        XCTAssertNil(insertion.blockedReason)
    }
    @MainActor func testWorkerPartialTypesBeforeFinishAndFinalSuffixIsNotDuplicated() async throws {
        let backend = try worker(); defer { backend.shutdown() }
        var writes: [String] = []
        let insertion = LiveInsertion(targetIsCurrent: { true }, send: { writes.append($0) })
        defer { insertion.cancel(); backend.onUpdate = nil }
        backend.onUpdate = { insertion.offer(backend.text) }
        try await backend.start(config: config().forRecording())
        try await backend.feed(Data(repeating: 0, count: 4))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while writes.joined() != "hello", ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(writes.joined(), "hello", "Partial must be delivered while the microphone would still be open")
        let final = try await backend.finish(expectedFrames: 1)
        await insertion.finish(final)
        XCTAssertEqual(writes.joined(), "hello world", "Finish sends only the suffix, not another full transcript")
    }
    @MainActor func testIncompleteFlagIsStickyAndNeverReturnsCompleteText() async throws {
        let backend = try worker("if q['op']=='audio': r['incomplete']=True")
        defer { backend.shutdown() }
        try await backend.start(config: config().forRecording())
        try await backend.feed(Data(repeating: 0, count: 4))
        do { _ = try await backend.finish(expectedFrames: 1); XCTFail("Incomplete text was accepted") }
        catch { guard case VellaError.unrecognizedAudio = error else { return XCTFail("Wrong error: \(error)") } }
        XCTAssertEqual(backend.committed, "hello world", "Recognized words remain recoverable")
    }
    @MainActor func testTimeoutAndCancellationRetireChild() async throws {
        let backend = try worker("if q['op']=='audio': time.sleep(3)", timeout: 0.3)
        defer { backend.shutdown() }
        try await backend.start(config: config().forRecording())
        let pid = try XCTUnwrap(backend.processID)
        do { try await backend.feed(Data(repeating: 0, count: 4)); XCTFail("Missing deadline") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        try await backend.releaseAndWait()
        XCTAssertNotEqual(kill(pid, 0), 0)
        try await backend.start(config: config().forRecording())
        let pending = Task { try await backend.feed(Data(repeating: 0, count: 4)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        pending.cancel()
        do { try await pending.value; XCTFail("Cancellation was ignored") } catch { }
        try await backend.releaseAndWait(); XCTAssertNil(backend.processID)
    }
    @MainActor func testStoppedSuspendedStartupCannotResurrectWorker() async throws {
        let backend = try worker("signal.signal(signal.SIGTERM, signal.SIG_IGN)", afterLoop: "time.sleep(1)")
        defer { backend.shutdown() }
        try await backend.start(config: config().forRecording())
        let starting = Task { try await backend.start(config: config().forRecording()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        backend.stop()
        do { try await starting.value; XCTFail("Stopped startup resurrected") } catch { }
        XCTAssertNil(backend.processID)
    }
    @MainActor func testModeSwitchPreservesBothSelectionsAndBlocksDuringCapture() throws {
        let path = try root().appendingPathComponent("config.json")
        var config = config(); config.mode = .dictation
        try JSONEncoder().encode(config).write(to: path)
        let model = Model(configurationURL: path)
        defer { model.shutdown() }
        try model.selectMode(.streaming)
        XCTAssertEqual(model.mode, .streaming)
        _ = NSApplication.shared
        let delegate = AppDelegate(model: model)
        delegate.rebuildMenu()
        let modes = try XCTUnwrap(delegate.menu.item(withTitle: "Mode")?.submenu)
        XCTAssertEqual(modes.item(withTitle: "Streaming")?.state, .on)
        let start = try XCTUnwrap(delegate.menu.item(withTitle: "Start Streaming"))
        XCTAssertEqual(start.keyEquivalent, "n")
        XCTAssertEqual(start.keyEquivalentModifierMask, [.control, .command])
        let table = try XCTUnwrap(delegate.menu.item(withTitle: "Models…")?.submenu?.items.first?.view as? MenuTableHostingView)
        XCTAssertEqual(table.rootView.library.mode, .streaming)
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: path))
        XCTAssertEqual(saved.model, config.model); XCTAssertEqual(saved.streamingModel, config.streamingModel)
        model.phase = .recording
        delegate.rebuildMenu()
        XCTAssertTrue(delegate.menu.item(withTitle: "Finish Streaming")?.isEnabled == true)
        XCTAssertTrue(delegate.menu.item(withTitle: "Mode")?.submenu?.items.allSatisfy { !$0.isEnabled } == true)
        XCTAssertThrowsError(try model.selectMode(.dictation))
        model.phase = .transcribing
        XCTAssertThrowsError(try model.selectMode(.dictation))
        model.phase = .idle
        try model.selectMode(.dictation)
    }
    @MainActor func testCancelledFinishCannotStopReplacementStartup() async throws {
        let backend = try worker("if q['op']=='finish': time.sleep(0.3)")
        defer { backend.shutdown() }
        try await backend.start(config: config().forRecording())
        let finishing = Task { try await backend.finish(expectedFrames: 0) }
        try await Task.sleep(nanoseconds: 20_000_000)
        backend.stop()
        try await backend.start(config: config().forRecording())
        do { _ = try await finishing.value; XCTFail("Stopped Finish succeeded") } catch { }
        XCTAssertNotNil(backend.processID, "An old Finish must not retire the replacement")
        try await backend.feed(Data(repeating: 0, count: 4))
        XCTAssertEqual(backend.partial, "hello")
    }
    @MainActor func testStreamingRecoveryIsDurableClipboardOnlyAndPreservesEarlierCheckpoint() async throws {
        let session = try RecordingSession(root: root(), config: config().forRecording())
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 2000).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: false)
        try session.saveStreamingPartial("earlier words")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = Model(pasteboard: pasteboard, streamingBackend: try worker())
        defer { model.shutdown() }
        model.recover(session.directory)
        let until = Date().addingTimeInterval(5)
        while model.busy && Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.phase, .success, model.message)
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello world")
        XCTAssertEqual(try String(contentsOf: session.transcriptURL), "hello world")
        let recovered = try RecordingSession(directory: session.directory)
        XCTAssertEqual(recovered.manifest.config.mode, .streaming)
        XCTAssertEqual(recovered.manifest.state, "transcribed")
        let files = try FileManager.default.contentsOfDirectory(atPath: session.directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("streaming-retry-") })
        XCTAssertEqual(recovered.manifest.segments.reduce(0) { $0 + $1.frames - $1.overlapFrames }, 2000)
    }
}
