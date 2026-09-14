import XCTest
import AVFoundation
@testable import Vella
import VellaCore

final class DictationStabilityTests: XCTestCase {
    private func fixture(_ audio: [[Float]], texts: [String?]? = nil) throws -> RecordingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stability-synthetic-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: .init(executable: "/unused", model: "/synthetic"))
        for (i, samples) in audio.enumerated() {
            let data = samples.withUnsafeBytes { Data($0) }
            let segment = RecordingSession.Segment(index: i, frames: samples.count,
                peakRMS: RecordingSession.peakRMS(data, range: 0..<samples.count), finalized: true,
                text: texts?[i], sha256: RecordingSession.digest(data))
            try session.durableWrite(data, to: session.directory.appendingPathComponent(segment.filename))
            session.manifest.segments.append(segment)
        }
        session.manifest.state = "captured"
        try session.save()
        return session
    }

    @MainActor func testEmptySuccessAtEveryEnergyMakesExactlyOneUnpaddedRequest() async throws {
        for level in [Float](arrayLiteral: 0, 0.000001, 0.0004, 0.004, 0.1, 0.9) {
            for response in ["", " \n\t "] {
                let session = try fixture([[Float](repeating: level, count: 16000)])
                var calls = 0
                let result = try await SessionTranscriber { url, _ in
                    calls += 1
                    XCTAssertEqual(try AVAudioFile(forReading: url).length, 16000)
                    return response
                }.run(session)
                XCTAssertEqual(calls, 1, "Energy \(level) must not bypass inference or trigger retries")
                XCTAssertEqual(result, "")
                let restored = try RecordingSession(directory: session.directory)
                XCTAssertEqual(restored.manifest.segments[0].text, "")
                XCTAssertEqual(restored.manifest.state, "transcribed")
                XCTAssertEqual(try String(contentsOf: session.transcriptURL, encoding: .utf8), "")
            }
        }
    }

    @MainActor func testConsecutiveEmptyGapCheckpointsBeforeContinuingAndNeverReplays() async throws {
        let session = try fixture(Array(repeating: [Float](repeating: 0.1, count: 32000), count: 4))
        let responses = ["Left.", "", " \n\t", "Right."]
        let normalized = ["Left.", "", "", "Right."]
        var calls = 0
        let transcriber = SessionTranscriber { _, _ in
            let disk = try RecordingSession(directory: session.directory)
            for i in 0..<calls { XCTAssertEqual(disk.manifest.segments[i].text, normalized[i]) }
            XCTAssertNil(disk.manifest.segments[calls].text)
            defer { calls += 1 }
            return responses[calls]
        }
        let result = try await transcriber.run(session)
        XCTAssertEqual(result, "Left. Right.")
        XCTAssertEqual(calls, 4)
        let restored = try RecordingSession(directory: session.directory)
        XCTAssertEqual(restored.manifest.segments.map(\.text), normalized.map { Optional($0) })
        let repeated = try await SessionTranscriber { _, _ in XCTFail("Cached empty text is resolved"); return "" }.run(restored)
        XCTAssertEqual(repeated, result)
    }

    @MainActor func testQuietRecognizedWordsAreAcceptedAndWhitespaceNormalized() async throws {
        for level in [Float](arrayLiteral: 0, 0.000001, 0.0004) {
            let session = try fixture([[Float](repeating: level, count: 1045)])
            var calls = 0
            let result = try await SessionTranscriber { _, _ in calls += 1; return " \tQuiet\n  words. \r\n" }.run(session)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result, "Quiet words.")
            XCTAssertEqual(session.manifest.segments[0].text, "Quiet words.")
        }
    }

    @MainActor func testRuntimeFailureAndCancellationStopWithoutRetryOrLosingEarlierCheckpoint() async throws {
        for cancelled in [false, true] {
            let session = try fixture(Array(repeating: [Float](repeating: 0.1, count: 32000), count: 3))
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                if calls == 1 { return "Saved." }
                if cancelled { throw CancellationError() }
                throw VellaError.message("Synthetic transport failure")
            }
            do { _ = try await transcriber.run(session); XCTFail("Must throw") }
            catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains("Synthetic transport failure")) }
            }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(session.manifest.segments.map(\.text), ["Saved.", nil, nil])
            XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.segments.map(\.text), ["Saved.", nil, nil])
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.transcriptURL.path))
        }
    }

    @MainActor func testPCMIntegrityFailurePreventsAffectedRequestAndCheckpoint() async throws {
        for truncate in [false, true] {
            let session = try fixture([[Float](repeating: 0.1, count: 32000)])
            let segment = session.manifest.segments[0]
            try Data(repeating: 0, count: truncate ? 4 : segment.frames * 4)
                .write(to: session.directory.appendingPathComponent(segment.filename))
            var calls = 0
            do {
                _ = try await SessionTranscriber { _, _ in calls += 1; return "Invented" }.run(session)
                XCTFail("Invalid PCM must fail")
            } catch {}
            XCTAssertEqual(calls, 0)
            XCTAssertNil(session.manifest.segments[0].text)
            let data = try Data(contentsOf: session.directory.appendingPathComponent("session.json"))
            let disk = try JSONDecoder().decode(RecordingSession.Manifest.self, from: data)
            XCTAssertNil(disk.segments[0].text)
        }
    }

    @MainActor func testCheckpointFailureRollsBackAffectedSegmentAndStops() async throws {
        for response in ["Recognized.", ""] {
            let session = try fixture(Array(repeating: [Float](repeating: 0.1, count: 32000), count: 3))
            var calls = 0
            var checkpoint: Data?
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                if calls == 1 { return "Saved." }
                let manifest = session.directory.appendingPathComponent("session.json")
                checkpoint = try Data(contentsOf: manifest)
                // Fail the post-response save, not run's initial save.
                try FileManager.default.removeItem(at: manifest)
                try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
                return response
            }
            do { _ = try await transcriber.run(session); XCTFail("Checkpoint must fail") } catch {}
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(session.manifest.segments.map(\.text), ["Saved.", nil, nil])
            let disk = try JSONDecoder().decode(RecordingSession.Manifest.self, from: XCTUnwrap(checkpoint))
            XCTAssertEqual(disk.segments, session.manifest.segments)
        }
    }

    @MainActor func testCancellationAfterResponseDoesNotCheckpointEvenEmptyText() async throws {
        for response in ["Do not checkpoint.", ""] {
            let session = try fixture(Array(repeating: [Float](repeating: 0.1, count: 32000), count: 2))
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return response
            }
            let task = Task { try await transcriber.run(session) }
            do { _ = try await task.value; XCTFail("Cancellation must win") } catch is CancellationError {}
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(session.manifest.segments.allSatisfy { $0.text == nil })
            XCTAssertTrue(try RecordingSession(directory: session.directory).manifest.segments.allSatisfy { $0.text == nil })
        }
    }

    @MainActor func testHistoricalGroupedCheckpointsArePreservedWithoutContextReplay() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 32000),
            [Float](repeating: 0.004, count: 32000), [Float](repeating: 0.1, count: 32000),
            [Float](repeating: 0.04, count: 1600)], texts: ["Left.", nil, "Right. Yes.", ""])
        session.manifest.segments[2].textThroughIndex = 3
        session.manifest.segments[3].quietSlices = 1
        try session.save()
        let restored = try RecordingSession(directory: session.directory)
        let historical = Array(restored.manifest.segments[2...3])
        var calls = 0
        let result = try await SessionTranscriber { url, _ in
            calls += 1
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000)
            return ""
        }.run(restored)
        XCTAssertEqual(result, "Left. Right. Yes.")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(Array(restored.manifest.segments[2...3]), historical)
        let disk = try RecordingSession(directory: session.directory)
        XCTAssertEqual(Array(disk.manifest.segments[2...3]), historical)
        let repeated = try await SessionTranscriber { _, _ in XCTFail("Historical checkpoints must not replay"); return "" }.run(disk)
        XCTAssertEqual(repeated, result)
    }
}
