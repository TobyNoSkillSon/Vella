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
    @MainActor func testContextRecoversRealShortWordWithoutReplayingAnchor() async throws {
        let session = try fixture()
        let hashes = session.manifest.segments.map(\.sha256)
        var calls = 0
        let transcriber = SessionTranscriber { url, _ in
            calls += 1
            let wav = try AVAudioFile(forReading: url)
            if calls <= 3 { throw VellaError.noSpeech }
            XCTAssertEqual(wav.length, 80000 + 1877 + 8000)
            return "A synthetic sentence. Yes."
        }
        transcriber.onObservation = { _, _, _ in XCTFail("Context retries must not calibrate tail speed") }
        let text = try await transcriber.run(session)
        XCTAssertEqual(text, "A synthetic sentence. Yes.")
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(session.manifest.segments[1].text, "Yes.")
        XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.segments.map(\.sha256), hashes)
        let data = try Data(contentsOf: session.directory.appendingPathComponent("context-retry-000001.json"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(provenance["tailRange"] as? [Int], [0, 1877])
        XCTAssertEqual(provenance["outcome"] as? String, "recognizedSuffix")
    }
    @MainActor func testContextRecognizesAnchorOnlyRatherThanDurationBasedDiscard() async throws {
        let session = try fixture()
        var calls = 0
        let transcriber = SessionTranscriber { _, _ in
            calls += 1
            if calls <= 3 { throw VellaError.noSpeech }
            return "A synthetic sentence."
        }
        let text = try await transcriber.run(session)
        XCTAssertEqual(text, "A synthetic sentence.")
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(session.manifest.segments[1].text, "")
    }
    @MainActor func testUncertainContextPreservesMissingSpeechWarning() async throws {
        for response in ["", "A different sentence.", "A synthetic"] {
            let session = try fixture()
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                if calls <= 3 || response.isEmpty { throw VellaError.noSpeech }
                return response
            }
            do { _ = try await transcriber.run(session); XCTFail("Must retain uncertainty") }
            catch VellaError.unrecognizedAudio {}
            XCTAssertEqual(calls, 4)
            XCTAssertNil(session.manifest.segments[1].text)
            let partial = try String(contentsOf: session.directory.appendingPathComponent("partial-transcript.txt"), encoding: .utf8)
            XCTAssertTrue(partial.contains("[Unrecognized audio — segment 2]"))
        }
    }
    @MainActor func testAlignmentPreservesRepeatedNewWords() {
        XCTAssertEqual(SessionTranscriber.contextSuffix(anchor: "Go now.", decoded: "Go now. Now!"), "Now!")
        XCTAssertNil(SessionTranscriber.contextSuffix(anchor: "Go now.", decoded: "Go."))
        XCTAssertNil(SessionTranscriber.contextSuffix(anchor: "We're ready.", decoded: "Were ready."))
        XCTAssertNil(SessionTranscriber.contextSuffix(anchor: "Please re-sign.", decoded: "Please resign."))
        XCTAssertEqual(SessionTranscriber.contextSuffix(anchor: "“We’re ready.”", decoded: "We're ready! Yes."), "Yes.")
    }
}
