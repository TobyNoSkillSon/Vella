import XCTest
import AVFoundation
@testable import Vella
import VellaCore

final class DictationStabilityTests: XCTestCase {
    private func pcm(_ levels: [Float]) -> [Float] {
        levels.flatMap { [Float](repeating: $0, count: 320) }
    }
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
    @MainActor func testTransientPolicyProtectsShortAndSustainedActivity() {
        func quiet(_ levels: [Float]) -> Bool {
            let samples = pcm(levels)
            return samples.withUnsafeBytes { SessionTranscriber.isModelConfirmedQuiet(Data($0), range: 0..<samples.count) }
        }
        var gap = [Float](repeating: 0.0004, count: 250)
        gap[5] = 0.001688
        XCTAssertTrue(quiet(gap))
        gap[6] = 0.002
        XCTAssertTrue(quiet(gap))
        gap[7] = 0.002
        XCTAssertFalse(quiet(gap), "60ms possible word must remain unresolved")
        XCTAssertFalse(quiet([0.0004, 0.001688, 0.0004]), "Short possible word is not a long pause")
        XCTAssertFalse(quiet([Float](repeating: 0.0016, count: 250)))
        gap = [Float](repeating: 0.0004, count: 250); gap[5] = 0.006
        XCTAssertFalse(quiet(gap), "Louder transient is outside the bounded policy")
        gap[5] = .nan
        XCTAssertFalse(quiet(gap))
        gap = [Float](repeating: 0.0004, count: 250)
        for i in stride(from: 0, to: 30, by: 5) { gap[i] = 0.002 }
        XCTAssertFalse(quiet(gap), "Repeated activity is not an isolated click")
        gap = [Float](repeating: 0.000576, count: 250)
        for i in 68...74 { gap[i] = 0.0017 }
        XCTAssertFalse(quiet(gap), "A 140ms run needs context, not a looser gate")
    }
    @MainActor func testQuietRecognitionAlwaysPrecedesClassificationAndEmptySuccess() async throws {
        var levels = [Float](repeating: 0.0004, count: 250); levels[5] = 0.001688
        for recognized in [false, true] {
            let session = try fixture([pcm(levels)])
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                if recognized && calls == 3 { return "Quiet word." }
                throw VellaError.noSpeech
            }
            let result = try await transcriber.run(session)
            XCTAssertEqual(calls, 3)
            XCTAssertEqual(result, recognized ? "Quiet word." : "")
            XCTAssertEqual(session.manifest.segments[0].quietSlices, recognized ? 0 : 1)
            XCTAssertEqual(try String(contentsOf: session.directory.appendingPathComponent("transcript.txt"), encoding: .utf8), result)
        }
    }
    @MainActor func testDigitalSilenceReturnsEmptyWithoutInference() async throws {
        let session = try fixture([[Float](repeating: 0, count: 16000)])
        let result = try await SessionTranscriber { _, _ in XCTFail("Digital silence"); return "" }.run(session)
        XCTAssertEqual(result, "")
    }
    @MainActor func testFreshTailJointDecodeCheckpointsBothOnceAndPreservesPCM() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)])
        let before = try session.manifest.segments.map { try Data(contentsOf: session.directory.appendingPathComponent($0.filename)) }
        let hashes = session.manifest.segments.map(\.sha256)
        var calls = 0
        let transcriber = SessionTranscriber { url, _ in
            calls += 1
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 80000 + 1045 + 8000)
            XCTAssertTrue(session.manifest.segments.allSatisfy { $0.text == nil })
            return "Fresh complete sentence. Yes."
        }
        transcriber.onObservation = { _, _, _ in XCTFail("Joint decode is not a tail timing") }
        let result = try await transcriber.run(session)
        XCTAssertEqual(result, "Fresh complete sentence. Yes.")
        XCTAssertEqual(calls, 1)
        let restored = try RecordingSession(directory: session.directory)
        XCTAssertEqual(restored.manifest.segments.map(\.text), [result, ""])
        XCTAssertEqual(restored.manifest.segments.map(\.sha256), hashes)
        XCTAssertEqual(try restored.manifest.segments.map { try Data(contentsOf: restored.directory.appendingPathComponent($0.filename)) }, before)
        let repeated = try await transcriber.run(session)
        XCTAssertEqual(repeated, result); XCTAssertEqual(calls, 1)
    }
    @MainActor func testGroupNoSpeechFallsBackToBothStandaloneRequests() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)])
        var calls = 0
        let transcriber = SessionTranscriber { _, _ in
            calls += 1
            if calls <= 3 { throw VellaError.noSpeech }
            return calls == 4 ? "Anchor." : "Yes."
        }
        let result = try await transcriber.run(session)
        XCTAssertEqual(result, "Anchor. Yes."); XCTAssertEqual(calls, 5)
    }
    @MainActor func testJointTransportFailureAndCancellationLeaveBothPending() async throws {
        for cancelled in [false, true] {
            let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)])
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                if cancelled { throw CancellationError() }
                throw VellaError.message("Synthetic transport failure")
            }
            do { _ = try await transcriber.run(session); XCTFail("Must throw") } catch {}
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(session.manifest.segments.allSatisfy { $0.text == nil })
            XCTAssertTrue(try RecordingSession(directory: session.directory).manifest.segments.allSatisfy { $0.text == nil })
        }
    }
    @MainActor func testJointPCMIntegrityFailureDoesNotRequestOrCheckpoint() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)])
        try Data(repeating: 0, count: 1045 * 4).write(to: session.directory.appendingPathComponent(session.manifest.segments[1].filename))
        let transcriber = SessionTranscriber { _, _ in XCTFail("Invalid PCM"); return "Invented" }
        do { _ = try await transcriber.run(session); XCTFail("Must throw") } catch {}
        XCTAssertTrue(session.manifest.segments.allSatisfy { $0.text == nil })
    }
    @MainActor func testTailAlignmentRetriesStrictlyAndPreservesAnchor() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)], texts: ["Anchor word.", nil])
        var calls = 0
        let transcriber = SessionTranscriber { url, _ in
            calls += 1
            if calls <= 3 { throw VellaError.noSpeech }
            if calls <= 5 { return "Changed word." }
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 80000 + 1045 + 16000)
            return "Anchor word. Yes."
        }
        let result = try await transcriber.run(session)
        XCTAssertEqual(result, "Anchor word. Yes."); XCTAssertEqual(calls, 6)
        XCTAssertEqual(session.manifest.segments[0].text, "Anchor word.")
    }
    @MainActor func testInteriorRecoveryRequiresBothExactAnchorsAndCanKeepNewWord() async throws {
        for middle in ["", "Yes."] {
            let session = try fixture(Array(repeating: [Float](repeating: 0.004, count: 32000), count: 3), texts: ["Left anchor.", nil, "Right anchor."])
            var calls = 0
            let transcriber = SessionTranscriber { url, _ in
                calls += 1
                if calls <= 3 { throw VellaError.noSpeech }
                XCTAssertEqual(try AVAudioFile(forReading: url).length, 96000 + 8000)
                return "Left anchor. \(middle) Right anchor."
            }
            transcriber.onObservation = { _, _, _ in XCTFail("Interior context is not missing-slice timing") }
            let result = try await transcriber.run(session)
            XCTAssertEqual(result, middle.isEmpty ? "Left anchor. Right anchor." : "Left anchor. Yes. Right anchor.")
            XCTAssertEqual(calls, 4)
            XCTAssertEqual(session.manifest.segments.map(\.text), ["Left anchor.", middle, "Right anchor."])
        }
    }
    @MainActor func testInteriorMismatchRemainsPendingAndDoesNotBecomeEmptySuccess() async throws {
        for decoded in ["Changed anchor. Right anchor.", "Left anchor. Changed anchor.", "Left anchor.", "Left anchor. Right anchor. Extra."] {
            let session = try fixture(Array(repeating: [Float](repeating: 0.004, count: 32000), count: 3), texts: ["Left anchor.", nil, "Right anchor."])
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in
                calls += 1
                if calls <= 3 { throw VellaError.noSpeech }
                return decoded
            }
            do { _ = try await transcriber.run(session); XCTFail("Mismatch must remain pending") }
            catch VellaError.unrecognizedAudio {}
            XCTAssertEqual(calls, 6)
            XCTAssertNil(session.manifest.segments[1].text)
            XCTAssertEqual(session.manifest.segments[0].text, "Left anchor.")
            XCTAssertEqual(session.manifest.segments[2].text, "Right anchor.")
        }
        let pending = try fixture([[Float](repeating: 0.004, count: 1600)])
        do { _ = try await SessionTranscriber { _, _ in throw VellaError.noSpeech }.run(pending); XCTFail("Unresolved is not silence") }
        catch VellaError.unrecognizedAudio {}
    }
    @MainActor func testGroupingExcludesOverlapsCachedTailAndOversizeRequest() async throws {
        for mode in 0..<3 {
            let frames = mode == 2 ? 29 * 16000 : 80000
            let session = try fixture([[Float](repeating: 0.1, count: frames), [Float](repeating: 0.004, count: 1045)])
            if mode == 0 { session.manifest.segments[1].overlapFrames = 320 }
            if mode == 1 { session.manifest.segments[1].text = "Cached tail." }
            try session.save()
            var calls = 0
            let transcriber = SessionTranscriber { url, _ in
                calls += 1
                if calls == 1 { XCTAssertEqual(try AVAudioFile(forReading: url).length, Int64(frames + 8000)) }
                return calls == 1 ? "Anchor." : "Tail."
            }
            _ = try await transcriber.run(session)
            XCTAssertEqual(calls, mode == 1 ? 1 : 2)
            if mode == 1 { XCTAssertEqual(session.manifest.segments[1].text, "Cached tail.") }
        }
    }
    @MainActor func testJointCheckpointFailureRestoresBothInMemory() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)])
        let original = session.manifest.segments
        let transcriber = SessionTranscriber { _, _ in
            // Fail only the checkpoint after inference, not run's initial save.
            let manifest = session.directory.appendingPathComponent("session.json")
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            return "Complete joint text."
        }
        do { _ = try await transcriber.run(session); XCTFail("Checkpoint must fail") } catch {}
        XCTAssertEqual(session.manifest.segments, original)
    }
    @MainActor func testCancellationAfterJointResponseDoesNotCheckpoint() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 80000), [Float](repeating: 0.004, count: 1045)])
        let transcriber = SessionTranscriber { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "Do not checkpoint."
        }
        let task = Task { try await transcriber.run(session) }
        do { _ = try await task.value; XCTFail("Cancellation must win") } catch is CancellationError {}
        XCTAssertTrue(session.manifest.segments.allSatisfy { $0.text == nil })
        XCTAssertTrue(try RecordingSession(directory: session.directory).manifest.segments.allSatisfy { $0.text == nil })
    }
    @MainActor func testInteriorContextRejectsOverlapAndThirtySecondOverflow() async throws {
        for oversized in [false, true] {
            let long = oversized ? 14 * 16000 : 32000
            let session = try fixture([[Float](repeating: 0.1, count: long), [Float](repeating: 0.004, count: 32000), [Float](repeating: 0.1, count: long)], texts: ["Left.", nil, "Right."])
            if !oversized { session.manifest.segments[2].overlapFrames = 320 }
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in calls += 1; throw VellaError.noSpeech }
            do { _ = try await transcriber.run(session); XCTFail("Ineligible context remains pending") }
            catch VellaError.unrecognizedAudio {}
            XCTAssertEqual(calls, 3)
        }
    }
    @MainActor func testInteriorIncludesSpokenGroupedTailCoverageAfterReload() async throws {
        let session = try fixture([[Float](repeating: 0.1, count: 32000),
            [Float](repeating: 0.004, count: 32000), [Float](repeating: 0.1, count: 32000),
            [Float](repeating: 0.04, count: 1600)], texts: ["Left anchor.", nil, nil, nil])
        let hashes = session.manifest.segments.map(\.sha256)
        var calls = 0
        let first = SessionTranscriber { url, _ in
            calls += 1
            if calls <= 3 { throw VellaError.noSpeech }
            if calls == 4 {
                XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000 + 1600 + 8000)
                return "Right anchor. Yes."
            }
            // Simulate interruption after the atomic group checkpoint.
            throw VellaError.message("Synthetic interruption before interior result")
        }
        do { _ = try await first.run(session); XCTFail("Expected interruption") } catch {}
        XCTAssertEqual(calls, 5)
        let restored = try RecordingSession(directory: session.directory)
        XCTAssertEqual(restored.manifest.segments[2].textThroughIndex, 3)
        XCTAssertNil(restored.manifest.segments[3].textThroughIndex)
        XCTAssertEqual(restored.manifest.segments[2].text, "Right anchor. Yes.")
        XCTAssertEqual(restored.manifest.segments[3].text, "")
        calls = 0
        let retry = SessionTranscriber { url, _ in
            calls += 1
            if calls <= 3 { throw VellaError.noSpeech }
            let wav = try AVAudioFile(forReading: url)
            XCTAssertEqual(wav.length, 3 * 32000 + 1600 + 8000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: AVAudioFrameCount(wav.length)))
            try wav.read(into: buffer)
            XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData)[0][4000 + 3 * 32000], 0.04, accuracy: 0.0001)
            return "Left anchor. Quiet word. Right anchor. Yes."
        }
        let result = try await retry.run(restored)
        XCTAssertEqual(result, "Left anchor. Quiet word. Right anchor. Yes.")
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(restored.manifest.segments.map(\.sha256), hashes)
        let evidence = try Data(contentsOf: restored.directory.appendingPathComponent("interior-context-retry-000001.json"))
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: evidence) as? [String: Any])
        XCTAssertEqual(entry["indices"] as? [Int], [0, 1, 2, 3])
        XCTAssertEqual(entry["sourceRanges"] as? [[Int]], [[0, 32000], [0, 32000], [0, 32000], [0, 1600]])
        XCTAssertEqual(entry["sourceSHA256"] as? [String], hashes.compactMap { $0 })
    }
    @MainActor func testInteriorRejectsMalformedGroupedCoverage() async throws {
        for mode in 0..<9 {
            let long = mode == 8 ? 216000 : 32000
            let session = try fixture([[Float](repeating: 0.1, count: long),
                [Float](repeating: 0.004, count: 32000), [Float](repeating: 0.1, count: long),
                [Float](repeating: 0.04, count: mode == 4 ? 16001 : 1600)],
                texts: ["Left.", nil, "Right. Yes.", ""])
            session.manifest.segments[2].textThroughIndex = 3
            switch mode {
            case 0: session.manifest.segments[2].textThroughIndex = 42
            case 1: session.manifest.segments[0].textThroughIndex = 1
            case 2: session.manifest.segments[3].overlapFrames = 320
            case 3: session.manifest.segments[3].text = "Separate words."
            case 4: break // More than one second is not a supported group.
            case 5: session.manifest.segments[3].textThroughIndex = 3
            case 6: session.manifest.segments[3].index = 4
            case 7: session.manifest.segments[3].finalized = false
            default: break // Full context exceeds 30 seconds with padding.
            }
            var calls = 0
            let transcriber = SessionTranscriber { _, _ in calls += 1; throw VellaError.noSpeech }
            do { _ = try await transcriber.run(session); XCTFail("Malformed coverage must remain pending") }
            catch VellaError.unrecognizedAudio {}
            XCTAssertEqual(calls, 3, "Mode \(mode) must not request context")
            XCTAssertNil(session.manifest.segments[1].text)
        }
    }
    @MainActor func testInteriorAlignmentDoesNotConsumeSharedOrRepeatedWords() {
        XCTAssertNil(SessionTranscriber.contextMiddle(prefix: "Same word.", suffix: "Same word.", decoded: "Same word."))
        XCTAssertEqual(SessionTranscriber.contextMiddle(prefix: "Go now.", suffix: "Stop now.", decoded: "Go now. Now. Stop now."), "Now.")
        XCTAssertNil(SessionTranscriber.contextMiddle(prefix: "We're ready.", suffix: "Please re-sign.", decoded: "We're ready. Please resign."))
    }
}
