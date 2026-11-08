import XCTest
import Foundation
@testable import VellaCore
import VellaTestSupport

/// docs/HEIMDALL.md, without a model: Channel 1's state derivation, payload and heartbeat; Channel 2's announcements,
/// borrow policy, wire format and socket client (against a fake Heimdall server).
@MainActor final class HeimdallSignalTests: XCTestCase {
    /// A dictation controller reduced to its phases: start prepares then records (or fails), finish transcribes then
    /// succeeds, cancel goes idle. The tracker sees every phase, as DictationController.update reports it.
    final class Phases {
        var tracker = DictationSignalTracker()
        var reasons: [DictationSignalReason] = []
        var phase = DictationSignalPhase.idle
        var startFails = false
        var operation: UInt64 = 0
        func set(_ next: DictationSignalPhase) {
            phase = next
            var sessions = 0
            if let reason = tracker.observe(next, newSession: { sessions += 1; return "s\(self.reasons.count)" }) { reasons.append(reason) }
        }
        func start() { operation += 1; set(.preparingCapture); set(startFails ? .failed : .recording) }
        func finish() { set(.transcribing); set(.success); set(.idle) }
        func cancel() { set(.idle) }
        var sinks: ShortcutEngine.Sinks {
            .init(
                start: { self.start() }, finish: { self.finish() }, cancel: { self.cancel() },
                isRecording: { self.phase == .recording }, isBusy: { self.phase == .preparingCapture || self.phase == .transcribing },
                currentOperation: { self.operation })
        }
    }
    private func engine(_ behavior: ShortcutBehavior, _ phases: Phases, clock: @escaping () -> TimeInterval) -> ShortcutEngine {
        ShortcutEngine(configuration: ShortcutConfiguration(trigger: ShortcutConfiguration.default.trigger, behavior: behavior), sinks: phases.sinks, now: clock)
    }

    func testToggleIsOnFromThePressThatStartsUntilThePressThatFinishes() {
        let phases = Phases()
        var now = 0.0
        let e = engine(.toggle, phases, clock: { now })
        e.press(); now += 0.05; e.release()
        XCTAssertEqual(phases.reasons, [.start])
        XCTAssertTrue(phases.tracker.on)
        now += 5; e.press(); e.release()
        XCTAssertEqual(phases.reasons, [.start, .stop], "stop when recording ends, before transcription")
        XCTAssertFalse(phases.tracker.on)
    }
    func testHoldToTalkIsOnWhileHeld() {
        let phases = Phases()
        var now = 0.0
        let e = engine(.holdToTalk, phases, clock: { now })
        e.press()
        XCTAssertEqual(phases.reasons, [.start])
        now += 3; e.release()
        XCTAssertEqual(phases.reasons, [.start, .stop])
    }
    func testTapOrHoldTapKeepsRecordingUntilTheSecondTap() {
        let phases = Phases()
        var now = 0.0
        let e = engine(.tapOrHold, phases, clock: { now })
        e.press(); now += 0.1; e.release()
        XCTAssertEqual(phases.reasons, [.start], "a short tap keeps recording: still on")
        XCTAssertTrue(phases.tracker.on)
        now += 4; e.press(); now += 0.1; e.release()
        XCTAssertEqual(phases.reasons, [.start, .stop])
    }
    func testTapOrHoldHeldFinishesOnRelease() {
        let phases = Phases()
        var now = 0.0
        let e = engine(.tapOrHold, phases, clock: { now })
        e.press(); now += 2; e.release()
        XCTAssertEqual(phases.reasons, [.start, .stop])
    }
    func testAPressThatCannotRecordStartsAndStopsAtOnce() {
        // No microphone permission or model check failure: preparing then failed.
        let phases = Phases(); phases.startFails = true
        var now = 0.0
        let e = engine(.toggle, phases, clock: { now })
        e.press(); now += 0.05; e.release()
        XCTAssertEqual(phases.reasons, [.start, .stop])
    }
    func testMenuCLIAndAPIStartsAreTheSamePhases() {
        // The menu's Start, `vella` and the API call the controller's toggle(): the same phases as a press.
        let phases = Phases()
        phases.start(); phases.finish()
        XCTAssertEqual(phases.reasons, [.start, .stop])
        XCTAssertEqual(phases.tracker.session, "s0")
    }
    func testPreparingForAGetOrARecoveryIsNotDictation() {
        let phases = Phases()
        for phase: DictationSignalPhase in [.preparingOther, .transcribing, .success, .failed, .idle] { phases.set(phase) }
        XCTAssertEqual(phases.reasons, [])
        XCTAssertEqual(phases.tracker.session, "", "no session before the first recording")
    }
    func testEachRecordingGetsANewSession() {
        var tracker = DictationSignalTracker()
        var n = 0
        let next = { () -> String in n += 1; return "id\(n)" }
        _ = tracker.observe(.preparingCapture, newSession: next)
        _ = tracker.observe(.recording, newSession: next)
        XCTAssertEqual(tracker.session, "id1", "recording continues the session that preparing started")
        _ = tracker.observe(.transcribing, newSession: next)
        XCTAssertEqual(tracker.session, "id1", "off keeps the last session")
        _ = tracker.observe(.preparingCapture, newSession: next)
        XCTAssertEqual(tracker.session, "id2")
    }

    // MARK: Payload and announcer

    func testPayloadHasTheSpecKeysAsPropertyListTypes() throws {
        let fields = shortcutSignalFields(.default)
        let payload = DictationSignalPayload(
            on: true, reason: .start, session: "abc", pid: 42, sent: 1_700_000_000.5, mode: "streaming", shortcut: fields.json, shortcutLabel: fields.label)
        let info = payload.userInfo
        XCTAssertEqual(Set(info.keys), ["v", "state", "reason", "session", "pid", "sent", "mode", "shortcut", "shortcutLabel"])
        XCTAssertEqual(info["v"] as? Int, 1)
        XCTAssertEqual(info["state"] as? String, "on")
        XCTAssertEqual(info["reason"] as? String, "start")
        XCTAssertEqual(info["mode"] as? String, "streaming")
        XCTAssertEqual(info["shortcutLabel"] as? String, "⌃⌘N · Toggle")
        XCTAssertTrue(PropertyListSerialization.propertyList(info, isValidFor: .binary))
        // Exactly shortcuts.json's form: it decodes back to the binding.
        let decoded = try JSONDecoder().decode(ShortcutConfiguration.self, from: Data((info["shortcut"] as? String ?? "").utf8))
        XCTAssertEqual(decoded, .default)
        XCTAssertEqual(shortcutSignalFields(.default).json, shortcutSignalFields(.default).json, "stable text for an equal binding")
    }

    final class FakeTimer {
        var interval: TimeInterval?
        var fire: (@MainActor () -> Void)?
        var cancels = 0
        var start: DictationAnnouncer.StartTimer {
            { interval, fire in self.interval = interval; self.fire = fire; return { self.cancels += 1; self.fire = nil } }
        }
    }
    var activity: [Bool] = []
    private func announcer(_ posts: @escaping ([String: Any]) -> Void, clock: @escaping () -> Double, timer: FakeTimer) -> DictationAnnouncer {
        let a = DictationAnnouncer(pid: 7, now: clock, startTimer: timer.start, post: posts)
        a.holdActivity = { [unowned self] in self.activity.append($0) }
        return a
    }

    func testHeartbeatEvery15SecondsWhileOnAndNoneAfter() {
        var posts: [[String: Any]] = []
        var now = 100.0
        let timer = FakeTimer()
        let a = announcer({ posts.append($0) }, clock: { now }, timer: timer)
        a.phaseChanged(.preparingCapture)
        a.phaseChanged(.recording)
        XCTAssertEqual(timer.interval, 15)
        for _ in 0..<3 { now += 15; timer.fire?() }
        a.phaseChanged(.transcribing)
        XCTAssertNil(timer.fire, "the heartbeat stops with the recording")
        XCTAssertEqual(timer.cancels, 1)
        a.heartbeat() // a late tick
        XCTAssertEqual(posts.map { $0["reason"] as? String }, ["start", "heartbeat", "heartbeat", "heartbeat", "stop"])
        XCTAssertEqual(posts.map { $0["state"] as? String }, ["on", "on", "on", "on", "off"])
        XCTAssertEqual(posts.map { $0["sent"] as? Double }, [100, 115, 130, 145, 145])
        XCTAssertEqual(Set(posts.map { $0["session"] as? String }).count, 1, "one session throughout")
        XCTAssertEqual(posts.first?["pid"] as? Int, 7)
        XCTAssertEqual(activity, [true, false], "App Nap is held off only while on")
    }
    func testHelloQuitAndShortcutChange() throws {
        var posts: [[String: Any]] = []
        var binding = ShortcutConfiguration.default
        let a = announcer({ posts.append($0) }, clock: { 1 }, timer: FakeTimer())
        a.shortcut = { shortcutSignalFields(binding) }
        a.shortcutMayHaveChanged()
        XCTAssertTrue(posts.isEmpty, "no hello for a binding before the launch hello")
        a.hello()
        a.shortcutMayHaveChanged()
        XCTAssertEqual(posts.count, 1, "an unchanged binding sends nothing")
        binding = ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .right), behavior: .holdToTalk)
        a.shortcutMayHaveChanged()
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[1]["reason"] as? String, "hello")
        XCTAssertEqual(posts[1]["shortcutLabel"] as? String, ShortcutLabels.display(binding))
        a.phaseChanged(.preparingCapture)
        a.quit(); a.quit()
        a.hello(); a.phaseChanged(.idle)
        XCTAssertEqual(posts.map { $0["reason"] as? String }, ["hello", "hello", "start", "quit"])
        XCTAssertEqual(posts.last?["state"] as? String, "off", "quit is always off")
    }
}

final class HeimdallASRCoreTests: XCTestCase {
    func ready(_ socket: String = "/tmp/h.sock", pid: Int = 9, model: String = "parakeet-v3-ultra") -> HeimdallAnnouncement {
        HeimdallAnnouncement(state: .ready, socket: socket, model: model, pid: pid)
    }
    func testAnnouncementParsing() {
        let info: [AnyHashable: Any] = ["v": 1, "state": "ready", "socket": "/x/asr.sock", "model": "parakeet-v3-ultra", "pid": 12, "sent": 3.5, "app": "dev.heimdall.app"]
        XCTAssertEqual(HeimdallAnnouncement(userInfo: info), HeimdallAnnouncement(state: .ready, socket: "/x/asr.sock", model: "parakeet-v3-ultra", pid: 12, sent: 3.5))
        var alpha = info; alpha["app"] = "com.tobynoskillson.heimdall"
        XCTAssertEqual(HeimdallAnnouncement(userInfo: alpha)?.app, "com.tobynoskillson.heimdall")
        var unknown = info; unknown["app"] = "com.example.other"
        XCTAssertNil(HeimdallAnnouncement(userInfo: unknown), "a ready from an unknown app")
        XCTAssertNil(HeimdallAnnouncement(userInfo: ["v": 2, "state": "ready", "socket": "/x"]), "another protocol version")
        XCTAssertNil(HeimdallAnnouncement(userInfo: ["v": 1, "state": "ready", "socket": "relative.sock"]))
        XCTAssertNil(HeimdallAnnouncement(userInfo: ["v": 1, "state": "maybe"]))
        XCTAssertNil(HeimdallAnnouncement(userInfo: nil))
        XCTAssertEqual(HeimdallAnnouncement(userInfo: ["v": 1, "state": "gone", "pid": 12])?.state, .gone)
    }
    func testBorrowsOnlyParakeetUltraWhileReady() {
        var state = HeimdallBorrowState()
        XCTAssertNil(state.socket(for: "parakeet-v3-ultra"), "absent")
        XCTAssertEqual(state.label, "absent")
        state.receive(ready())
        XCTAssertEqual(state.socket(for: "parakeet-v3-ultra"), "/tmp/h.sock")
        XCTAssertNil(state.socket(for: "parakeet-v3"), "another model is unaffected")
        XCTAssertNil(state.socket(for: nil))
        var other = HeimdallBorrowState(); other.receive(ready(model: "whisper"))
        XCTAssertNil(other.socket(for: "parakeet-v3-ultra"), "Heimdall holding another model")
    }
    func testAFailureFallsBackUntilTheNextReady() {
        var state = HeimdallBorrowState()
        state.receive(ready())
        state.failed("busy")
        XCTAssertNil(state.socket(for: "parakeet-v3-ultra"))
        XCTAssertEqual(state.label, "unavailable")
        XCTAssertEqual(state.lastFailure, "busy")
        state.receive(ready())
        XCTAssertEqual(state.socket(for: "parakeet-v3-ultra"), "/tmp/h.sock")
        XCTAssertNil(state.lastFailure)
    }
    func testAReannouncementDuringARequestKeepsItsFailure() {
        var state = HeimdallBorrowState()
        let asked = HeimdallAnnouncement(state: .ready, socket: "/s", model: "parakeet-v3-ultra", pid: 4, sent: 1)
        state.receive(asked)
        state.receive(HeimdallAnnouncement(state: .ready, socket: "/s", model: "parakeet-v3-ultra", pid: 4, sent: 2)) // a query reply
        state.failed("busy", for: asked)
        XCTAssertEqual(state.label, "unavailable")
    }
    func testAReadyWithoutAPidIsIgnored() {
        XCTAssertNil(HeimdallAnnouncement(userInfo: ["v": 1, "state": "ready", "socket": "/x/asr.sock", "model": "parakeet-v3-ultra"]))
    }
    func testAStaleFailureDoesNotDisableANewerHeimdall() {
        var state = HeimdallBorrowState()
        let old = ready(pid: 1)
        state.receive(old)
        state.receive(ready(pid: 2))
        state.failed("connect", for: old)
        XCTAssertEqual(state.label, "ready")
        state.failed("busy", for: ready(pid: 2))
        XCTAssertEqual(state.label, "unavailable")
    }
    func testGoneEndsBorrowingButNotAnotherHeimdallsReadiness() {
        var state = HeimdallBorrowState()
        state.receive(ready(pid: 9))
        state.receive(HeimdallAnnouncement(state: .gone, socket: "", model: "", pid: 8))
        XCTAssertNotNil(state.socket(for: "parakeet-v3-ultra"), "a gone from an older Heimdall")
        state.receive(HeimdallAnnouncement(state: .gone, socket: "", model: "", pid: 9))
        XCTAssertNil(state.socket(for: "parakeet-v3-ultra"))
        XCTAssertEqual(state.label, "absent")
    }
    func testWireFormat() throws {
        let header = HeimdallASRWire.header(samples: 3)
        XCTAssertEqual(header.last, 10)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: header.dropLast()) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1); XCTAssertEqual(object["op"] as? String, "transcribe")
        XCTAssertEqual(object["model"] as? String, "parakeet-v3-ultra"); XCTAssertEqual(object["rate"] as? Int, 16_000)
        XCTAssertEqual(object["samples"] as? Int, 3); XCTAssertEqual(object["format"] as? String, "f32le")
        XCTAssertEqual(HeimdallASRWire.body([1, -0.5]), Data([0, 0, 0x80, 0x3F, 0, 0, 0, 0xBF]))
        XCTAssertEqual(try HeimdallASRWire.parse(Data(#"{"v":1,"ok":true,"text":"hi","queue_ms":3,"decode_ms":120,"audio_ms":8400}"#.utf8)).get(),
            HeimdallTranscript(text: "hi", queueMs: 3, decodeMs: 120, audioMs: 8400))
        XCTAssertEqual(HeimdallASRWire.parse(Data(#"{"v":1,"ok":false,"error":"busy"}"#.utf8)), .failure(.rejected("busy")))
        XCTAssertEqual(HeimdallASRWire.parse(Data("nope".utf8)), .failure(.invalidReply))
        XCTAssertEqual(HeimdallASRWire.parse(Data(#"{"v":1,"ok":true}"#.utf8)), .failure(.invalidReply))
        XCTAssertEqual(HeimdallASRWire.timeout(audioSeconds: 0), 5)
        XCTAssertEqual(HeimdallASRWire.timeout(audioSeconds: 30), 8)
    }
    func testWAVSamples() throws {
        func wav(format: UInt16, bits: UInt16, rate: UInt32 = 16_000, channels: UInt16 = 1, body: Data) -> Data {
            var d = Data("RIFF".utf8)
            func u32(_ n: UInt32) { withUnsafeBytes(of: n.littleEndian) { d.append(contentsOf: $0) } }
            func u16(_ n: UInt16) { withUnsafeBytes(of: n.littleEndian) { d.append(contentsOf: $0) } }
            u32(UInt32(36 + body.count)); d.append(Data("WAVEfmt ".utf8)); u32(16)
            u16(format); u16(channels); u32(rate); u32(rate * UInt32(bits / 8)); u16(bits / 8); u16(bits)
            d.append(Data("data".utf8)); u32(UInt32(body.count)); d.append(body)
            return d
        }
        var pcm = Data()
        for value: Int16 in [16384, -32768] { withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) } }
        XCTAssertEqual(try heimdallWAVSamples(wav(format: 1, bits: 16, body: pcm)), [0.5, -1])
        XCTAssertEqual(try heimdallWAVSamples(wav(format: 3, bits: 32, body: HeimdallASRWire.body([0.25]))), [0.25])
        XCTAssertThrowsError(try heimdallWAVSamples(wav(format: 1, bits: 16, rate: 44_100, body: pcm)))
        XCTAssertThrowsError(try heimdallWAVSamples(wav(format: 1, bits: 16, channels: 2, body: pcm)))
        XCTAssertThrowsError(try heimdallWAVSamples(Data("garbage".utf8)))
        XCTAssertThrowsError(try heimdallWAVSamples(wav(format: 1, bits: 24, body: Data(count: 6))), "never silence for another format")
    }
    func testStatusFieldsRoundTripAndOldFilesStillDecode() throws {
        var status = WorkerStatus()
        status.heimdall = HeimdallStatus(state: "ready", socket: "/s", model: "parakeet-v3-ultra", pid: 3, borrowing: true)
        status.last_dictation = LastDictationStatus(path: "heimdall", model: "parakeet-v3-ultra", at: 5, seconds: 0.4, audio_seconds: 8)
        let decoded = try JSONDecoder().decode(WorkerStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertNil(try JSONDecoder().decode(WorkerStatus.self, from: Data(#"{"updated":1}"#.utf8)).heimdall)
    }
    func testDiagnoseReportsThePathWithoutLocalPaths() throws {
        var d = Diagnosis(host: Diagnosis.Host(), running: true)
        d.heimdall = HeimdallStatus(state: "unavailable", socket: "/Users/someone/Library/x.sock", pid: 4, borrowing: false, last_failure: "busy")
        d.lastDictation = LastDictationStatus(path: "vella", model: "/Users/someone/Models/m", at: 1, seconds: 1.25, fallback: "busy")
        XCTAssertEqual(Diagnose.heimdallLine(d), "heimdall: unavailable (last request: busy) · last dictation via Vella's model in 1.25 s (fell back: busy)")
        let json = Diagnose.jsonText(d, issueURL: "u")
        XCTAssertFalse(json.contains("/Users/someone"))
        XCTAssertTrue(json.contains(#""last_failure" : "busy""#))
        XCTAssertNil(Diagnose.heimdallLine(Diagnosis(host: Diagnosis.Host(), running: true)))
    }
}

/// The client against a fake Heimdall socket: ok, busy, garbage, silence (timeout), close mid-request, and no socket.
final class HeimdallSocketClientTests: XCTestCase {
    let audio: [Float] = (0..<8000).map { Float($0 % 100) / 100 }
    func testThePeerMustBeTheAnnouncedProcess() async throws {
        let server = try FakeHeimdallServer(reply: .ok("x")); defer { server.stop() }
        let ok = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio, peer: getpid())
        XCTAssertEqual(ok.text, "x")
        do { _ = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio, peer: 1); XCTFail() } catch let error as HeimdallASRError {
            XCTAssertEqual(error, .connect("peer"))
        }
    }
    func testOkSendsTheHeaderAndEveryByte() async throws {
        let server = try FakeHeimdallServer(reply: .ok("hello there")); defer { server.stop() }
        let reply = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio)
        XCTAssertEqual(reply.text, "hello there")
        XCTAssertEqual(reply.audioMs, 500)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.samples, 8000); XCTAssertEqual(request.bytes, 32_000); XCTAssertEqual(request.firstSample, 0)
        XCTAssertEqual(request.header["op"], "transcribe"); XCTAssertEqual(request.header["format"], "f32le")
        let ok = await HeimdallASRClient.status(socket: server.path)
        XCTAssertTrue(ok)
    }
    func testBusyIsARejection() async throws {
        let server = try FakeHeimdallServer(reply: .error("busy")); defer { server.stop() }
        do { _ = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio); XCTFail("busy must throw") } catch let error as HeimdallASRError {
            XCTAssertEqual(error, .rejected("busy"))
        }
    }
    func testGarbageIsAnInvalidReply() async throws {
        let server = try FakeHeimdallServer(reply: .garbage); defer { server.stop() }
        do { _ = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio); XCTFail() } catch let error as HeimdallASRError {
            XCTAssertEqual(error, .invalidReply)
        }
    }
    func testSilenceTimesOut() async throws {
        let server = try FakeHeimdallServer(reply: .silence); defer { server.stop() }
        let start = Date()
        do { _ = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio, timeout: 0.4); XCTFail() } catch let error as HeimdallASRError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCloseWithoutAReply() async throws {
        let server = try FakeHeimdallServer(reply: .close); defer { server.stop() }
        do { _ = try await HeimdallASRClient.transcribe(socket: server.path, samples: audio, timeout: 2); XCTFail() } catch let error as HeimdallASRError {
            XCTAssertEqual(error, .invalidReply)
        }
    }
    func testNoSocketIsAConnectFailure() async {
        do { _ = try await HeimdallASRClient.transcribe(socket: "/tmp/vh-missing-\(UUID().uuidString.prefix(6)).sock", samples: audio); XCTFail() } catch let error as HeimdallASRError {
            XCTAssertEqual(error.code, "connect")
        } catch { XCTFail("\(error)") }
        let ok = await HeimdallASRClient.status(socket: "/tmp/vh-none.sock")
        XCTAssertFalse(ok)
    }
    func testCancellationStopsWaiting() async throws {
        let server = try FakeHeimdallServer(reply: .silence); defer { server.stop() }
        let task = Task { try await HeimdallASRClient.transcribe(socket: server.path, samples: audio, timeout: 10) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let start = Date()
        do { _ = try await task.value; XCTFail() } catch let error as HeimdallASRError { XCTAssertEqual(error, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

/// The "from Heimdall" row's choice rules (HeimdallSelection.swift).
final class HeimdallSelectionTests: XCTestCase {
    func testOnlyAUserWhoNeverChoseGetsHeimdallByDefault() {
        let fresh = Configuration(model: "")
        XCTAssertEqual(effectiveDictationSource(fresh, heimdallDetected: true), .heimdall)
        XCTAssertEqual(effectiveDictationSource(fresh, heimdallDetected: false), .own)
        XCTAssertEqual(effectiveDictationSource(Configuration(model: "/m/whisper"), heimdallDetected: true), .own, "a model chosen before this setting")
        var own = Configuration(model: ""); own.dictationSource = .own
        XCTAssertEqual(effectiveDictationSource(own, heimdallDetected: true), .own, "an explicit choice survives Heimdall appearing")
        var cleared = Configuration(model: ""); cleared.clearedSelectionReasons["dictation"] = "retired"
        XCTAssertEqual(effectiveDictationSource(cleared, heimdallDetected: true), .own, "an upgrade-cleared choice is still a past choice")
        var loaded = Configuration(model: ""); loaded.recordLoad(path: "/m/x", mode: .dictation, family: nil, precision: nil)
        XCTAssertEqual(loaded.dictationSource, .own, "Load and Get record an own choice")
        // A selection stored before this build is a known choice (Vella writes one only on Get or Load): it stays, even
        // when it is Vella's own copy of the model Heimdall holds and Heimdall is present (Toby, 28 Oct).
        let ultra = Configuration(model: "/m/ultra")
        XCTAssertEqual(effectiveDictationSource(ultra, heimdallDetected: true), .own)
        XCTAssertEqual(effectiveDictationSource(Configuration(model: "/m/qwen"), heimdallDetected: true), .own)
        var migrated = Configuration(model: ""); migrated.dictationSource = .heimdall
        migrated.selectModel("/m/replacement", for: .dictation) // what an upgrade migration does
        XCTAssertEqual(migrated.dictationSource, .heimdall, "a migration never changes the choice")
        var untouched = Configuration(model: "/m/ultra-old"); untouched.selectModel("/m/ultra-new", for: .dictation)
        XCTAssertNil(untouched.dictationSource, "nor turns a never-chose user into an explicit one")
        XCTAssertEqual(effectiveDictationSource(untouched, heimdallDetected: true), .own, "and a migrated legacy selection stays own")
        untouched.markOwnChoice(.dictation)
        XCTAssertEqual(untouched.dictationSource, .own)
        var heimdall = Configuration(model: "/m/whisper"); heimdall.dictationSource = .heimdall
        XCTAssertEqual(effectiveDictationSource(heimdall, heimdallDetected: false), .heimdall, "and Heimdall going away")
    }
    func testLoadingADictationModelRecordsOwnAndTheChoicePersists() throws {
        var config = Configuration(model: ""); config.dictationSource = .heimdall
        config.recordLoad(path: "/m/s", mode: .streaming, family: nil, precision: nil)
        XCTAssertEqual(config.dictationSource, .heimdall, "a streaming load is not a dictation choice")
        config.recordLoad(path: "/m/d", mode: .dictation, family: nil, precision: nil)
        XCTAssertEqual(config.dictationSource, .own)
        config.dictationSource = .heimdall
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.dictationSource, .heimdall, "kept across a restart")
        XCTAssertNil(try JSONDecoder().decode(Configuration.self, from: Data(#"{"model":"/m"}"#.utf8)).dictationSource)
    }
    func testPresence() {
        XCTAssertEqual(HeimdallPresence.of(installed: true, ready: true, unavailable: false), .present)
        XCTAssertEqual(HeimdallPresence.of(installed: false, ready: true, unavailable: false), .present, "a development build answering")
        XCTAssertEqual(HeimdallPresence.of(installed: true, ready: false, unavailable: false), .offline)
        XCTAssertEqual(HeimdallPresence.of(installed: true, ready: true, unavailable: true), .offline, "busy or failing")
        XCTAssertEqual(HeimdallPresence.of(installed: false, ready: false, unavailable: false), .absent)
    }
    func testProjectURLIsUnsetUntilConfigured() {
        XCTAssertNil(HeimdallApp.projectURL(nil))
        XCTAssertNil(HeimdallApp.projectURL(Bundle.main.infoDictionary), "no page exists yet")
        XCTAssertNil(HeimdallApp.projectURL([HeimdallApp.projectURLKey: "http://example.com"]), "https only")
        XCTAssertNil(HeimdallApp.projectURL([HeimdallApp.projectURLKey: "file:///etc"]))
        XCTAssertEqual(HeimdallApp.projectURL([HeimdallApp.projectURLKey: "https://example.com/h"]), URL(string: "https://example.com/h"))
        XCTAssertEqual(HeimdallApp.bundleIdentifiers, ["dev.heimdall.app", "com.tobynoskillson.heimdall"])
    }
}
