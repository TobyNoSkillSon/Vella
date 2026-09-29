import XCTest
import AVFoundation
@testable import Vella
import VellaCore

/// Cut points per architecture and the final-unit merge. The expected frame counts are the same synthetic cases as
/// lab/bench/appseg.py's self-check (the benchmark replica must stay in lockstep with these).
final class SegmentationPolicyTests: XCTestCase {
    enum Piece { case speech(Double), pause(Double) }
    /// Speech is a ramp whose every 20 ms block is above the 0.003 silence level and whose PCM16 value encodes the
    /// sample position (100 + i % 30011, a 1.9 s period), so a request can be located in the input sample by sample.
    func signal(_ pieces: [Piece]) -> [Float] {
        var out: [Float] = []
        for piece in pieces {
            switch piece {
            case .speech(let s): for _ in 0..<Int(s * 16_000) { out.append(Float(100 + out.count % 30_011) / 32767) }
            case .pause(let s): out += [Float](repeating: 0, count: Int(s * 16_000))
            }
        }
        return out
    }
    func folder(_ config: [String: Any]?, derivedFrom source: URL? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vella-seg-model-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        if let config { try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json")) }
        if let source { try JSONSerialization.data(withJSONObject: ["schema": 1, "source": source.path]).write(to: url.appendingPathComponent("vella-derived.json")) }
        return url
    }
    func record(_ samples: [Float], model: String = "/qa/model") throws -> RecordingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-seg-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: Configuration(executable: "/qa/unused", model: model))
        let writer = try SegmentedPCMWriter(session: session)
        // Capture-sized pieces, like the microphone path.
        for start in stride(from: 0, to: samples.count, by: 4_096) {
            try samples[start..<min(start + 4_096, samples.count)].withUnsafeBufferPointer { try writer.append($0) }
        }
        try writer.finish(userStopped: true)
        return session
    }
    /// One request: its PCM16 samples (the app writes a canonical 44-byte header; AVAudioFile checks it is readable).
    func pcm(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, AVAudioFramePosition((data.count - 44) / 2))
        return data.dropFirst(44).withUnsafeBytes { bytes in (0..<(bytes.count / 2)).map { Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
    }
    func expected(_ samples: ArraySlice<Float>) -> [Int16] { samples.map { Int16(max(-32767, min(32767, $0 * 32767))) } }
    /// Runs the transcriber; returns (request lengths, request start positions in the input, text).
    @MainActor func transcribe(_ session: RecordingSession, input: [Float], replies: [String]? = nil) async throws -> ([Int], [Int], String) {
        var lengths: [Int] = [], starts: [Int] = []
        let reference = expected(input[...])
        let text = try await SessionTranscriber { url, _ in
            let samples = try self.pcm(url)
            // Locate the request in the input by its exact content, searching from 1 s before the previous request's
            // end (a forced cut or a re-split starts 0.5 s early; the ramp's period is longer than the search window).
            func matches(_ i: Int) -> Bool {
                guard i + samples.count <= reference.count else { return false }
                return reference.withUnsafeBufferPointer { r in samples.withUnsafeBufferPointer { q in
                    memcmp(r.baseAddress! + i, q.baseAddress!, q.count * 2) == 0 } }
            }
            let from = starts.isEmpty ? 0 : max(0, starts.last! + lengths.last! - 16_000)
            starts.append((from..<reference.count).first(where: matches) ?? -1); lengths.append(samples.count)
            return replies?[lengths.count - 1] ?? "piece \(lengths.count)"
        }.run(session)
        return (lengths, starts, text)
    }

    func testPolicyFollowsTheModelsArchitecture() throws {
        XCTAssertEqual(SegmentedPCMWriter.Policy().preferredSeconds, 5)
        XCTAssertEqual(SegmentedPCMWriter.Policy().minimumSeconds, 2)
        XCTAssertEqual(SegmentedPCMWriter.Policy.whisper.preferredSeconds, 20)
        XCTAssertEqual(SegmentedPCMWriter.Policy.whisper.maximumSeconds, 25)
        let whisper = try folder(["model_type": "whisper"])
        XCTAssertEqual(SegmentedPCMWriter.Policy.forModel(whisper.path), .whisper)
        XCTAssertEqual(SegmentedPCMWriter.Policy.forModel(try folder(nil, derivedFrom: whisper).path), .whisper, "A derived precision uses its source's architecture")
        XCTAssertEqual(SegmentedPCMWriter.Policy.forModel(try folder(["model_type": "qwen3_asr"]).path), .init())
        XCTAssertEqual(SegmentedPCMWriter.Policy.forModel(try folder(["target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"]).path), .init())
        XCTAssertEqual(SegmentedPCMWriter.Policy.forModel("/qa/missing"), .init())
        XCTAssertEqual(SegmentedPCMWriter.Policy.forModel(""), .init())
    }

    func testWhisperCutsAtAPauseOnlyAfterTwentySeconds() throws {
        let whisper = try folder(["model_type": "whisper"]).path
        let gap = signal([.speech(6), .pause(1), .speech(3)])
        XCTAssertEqual(try record(gap, model: whisper).manifest.segments.map(\.frames), [gap.count])
        XCTAssertEqual(try record(gap).manifest.segments.map(\.frames), [102_400, 57_600])
        let pauses = signal([.speech(8), .pause(1), .speech(8), .pause(1), .speech(8)])
        XCTAssertEqual(try record(pauses).manifest.segments.map(\.frames), [134_400, 144_000, 137_600])
        XCTAssertEqual(try record(pauses, model: whisper).manifest.segments.map(\.frames), [400_000, 24_000])
        // A pause that starts before 20 s still cuts once the segment reaches 20 s; later pauses wait another 20 s.
        let long = signal([.speech(19), .pause(1), .speech(3), .pause(1), .speech(3)])
        XCTAssertEqual(try record(long, model: whisper).manifest.segments.map(\.frames), [320_000, 112_000])
    }

    @MainActor func testWhisperRecognizesAClipWithPausesAndAShortEndingInOneRequest() async throws {
        let whisper = try folder(["model_type": "whisper"]).path
        let input = signal([.speech(8), .pause(1), .speech(8), .pause(1), .speech(8)])
        let session = try record(input, model: whisper)
        let (lengths, starts, text) = try await transcribe(session, input: input, replies: ["Whole clip."])
        XCTAssertEqual(lengths, [416_000]); XCTAssertEqual(starts, [0])
        XCTAssertEqual(text, "Whole clip.")
        XCTAssertEqual(session.manifest.segments.map(\.text), ["Whole clip.", ""])
    }

    @MainActor func testShortTailIsMergedAndTheJournalIsUnchanged() async throws {
        for (pieces, journal) in [([Piece.speech(6), .pause(0.5), .speech(1)], [102_400, 17_600]),   // 1.1 s tail
                                  ([.speech(13.5), .pause(0.8), .speech(0.1)], [222_400, 8_000])] { // Parakeet F2 shape: 0.5 s tail
            let input = signal(pieces)
            let session = try record(input)
            XCTAssertEqual(session.manifest.segments.map(\.frames), journal)
            let files = try session.manifest.segments.map { try Data(contentsOf: session.directory.appendingPathComponent($0.filename)) }
            let (lengths, starts, text) = try await transcribe(session, input: input)
            XCTAssertEqual(lengths, [input.count]); XCTAssertEqual(starts, [0])
            XCTAssertEqual(text, "piece 1")
            XCTAssertEqual(session.manifest.segments.map(\.text), ["piece 1", ""])
            let recovered = try RecordingSession(directory: session.directory)
            XCTAssertEqual(recovered.manifest.segments.map(\.frames), journal)
            XCTAssertEqual(try recovered.manifest.segments.map { try Data(contentsOf: recovered.directory.appendingPathComponent($0.filename)) }, files)
            XCTAssertEqual(try recovered.complete(), "piece 1")
        }
    }

    @MainActor func testSilentTailIsMergedButAVoicedTwoSecondTailStaysAlone() async throws {
        let silent = signal([.speech(6), .pause(3.4)])
        let a = try record(silent)
        XCTAssertEqual(a.manifest.segments.map(\.frames), [102_400, 48_000], "3 s final segment without a voiced block")
        let (la, _, _) = try await transcribe(a, input: silent)
        XCTAssertEqual(la, [silent.count])
        let voiced = signal([.speech(6), .pause(1), .speech(3)])
        let b = try record(voiced)
        let (lb, sb, tb) = try await transcribe(b, input: voiced)
        XCTAssertEqual(lb, [102_400, 57_600]); XCTAssertEqual(sb, [0, 102_400])
        XCTAssertEqual(tb, "piece 1 piece 2")
        // A short voiced ending after a silent segment absorbs only that one (the unit is then long enough and voiced).
        let cough = signal([.speech(6), .pause(6), .speech(1)])
        let c = try record(cough)
        XCTAssertEqual(c.manifest.segments.map(\.frames), [102_400, 80_000, 25_600])
        let (lc, sc, _) = try await transcribe(c, input: cough)
        XCTAssertEqual(lc, [102_400, 105_600]); XCTAssertEqual(sc, [0, 102_400])
        XCTAssertEqual(c.manifest.segments.map(\.text), ["piece 1", "piece 2", ""])
    }

    @MainActor func testMaximumBoundary() async throws {
        // 26 s without a pause: forced cut at 25 s leaves 0.5 s overlap + 1 s new -> one 26 s request (<= 25 + 2 s).
        let a = signal([.speech(26)])
        let ra = try record(a)
        XCTAssertEqual(ra.manifest.segments.map(\.frames), [400_000, 24_000])
        XCTAssertEqual(ra.manifest.segments[1].overlapFrames, 8_000)
        let (la, sa, _) = try await transcribe(ra, input: a)
        XCTAssertEqual(la, [416_000]); XCTAssertEqual(sa, [0])
        // 27.5 s: 2.5 s of new voiced audio after the cut -> the usual forced cut with its overlap.
        let b = signal([.speech(27.5)])
        let (lb, sb, _) = try await transcribe(try record(b), input: b)
        XCTAssertEqual(lb, [400_000, 48_000]); XCTAssertEqual(sb, [0, 392_000])
        // 22 s speech then 8 s silence: the silent 5 s + 2.6 s final unit would make 30 s > 27 s: re-split evenly with
        // the 0.5 s overlap, and the halves' texts are joined like a forced cut.
        let c = signal([.speech(22), .pause(8)])
        let rc = try record(c)
        XCTAssertEqual(rc.manifest.segments.map(\.frames), [358_400, 80_000, 41_600])
        let (lc, sc, tc) = try await transcribe(rc, input: c, replies: ["alpha beta gamma", "gamma delta"])
        XCTAssertEqual(lc, [244_000, 244_000]); XCTAssertEqual(sc, [0, 236_000])
        XCTAssertEqual(tc, "alpha beta gamma delta")
        XCTAssertEqual(rc.manifest.segments.map(\.text), ["alpha beta gamma delta", "", ""])
        // 22 s speech then 3 s silence: one 25 s request.
        let d = signal([.speech(22), .pause(3)])
        let (ld, _, _) = try await transcribe(try record(d), input: d)
        XCTAssertEqual(ld, [400_000])
    }

    @MainActor func testLongRecordingMergesOnlyItsFinalUnitAndLosesNoAudio() async throws {
        var pieces: [Piece] = []
        for _ in 0..<20 { pieces += [.speech(9), .pause(0.7)] }
        pieces += [.speech(40.3)]              // a forced cut at 25 s, then 15.6 s more speech after the 0.5 s overlap
        pieces += [.pause(0.5), .speech(0.6)]  // a pause cut, then a 0.7 s final segment
        let input = signal(pieces)
        let session = try record(input)
        let journal = session.manifest.segments
        XCTAssertGreaterThan(journal.count, 20)
        let (lengths, starts, text) = try await transcribe(session, input: input)
        XCTAssertEqual(lengths.count, journal.count - 1)
        XCTAssertEqual(Array(lengths.dropLast()), journal.dropLast(2).map(\.frames))
        XCTAssertEqual(lengths.last, journal[journal.count - 2].frames + journal.last!.frames)
        // Every input sample is in some request, in order; forced-cut requests start 0.5 s early.
        XCTAssertFalse(starts.contains(-1))
        XCTAssertEqual(starts.last! + lengths.last!, input.count)
        for k in 1..<starts.count { XCTAssertLessThanOrEqual(starts[k], starts[k - 1] + lengths[k - 1]) }
        XCTAssertEqual(text, (1...lengths.count).map { "piece \($0)" }.joined(separator: " "))
        XCTAssertEqual(session.manifest.segments.last?.text, "")
    }

    @MainActor func testMergedUnitFailureKeepsItPendingAndRetryRecognizesItOnce() async throws {
        let input = signal([.speech(6), .pause(0.5), .speech(1)])
        let session = try record(input)
        do {
            _ = try await SessionTranscriber { _, _ in throw URLError(.timedOut) }.run(session)
            XCTFail("Actual failure must propagate")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(session.manifest.segments.map(\.text), [nil, nil])
        let recovered = try RecordingSession(directory: session.directory)
        XCTAssertEqual(recovered.manifest.segments.map(\.text), [nil, nil])
        XCTAssertNil(try recovered.savePartialTranscript(), "Nothing recognized yet: no partial transcript")
        var calls = 0
        let text = try await SessionTranscriber { _, _ in calls += 1; return "Once only." }.run(recovered)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(text, "Once only.")
        XCTAssertEqual(try String(contentsOf: recovered.transcriptURL, encoding: .utf8), "Once only.")
        // Running again changes nothing and sends nothing.
        let again = try await SessionTranscriber { _, _ in XCTFail("Nothing is pending"); return "" }.run(recovered)
        XCTAssertEqual(again, "Once only.")
    }

    @MainActor func testASavedPredecessorIsNeverReplaced() async throws {
        let input = signal([.speech(6), .pause(0.5), .speech(1)])
        let session = try record(input)
        session.manifest.segments[0].text = "Saved earlier."
        try session.save()
        let (lengths, _, text) = try await transcribe(session, input: input, replies: ["tail"])
        XCTAssertEqual(lengths, [17_600])
        XCTAssertEqual(text, "Saved earlier. tail")
    }

    func testSegmentsBetweenCutsAreNeverShorterThanThePreferredLength() throws {
        // Mid-stream cuts need >= preferred frames (5 s, or 20 s for Whisper), so no < 2 s remainder is created there.
        var pieces: [Piece] = []
        for k in 0..<30 { pieces += [.speech(Double(k % 7) * 0.9 + 0.3), .pause(k % 3 == 0 ? 0.5 : 0.1)] }
        pieces.append(.speech(31))
        let input = signal(pieces)
        for model in ["/qa/model", try folder(["model_type": "whisper"]).path] {
            let session = try record(input, model: model)
            let preferred = Int(SegmentedPCMWriter.Policy.forModel(model).preferredSeconds * 16_000)
            for segment in session.manifest.segments.dropLast() { XCTAssertGreaterThanOrEqual(segment.frames, preferred) }
        }
    }
}
