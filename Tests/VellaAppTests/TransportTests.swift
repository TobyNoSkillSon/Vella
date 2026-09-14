import XCTest
import Foundation
import Darwin
@testable import Vella
import VellaCore

final class TransportTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() throws -> (URL, RecordingSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-ipc-tests-\(UUID())")
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("worker.py")
        try #"""
import json,sys,time,os,signal
for line in sys.stdin:
 r=json.loads(line); mode=r['model'].split('/')[-1]
 if mode in ('timeout','stubborn'):
  if mode=='stubborn': signal.signal(signal.SIGTERM,signal.SIG_IGN)
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
            let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script, requestTimeout: 0.4)
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
            let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script)
            defer { backend.stop() }
            let text = try await SessionTranscriber { url, config in try await backend.transcribe(url, config: config) }.run(record)
            XCTAssertEqual(text, "")
            XCTAssertEqual(try RecordingSession(directory: record.directory).manifest.segments[0].text, "")
            XCTAssertEqual(record.manifest.state, "transcribed")
        }
    }
    @MainActor func testWarmReuseSwitchAndIdleExit() async throws {
        let (script, record) = try fixture()
        let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script, idleTimeout: 0.15)
        defer { backend.stop() }
        let wav = try record.wav(for: record.manifest.segments[0])
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        let first = try XCTUnwrap(backend.processID)
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        XCTAssertEqual(backend.processID, first)
        record.manifest.config.model = "/fixture/other"
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        let second = try XCTUnwrap(backend.processID)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(kill(first, 0), 0, "Old process must exit BEFORE a new model starts")
        try await exited(second)
        XCTAssertNil(backend.processID)
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        XCTAssertNotEqual(backend.processID, second)
    }
    @MainActor func testCancellationKillsOnlyItsOwnWorkerAndAllowsRestart() async throws {
        let (script, record) = try fixture()
        let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script)
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
    @MainActor func testMemoryPressureReleasesIdleWorkerAndShutdownDoesNotNeedDelayedCallbacks() async throws {
        let (script, record) = try fixture()
        let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script)
        let wav = try record.wav(for: record.manifest.segments[0])
        _ = try await backend.transcribe(wav, config: record.manifest.config)
        let idlePID = try XCTUnwrap(backend.processID)
        backend.handleMemoryPressure(critical: false)
        try await exited(idlePID)
        record.manifest.config.model = "/fixture/stubborn"
        let task = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<100 { if backend.processID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = try XCTUnwrap(backend.processID)
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        backend.shutdown()
        _ = try? await task.value
        try await exited(pid)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Shutdown must send KILL synchronously rather than depend on a callback after app exit")
    }
    @MainActor func testConcurrentRequestIsRejectedWithoutStoppingOriginal() async throws {
        let (script, record) = try fixture()
        let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script)
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
        let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script)
        defer { backend.shutdown() }
        let wav = try record.wav(for: record.manifest.segments[0])
        record.manifest.config.model = "/fixture/stubborn"
        let first = Task { try await backend.transcribe(wav, config: record.manifest.config) }
        for _ in 0..<100 { if backend.processID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = try XCTUnwrap(backend.processID)
        try await Task.sleep(nanoseconds: 150_000_000)
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
        let backend = Backend(python: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: script)
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
