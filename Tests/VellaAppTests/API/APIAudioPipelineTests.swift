import Foundation
import XCTest
@testable import Vella
import VellaCore

final class APIAudioPipelineTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-overlap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private func compare(_ file: URL, root: URL) async throws {
        let config = Configuration(model: "")
        let (old, duration) = try APIAudio.segment(file, root: root, config: config)
        var expected: [Data] = []
        let before = SessionTranscriber { url, _ in
            expected.append(try Data(contentsOf: url))
            return "boundary word \(expected.count)"
        }
        let text = try await before.run(old)
        var received: [Data] = []
        let after = SessionTranscriber { url, _ in
            received.append(try Data(contentsOf: url))
            return "boundary word \(received.count)"
        }
        let (new, newDuration) = try await APIAudio.overlapping(file, root: root, config: config, runner: after)
        XCTAssertEqual(duration, newDuration)
        XCTAssertEqual(old.manifest.segments, new.manifest.segments, "Every cut, Float32 SHA, text and merge is unchanged")
        XCTAssertEqual(expected, received, "Every request WAV is byte-identical, in the same order")
        XCTAssertEqual(text, try RecordingSession.assemble(new.manifest.segments))
        XCTAssertEqual(APIAudio.segments(old).segments, APIAudio.segments(new).segments)
        try FileManager.default.removeItem(at: old.directory)
        try FileManager.default.removeItem(at: new.directory)
    }

    @MainActor func testForcedCutsPauseAndShortTailAreIdentical() async throws {
        let root = try root(), file = root.appendingPathComponent("cuts.wav")
        try writeTestWAV(file, bursts: [75, 6, 0.1], rate: 16_000)
        try await compare(file, root: root)
    }

    @MainActor func testLongQuietTailAndExactRedundantOverlapAreIdentical() async throws {
        let root = try root(), file = root.appendingPathComponent("quiet.wav")
        try writeTestWAV(file, bursts: [70], gap: 70, rate: 16_000)
        try await compare(file, root: root)
        let exact = root.appendingPathComponent("exact.wav")
        try writeTestWAV(exact, bursts: [98.5], gap: 0, rate: 16_000)
        try await compare(exact, root: root)
    }

    @MainActor func testCapRefusesBeforeAnyRequestOrSession() async throws {
        let root = try root(), file = root.appendingPathComponent("too-long.wav")
        try writeTestWAV(file, bursts: [6], rate: 16_000)
        var requests = 0
        let runner = SessionTranscriber { _, _ in
            requests += 1; return "wrong"
        }
        do {
            _ = try await APIAudio.overlapping(file, root: root, config: Configuration(model: ""), runner: runner, maxSeconds: 5)
            XCTFail("Oversize file accepted")
        } catch let error as APIError { XCTAssertEqual(error.code, "audio_too_long") }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["too-long.wav"])
    }

    @MainActor func testCancelWhileProducerIsBackpressuredJoinsAndRemovesBothSessions() async throws {
        let root = try root(), file = root.appendingPathComponent("cancel.wav")
        try writeTestWAV(file, bursts: [150], rate: 16_000)
        var requested = false
        let runner = SessionTranscriber { _, _ in
            requested = true
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "wrong"
        }
        let task = Task { try await APIAudio.overlapping(file, root: root, config: Configuration(model: ""), runner: runner) }
        while !requested { try await Task.sleep(nanoseconds: 1_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled job succeeded") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["cancel.wav"])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["cancel.wav"], "No decoder/task creates files after return")
    }

    @MainActor func testWorkerExitMidFileGetsOneRetryAndSecondExitCleansUp() async throws {
        let root = try root(), file = root.appendingPathComponent("retry.wav")
        try writeTestWAV(file, bursts: [150], rate: 16_000)
        let (old, _) = try APIAudio.segment(file, root: root, config: Configuration(model: ""))
        var expected: [Data] = []
        _ = try await SessionTranscriber { url, _ in
            expected.append(try Data(contentsOf: url)); return "text"
        }.run(old)
        try FileManager.default.removeItem(at: old.directory)
        for failTwice in [false, true] {
            var calls = 0, failures = 0, received: [Data] = []
            let runner = SessionTranscriber { url, _ in
                calls += 1
                if calls == 2 || (failTwice && calls == 3) { failures += 1; throw WorkerExited() }
                received.append(try Data(contentsOf: url))
                return "text"
            }
            do {
                let (session, _) = try await APIAudio.overlapping(file, root: root, config: Configuration(model: ""), runner: runner)
                XCTAssertFalse(failTwice)
                XCTAssertEqual(received, expected)
                XCTAssertEqual(failures, 1)
                try FileManager.default.removeItem(at: session.directory)
            } catch is WorkerExited { XCTAssertTrue(failTwice); XCTAssertEqual(failures, 2) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["retry.wav"])
        }
    }
    @MainActor func testActualAPIWorkerExitOnSecondSegmentRetriedOnceThenReturnsExistingError() async throws {
        for failTwice in [false, true] {
            let api = try await APIFixture(models: ["fake-a"])
            defer { api.close() }
            let helper = api.root.appendingPathComponent("api-fake-worker.py")
            let script = APIFakeWorker.script.replacingOccurrences(
                of: "note('start',name)",
                with: """
                    counter=os.path.join(r['model'],'.requests')
                    n=int(open(counter).read())+1 if os.path.exists(counter) else 1
                    open(counter,'w').write(str(n))
                    if n==2\(failTwice ? " or n==3" : ""): os._exit(3)
                    note('start',name)
                    """.replacingOccurrences(of: "\n", with: "\n    "))
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let file = api.root.appendingPathComponent("mid-file.wav")
            try writeTestWAV(file, bursts: [150], rate: 16_000)
            let model = api.models.list[0]
            do {
                _ = try await api.transcriber.transcribe(file, resolve: { model }, current: { nil })
                XCTAssertFalse(failTwice)
                XCTAssertGreaterThan(api.requests().filter { $0.hasPrefix("start ") }.count, 2)
            } catch let error as APIError {
                XCTAssertTrue(failTwice)
                XCTAssertEqual(error.code, "worker_exited")
                XCTAssertEqual(error.message, APITranscriber.workerExited)
                let attempts = try String(contentsOf: URL(fileURLWithPath: model.path).appendingPathComponent(".requests"), encoding: .utf8)
                XCTAssertEqual(attempts, "3")
            }
            XCTAssertEqual(api.leftovers(), [])
        }
    }

    /// Full public-domain fixture, enabled by the local receipt job; ordinary CI has no hour-long audio asset.
    @MainActor func testBerylFullFileThroughActualAPITranscriber() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_OVERLAP_BERYL"] else { throw XCTSkip("Local Beryl fixture not requested") }
        let api = try await APIFixture(models: ["fake-a"])
        defer { api.close() }
        let model = api.models.list[0]
        let helper = api.root.appendingPathComponent("api-fake-worker.py")
        let script = APIFakeWorker.script.replacingOccurrences(of: "import json,sys,os,time", with: "import json,sys,os,time,hashlib")
            .replacingOccurrences(of: "note('start',name)", with: "note('wav:'+hashlib.sha256(open(r['audio'],'rb').read()).hexdigest(),name); note('start',name)")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        let file = URL(fileURLWithPath: path)
        let (old, duration) = try APIAudio.segment(file, root: api.root, config: Configuration(model: model.path))
        var hashes: [String] = []
        let expectedText = try await SessionTranscriber { url, _ in
            let data = try Data(contentsOf: url)
            hashes.append(RecordingSession.digest(data))
            return String(format: "fake-a heard %.2f s.", Double(data.count - 44) / 32_000)
        }.run(old)
        let expected = APIAudio.segments(old)
        let result = try await api.transcriber.transcribe(file, resolve: { model }, current: { nil })
        let received = api.requests().filter { $0.hasPrefix("wav:") }.map { String($0.split(separator: " ")[0].dropFirst(4)) }
        XCTAssertEqual(received, hashes)
        XCTAssertEqual(result.text, expectedText)
        XCTAssertEqual(result.segments, expected.segments)
        XCTAssertEqual(result.duration, duration)
        XCTAssertEqual(api.leftovers(), [])
        // Separate whole-file segmentation comparison includes every exact Float32 segment SHA/cut, not only PCM16.
        try await compare(file, root: api.root)
        print("OVERLAP Beryl actual API: \(hashes.count) byte-identical WAVs, exact text/timestamps/duration and all Float32 cuts/hashes")
    }

}
