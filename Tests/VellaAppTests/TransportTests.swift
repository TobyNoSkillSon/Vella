import XCTest
import Foundation
import Darwin
@testable import Vella
import VellaCore

final class TransportTests: XCTestCase {
    private var roots: [URL] = []
    @MainActor private func runtime(minuteSeconds: Double = 60) throws -> Runtime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-ipc-runtime-\(UUID())")
        roots.append(root)
        return try Runtime.isolated(root, minuteSeconds: minuteSeconds)
    }
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() throws -> (URL, RecordingSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-ipc-tests-\(UUID())")
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("worker.py")
        try #"""
#!/usr/bin/env python3
import json,sys,time,os,signal
for line in sys.stdin:
 r=json.loads(line)
 if r.get('op') in ('unload','status','trim'): print(json.dumps({'id':r['id'],'ok':True}),flush=True); continue
 mode=r['model'].split('/')[-1]
 if mode=='slow' and r.get('op')!='load': time.sleep(0.8)
 if mode in ('timeout','stubborn'):
  if mode=='stubborn':
   signal.signal(signal.SIGTERM,signal.SIG_IGN)
   open(os.path.join(os.path.dirname(__file__),'stubborn-ready'),'w').close()
  time.sleep(10)
 if mode=='exit': sys.exit(2)
 if mode=='malformed': print('{bad',flush=True); continue
 if mode=='oversize': print('x'*2100000,flush=True); continue
 obj={'id':r['id'],'text':'Fixture recognized speech.','metrics':{'pid':os.getpid()}}
 if mode=='failure': obj={'id':r['id'],'error':{'code':'inference','message':'not persisted'}}
 if mode=='empty': obj['text']=''
 if mode=='legacyempty': obj={'id':r['id'],'error':{'code':'no_speech'}}
 if mode=='wrongid': obj['id']='wrong'
 print(json.dumps(obj),flush=True)
"""#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let record = try RecordingSession(root: root, config: Configuration(executable: "/unused", model: "/fixture/normal"))
        let writer = try SegmentedPCMWriter(session: record)
        try [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        return (script, record)
    }
    @MainActor private func exited(_ pid: Int32) async throws {
        for _ in 0..<180 { if kill(pid, 0) != 0 { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Test-owned worker did not exit")
    }
    @MainActor func testIPCFailuresPreserveAudioAndNeverCommitInvalidText() async throws {
        for mode in ["timeout", "failure", "malformed", "exit", "oversize", "wrongid"] {
            let (script, record) = try fixture()
            record.manifest.config.model = "/fixture/\(mode)"
            let backend = Backend(helper: script, requestTimeout: 0.4, runtime: try runtime())
            defer { backend.stop() }
            do { _ = try await SessionTranscriber { url, config in try await backend.transcribe(url, config: config) }.run(record); XCTFail(mode) }
            catch { if mode == "timeout" { XCTAssertEqual((error as? URLError)?.code, .timedOut) } }
            let recovered = try RecordingSession(directory: record.directory)
            XCTAssertEqual(recovered.manifest.segments[0].frames, 1600)
            XCTAssertNil(recovered.manifest.segments[0].text)
        }
    }
    @MainActor func testEmptyAndLegacyEmptyIPCResponsesAreSuccessful() async throws {
        for mode in ["empty", "legacyempty"] {
            let (script, record) = try fixture()
            record.manifest.config.model = "/fixture/\(mode)"
            let backend = Backend(helper: script, runtime: try runtime())
            defer { backend.stop() }
            let text = try await SessionTranscriber { url, config in try await backend.transcribe(url, config: config) }.run(record)
            XCTAssertEqual(text, "")
            XCTAssertEqual(try RecordingSession(directory: record.directory).manifest.segments[0].text, "")
            XCTAssertEqual(record.manifest.state, "transcribed")
        }
    }
    @MainActor func testWarmReuseSwitchKeepsBothHotAndIdleExit() async throws {
        let (script, record) = try fixture()
        let backend = Backend(helper: script, runtime: try runtime(minuteSeconds: 0.02)) // 15 min on demand = 0.3 s
        defer { backend.shutdown() }
        let wav = try record.wav(for: record.manifest.segments[0])
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        let first = try XCTUnwrap(backend.processID)
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        XCTAssertEqual(backend.processID, first)
        record.manifest.config.model = "/fixture/other"
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        let second = try XCTUnwrap(backend.processID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(kill(first, 0), 0, "Another model stays hot within its Keep Hot window")
        try await exited(first)
        try await exited(second)
        XCTAssertNil(backend.processID)
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        XCTAssertNotEqual(backend.processID, second)
    }
    @MainActor func testCancellationKillsOnlyItsOwnWorkerAndAllowsRestart() async throws {
        let (script, record) = try fixture()
        let backend = Backend(helper: script, runtime: try runtime())
        defer { backend.stop() }
        let wav = try record.wav(for: record.manifest.segments[0])
        record.manifest.config.model = "/fixture/stubborn"
        let task = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<100 { if backend.processID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = try XCTUnwrap(backend.processID)
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        try await exited(pid)
        record.manifest.config.model = "/fixture/normal"
        let text = try await backend.transcribe(wav, config: record.manifest.config)
        XCTAssertEqual(text, "Fixture recognized speech.")
    }
    @MainActor func testMemoryPressureNeverStopsInFlightRequestAndShedsIdleModels() async throws {
        let (script, record) = try fixture()
        let runtime = try runtime()
        let backend = Backend(helper: script, runtime: runtime)
        defer { backend.shutdown() }
        let wav = try record.wav(for: record.manifest.segments[0])
        var pids: [String: Int32] = [:]
        for name in ["normal", "other"] {
            record.manifest.config.model = "/fixture/\(name)"
            _ = try await backend.transcribe(wav, config: record.manifest.config)
            pids[name] = try XCTUnwrap(backend.processID)
        }
        backend.handleMemoryPressure(critical: false) // warning: caches only, everything stays hot
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Set(backend.loadedModelIDs), ["normal", "other", ])
        record.manifest.config.model = "/fixture/slow"
        let busy = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<200 { if runtime.isLoaded("slow") { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000) // the request is now in flight
        let slowPID = try XCTUnwrap(backend.processID)
        backend.handleMemoryPressure(critical: true)
        let text = try await busy.value
        XCTAssertEqual(text, "Fixture recognized speech.", "critical pressure must not stop the in-flight request")
        XCTAssertEqual(kill(slowPID, 0), 0, "the busy model is pinned, not shed")
        try await exited(try XCTUnwrap(pids["other"]))
        XCTAssertEqual(Set(backend.loadedModelIDs), ["normal", "slow"], "shed keeps the first loaded model and the pinned one")
        XCTAssertTrue(runtime.status.evictions?.last?.reason.hasPrefix("memory pressure") == true)
    }
    @MainActor func testShutdownDoesNotNeedDelayedCallbacks() async throws {
        let (script, record) = try fixture()
        let backend = Backend(helper: script, runtime: try runtime())
        let wav = try record.wav(for: record.manifest.segments[0])
        record.manifest.config.model = "/fixture/stubborn"
        let task = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<200 { if backend.loadedModelIDs.contains("stubborn") { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = try XCTUnwrap(backend.processID)
        let start = Date()
        backend.shutdown()
        _ = try? await task.value
        try await exited(pid)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Shutdown must send KILL synchronously rather than depend on a callback after app exit")
    }
    @MainActor func testConcurrentRequestIsRejectedWithoutStoppingOriginal() async throws {
        let (script, record) = try fixture()
        let backend = Backend(helper: script, runtime: try runtime())
        defer { backend.stop() }
        let wav = try record.wav(for: record.manifest.segments[0])
        record.manifest.config.model = "/fixture/timeout"
        let task = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<100 { if backend.processID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = backend.processID
        do { _ = try await backend.transcribe(wav, config: record.manifest.config); XCTFail() } catch { }
        XCTAssertEqual(backend.processID, pid)
        task.cancel(); _ = try? await task.value
    }

    @MainActor func testStopDuringStartupCannotLaunchAReplacement() async throws {
        let (script, record) = try fixture()
        let backend = Backend(helper: script, runtime: try runtime())
        defer { backend.shutdown() }
        let wav = try record.wav(for: record.manifest.segments[0])
        record.manifest.config.model = "/fixture/stubborn"
        let first = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<100 { if backend.processID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = try XCTUnwrap(backend.processID)
        let ready = script.deletingLastPathComponent().appendingPathComponent("stubborn-ready")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        backend.stop(); _ = try? await first.value
        XCTAssertEqual(kill(pid, 0), 0, "Fixture predecessor must still be retiring")
        record.manifest.config.model = "/fixture/normal"
        let next = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(backend.processID)
        backend.stop() // Caller task itself is intentionally NOT cancelled.
        do { _ = try await next.value; XCTFail("A stopped startup launched inference") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(backend.processID)
        try await exited(pid)
    }

    @MainActor func testRepeatedWorkerFailuresRecoverWithoutLosingAudioOrLeakingChildren() async throws {
        let (script, record) = try fixture()
        let backend = Backend(helper: script, runtime: try runtime())
        defer { backend.shutdown() }
        let wav = try record.wav(for: record.manifest.segments[0])
        let archive = record.directory.appendingPathComponent(record.manifest.segments[0].filename)
        let original = try Data(contentsOf: archive)
        for cycle in 0..<12 {
            record.manifest.config.model = "/fixture/normal"
            _ = try await backend.transcribe(wav, config: record.manifest.config)
            let first = try XCTUnwrap(backend.processID)
            _ = try await backend.transcribe(wav, config: record.manifest.config)
            XCTAssertEqual(backend.processID, first)
            record.manifest.config.model = "/fixture/" + ["failure", "malformed", "exit", "wrongid"][cycle % 4]
            do { _ = try await backend.transcribe(wav, config: record.manifest.config); XCTFail("Expected fixture failure") }
            catch { }
            try await backend.releaseAndWait()
            XCTAssertNotEqual(kill(first, 0), 0)
            XCTAssertNil(backend.processID)
            record.manifest.config.model = "/fixture/normal"
            let recovered = try await backend.transcribe(wav, config: record.manifest.config)
            XCTAssertEqual(recovered, "Fixture recognized speech.")
            let last = try XCTUnwrap(backend.processID)
            try await backend.releaseAndWait()
            XCTAssertNotEqual(kill(last, 0), 0)
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
    }
}
