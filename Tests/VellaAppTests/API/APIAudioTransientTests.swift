import Foundation
import XCTest
@testable import Vella
import VellaCore

final class APIAudioTransientTests: XCTestCase {
    func testAPIFileInputKeepsNoRecoveryJournal() throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent("fixture.wav")
        try writeTestWAV(file, bursts: [26, 6, 0.1])
        let (session, duration) = try APIAudio.segment(file, root: root, config: Configuration(model: ""))
        XCTAssertGreaterThan(duration, 30)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: session.directory.path).isEmpty)
        XCTAssertFalse(RecordingSession.discover(root: root).contains(session.directory))
        XCTAssertTrue(session.manifest.segments.contains { $0.overlapFrames > 0 })
        for segment in session.manifest.segments { XCTAssertEqual(try session.samples(for: segment).count, segment.frames) }
        XCTAssertThrowsError(try RecordingSession(directory: session.directory))
    }

    /// Replay the decoded samples through the unchanged durable writer, then compare every cut, hash, sample,
    /// tail request, WAV byte and assembled timestamp/text. Includes a forced overlap, pause and short quiet tail.
    @MainActor func testTransientAudioIsIdenticalToDurableJournal() async throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent("fixture.wav")
        try writeTestWAV(file, bursts: [26, 6, 0.1])
        let (transient, duration) = try APIAudio.segment(file, root: root, config: Configuration(model: ""))
        let durable = try RecordingSession(root: root, config: transient.manifest.config)
        let writer = try SegmentedPCMWriter(session: durable)
        for segment in transient.manifest.segments {
            let samples = Array(try transient.samples(for: segment).dropFirst(segment.overlapFrames))
            try samples.withUnsafeBufferPointer { try writer.append($0) }
        }
        try writer.finish(userStopped: true)
        XCTAssertEqual(Double(writer.totalFrames) / 16_000, duration)
        XCTAssertEqual(transient.manifest.segments, durable.manifest.segments)
        let merge = try transient.tailMerge(policy: .init())
        XCTAssertNotNil(merge)
        XCTAssertEqual(merge, try durable.tailMerge(policy: .init()))
        for (left, right) in zip(transient.manifest.segments, durable.manifest.segments) {
            XCTAssertEqual(try transient.samples(for: left), try durable.samples(for: right))
            XCTAssertEqual(try Data(contentsOf: transient.wav(for: left)), try Data(contentsOf: durable.wav(for: right)))
        }
        var requests: [[Data]] = []
        var texts: [String] = []
        for session in [durable, transient] {
            var audio: [Data] = []
            let runner = SessionTranscriber { url, _ in
                audio.append(try Data(contentsOf: url))
                return audio.count == 1 ? "one overlap word" : "overlap word two"
            }
            texts.append(try await runner.run(session))
            requests.append(audio)
        }
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(texts[0], texts[1])
        XCTAssertEqual(durable.manifest.segments, transient.manifest.segments)
        XCTAssertEqual(APIAudio.segments(durable).segments, APIAudio.segments(transient).segments)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: transient.directory.path), ["request.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.transcriptURL.path))
        XCTAssertEqual(try RecordingSession(directory: durable.directory).manifest.segments, durable.manifest.segments)
    }

    func testTransientExactCutVerifiesRedundantOverlapWithoutFiles() throws {
        let session = try RecordingSession(root: temporaryRoot(), config: Configuration(model: ""), transient: true)
        let writer = try SegmentedPCMWriter(session: session)
        let samples = [Float](repeating: 0.1, count: 25 * 16_000)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        XCTAssertEqual(session.manifest.segments.count, 2)
        XCTAssertEqual(session.manifest.segments[1].frames, session.manifest.segments[1].overlapFrames)
        XCTAssertNoThrow(try session.verifyRedundantTail(at: 1))
    }

    func testTransientDecodeCancellationLeavesNoSession() async throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent("fixture.wav")
        try writeTestWAV(file)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try APIAudio.segment(file, root: root, config: Configuration(model: ""))
        }
        do { _ = try await task.value; XCTFail("Cancelled decode succeeded") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fixture.wav"])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-api-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
