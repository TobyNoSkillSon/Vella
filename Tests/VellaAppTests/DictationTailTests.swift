import XCTest
import AVFoundation
@testable import Vella
import VellaCore

final class DictationTailTests: XCTestCase {
    @MainActor func testExactStopOverlapIsVerifiedWithoutInferenceAndMismatchIsRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlap-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: .init(executable: "/unused", model: "/synthetic"))
        var policy = SegmentedPCMWriter.Policy()
        policy.preferredSeconds = 1; policy.maximumSeconds = 2; policy.overlapSeconds = 0.1
        let writer = try SegmentedPCMWriter(session: session, policy: policy)
        try [Float](repeating: 0.1, count: 32000).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        XCTAssertEqual(session.manifest.segments.map(\.frames), [32000, 1600])
        XCTAssertEqual(session.manifest.segments[1].overlapFrames, 1600)
        session.manifest.segments[0].text = "Synthetic anchor."
        try session.save()
        XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.segments.count, 1)
        let transcriber = SessionTranscriber { _, _ in XCTFail("Duplicate needs no inference"); return "" }
        let text = try await transcriber.run(session)
        XCTAssertEqual(text, "Synthetic anchor.")
        // A self-consistent hash does not establish duplication: compare actual PCM.
        let changed = [Float](repeating: 0.2, count: 1600).withUnsafeBytes { Data($0) }
        try changed.write(to: session.directory.appendingPathComponent(session.manifest.segments[1].filename))
        session.manifest.segments[1].sha256 = RecordingSession.digest(changed)
        session.manifest.segments[1].text = nil
        try session.save()
        XCTAssertThrowsError(try RecordingSession(directory: session.directory))
        do { _ = try await transcriber.run(session); XCTFail("Must retain mismatched audio") } catch {}
        XCTAssertNil(session.manifest.segments[1].text)
    }
    private func fixture() throws -> RecordingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tail-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: .init(executable: "/unused", model: "/synthetic"))
        // A silence cut at five seconds followed by 117 ms of nonquiet audio.
        let writer = try SegmentedPCMWriter(session: session)
        let samples = [Float](repeating: 0.1, count: 73600) + [Float](repeating: 0, count: 6400)
            + [Float](repeating: 0.0042, count: 1877)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        XCTAssertEqual(session.manifest.segments.map(\.frames), [80000, 1877])
        session.manifest.segments[0].text = "A synthetic sentence."
        try session.save()
        return session
    }
    @MainActor func testShortTailUsesOnlyItsExactUnpaddedFramesAndPreservesPCM() async throws {
        let session = try fixture()
        let original = try session.manifest.segments.map { try Data(contentsOf: session.directory.appendingPathComponent($0.filename)) }
        let hashes = session.manifest.segments.map(\.sha256)
        var calls = 0
        let text = try await SessionTranscriber { url, _ in
            calls += 1
            let wav = try AVAudioFile(forReading: url)
            XCTAssertEqual(wav.length, 1877)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: AVAudioFrameCount(wav.length)))
            try wav.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            XCTAssertEqual(samples[0], 0.0042, accuracy: 0.0001)
            XCTAssertEqual(samples[1876], 0.0042, accuracy: 0.0001)
            return "Yes."
        }.run(session)
        XCTAssertEqual(text, "A synthetic sentence. Yes.")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.manifest.segments.map(\.text), ["A synthetic sentence.", "Yes."])
        let restored = try RecordingSession(directory: session.directory)
        XCTAssertEqual(restored.manifest.segments.map(\.sha256), hashes)
        XCTAssertEqual(try restored.manifest.segments.map { try Data(contentsOf: restored.directory.appendingPathComponent($0.filename)) }, original)
    }

    @MainActor func testFreshTinyTailIsNeverGroupedWithPredecessor() async throws {
        let session = try fixture()
        session.manifest.segments[0].text = nil
        try session.save()
        var calls = 0
        let text = try await SessionTranscriber { url, _ in
            calls += 1
            XCTAssertEqual(try AVAudioFile(forReading: url).length, calls == 1 ? 80000 : 1877)
            if calls == 2 {
                let disk = try RecordingSession(directory: session.directory)
                XCTAssertEqual(disk.manifest.segments[0].text, "Fresh sentence.")
                XCTAssertNil(disk.manifest.segments[1].text)
            }
            return calls == 1 ? "Fresh sentence." : "Yes."
        }.run(session)
        XCTAssertEqual(text, "Fresh sentence. Yes.")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(session.manifest.segments.map(\.text), ["Fresh sentence.", "Yes."])
        XCTAssertTrue(session.manifest.segments.allSatisfy { $0.textThroughIndex == nil })
    }

    @MainActor func testSuccessfulTailResponseNeedsNoAnchorAgreement() async throws {
        for response in ["", "A different sentence.", "A synthetic", "Now! Now!"] {
            let session = try fixture()
            var calls = 0
            let text = try await SessionTranscriber { _, _ in calls += 1; return response }.run(session)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(session.manifest.segments[1].text, response)
            XCTAssertEqual(text, response.isEmpty ? "A synthetic sentence." : "A synthetic sentence. " + response)
        }
    }

    @MainActor func testTailFailureDoesNotRetryOrReplayCachedPredecessor() async throws {
        let session = try fixture()
        var calls = 0
        do {
            _ = try await SessionTranscriber { url, _ in
                calls += 1
                XCTAssertEqual(try AVAudioFile(forReading: url).length, 1877)
                throw VellaError.message("Synthetic worker failure")
            }.run(session)
            XCTFail("Actual failure must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Synthetic worker failure"))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.manifest.segments.map(\.text), ["A synthetic sentence.", nil])
        XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.segments.map(\.text), ["A synthetic sentence.", nil])
    }
}
