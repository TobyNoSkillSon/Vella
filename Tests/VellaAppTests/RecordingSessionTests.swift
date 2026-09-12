import XCTest
import AppKit
import AVFoundation
import CryptoKit
@testable import Vella
import VellaCore

final class RecordingSessionTests: XCTestCase {
    func testIndexedRecoveryPreservesSparseMetadataFirstDuplicateAndOrphans() throws {
        let record = try RecordingSession(root: root(), config: config)
        let raw = [Float(0.1)].withUnsafeBytes { Data($0) }
        let hash = RecordingSession.digest(raw)
        // Reverse, sparse indices catch accidental positional lookup; all audio is synthetic.
        for index in stride(from: 1023, through: 1, by: -2) {
            let segment = RecordingSession.Segment(index: index, frames: 1, peakRMS: 0.1,
                finalized: true, text: "Fixture \(index)", sha256: hash)
            record.manifest.segments.append(segment)
            try raw.write(to: record.directory.appendingPathComponent(segment.filename))
        }
        var duplicate = record.manifest.segments[0]; duplicate.text = "Later duplicate must not win"
        record.manifest.segments.append(duplicate)
        try raw.write(to: record.directory.appendingPathComponent("002000.pcm"))
        try record.save()
        let recovered = try RecordingSession(directory: record.directory)
        XCTAssertEqual(recovered.manifest.segments.count, 513)
        XCTAssertEqual(recovered.manifest.segments.map(\.index), Array(stride(from: 1, through: 1023, by: 2)) + [2000])
        for segment in recovered.manifest.segments.dropLast() {
            XCTAssertEqual(segment.text, "Fixture \(segment.index)")
            XCTAssertEqual(segment.sha256, hash)
        }
        let orphan = try XCTUnwrap(recovered.manifest.segments.last)
        XCTAssertNil(orphan.text); XCTAssertEqual(orphan.frames, 1)
        XCTAssertEqual(orphan.sha256, hash); XCTAssertTrue(orphan.finalized)
    }

    let config = Configuration(executable: "/qa/unused", model: "/qa/model")
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vella-session-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func session(policy: SegmentedPCMWriter.Policy = .init(), blocks: [[Float]]) throws -> RecordingSession {
        let session = try RecordingSession(root: root(), config: config)
        let writer = try SegmentedPCMWriter(session: session, policy: policy)
        for block in blocks { try block.withUnsafeBufferPointer { try writer.append($0) } }
        try writer.finish(userStopped: true)
        return try RecordingSession(directory: session.directory)
    }
    func testSilenceCutsAndForcedOverlapAreSampleExact() throws {
        var policy = SegmentedPCMWriter.Policy(); policy.preferredSeconds = 1; policy.maximumSeconds = 2; policy.silenceSeconds = 0.2; policy.overlapSeconds = 0.1
        let input = (0..<100_031).map { Float(sin(Double($0) / 13) * 0.2) }
        let record = try session(policy: policy, blocks: [input])
        XCTAssertGreaterThan(record.manifest.segments.count, 3)
        var recovered = Data()
        for segment in record.manifest.segments {
            XCTAssertLessThanOrEqual(segment.frames, 32_000)
            let pcm = try Data(contentsOf: record.directory.appendingPathComponent(segment.filename))
            recovered.append(pcm.dropFirst(segment.overlapFrames * 4))
            let wav = try record.wav(for: segment)
            let file = try AVAudioFile(forReading: wav)
            XCTAssertEqual(file.length, AVAudioFramePosition(segment.frames))
            XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        }
        XCTAssertEqual(recovered, input.withUnsafeBytes { Data($0) }, "No lost, duplicated or reordered source samples")
        let quiet = try session(policy: policy, blocks: [[Float](repeating: 0, count: 50_000)])
        XCTAssertTrue(quiet.manifest.segments.allSatisfy { $0.overlapFrames == 0 })
        XCTAssertEqual(quiet.seconds, 50_000.0/16_000, accuracy: 0.00001)
    }
    func testExactCutDoesNotRecoverDuplicateTail() throws {
        var policy = SegmentedPCMWriter.Policy(); policy.preferredSeconds = 1; policy.maximumSeconds = 2; policy.overlapSeconds = 0.1
        let record = try session(policy: policy, blocks: [[Float](repeating: 0.1, count: 32_000)])
        XCTAssertEqual(record.manifest.segments.count, 1)
        XCTAssertEqual(record.seconds, 2)
    }
    func testDiskFullPreservesCompletedAndCurrentAudio() throws {
        let record = try RecordingSession(root: root(), config: config)
        var free: Int64 = 1_000_000_000
        let writer = try SegmentedPCMWriter(session: record, availableBytes: { free })
        try [Float](repeating: 0.2, count: 32_000).withUnsafeBufferPointer { try writer.append($0) }
        free = 0
        XCTAssertThrowsError(try [Float](repeating: 0.3, count: 320).withUnsafeBufferPointer { try writer.append($0) })
        try writer.finish(userStopped: false)
        let recovered = try RecordingSession(directory: record.directory)
        XCTAssertEqual(recovered.seconds, 2)
        XCTAssertEqual(recovered.manifest.state, "interrupted")
        XCTAssertFalse(recovered.manifest.userStopped)
    }
    func testPartialWriteFailureReconcilesPersistedSamples() throws {
        let record = try RecordingSession(root: root(), config: config)
        let writer = try SegmentedPCMWriter(session: record)
        try [Float](repeating: 0.1, count: 32_000).withUnsafeBufferPointer { try writer.append($0) }
        writer.writeBytes = { file, bytes in
            try file.write(contentsOf: bytes.prefix(128))
            throw CocoaError(.fileWriteOutOfSpace)
        }
        XCTAssertThrowsError(try [Float](repeating: 0.2, count: 320).withUnsafeBufferPointer { try writer.append($0) })
        try writer.finish(userStopped: false)
        let recovered = try RecordingSession(directory: record.directory)
        XCTAssertEqual(recovered.manifest.segments[0].frames, 32_032)
        XCTAssertEqual(try AVAudioFile(forReading: recovered.wav(for: recovered.manifest.segments[0])).length, 32_032)
    }
    func testWriteFailureAndTamperNeverDeleteOriginalAudio() throws {
        let record = try session(blocks: [[Float](repeating: 0.1, count: 1000)])
        let segment = record.manifest.segments[0]
        let url = record.directory.appendingPathComponent(segment.filename)
        var bytes = try Data(contentsOf: url); bytes[0] ^= 1; try bytes.write(to: url)
        XCTAssertThrowsError(try RecordingSession(directory: record.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testAbruptProcessExitRecoversOpenSegment() throws {
        let root = try root()
        let process = Process(); process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/Vella")
        process.arguments = ["--session-crash-fixture", root.path]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); XCTFail("Crash fixture exceeded deadline"); return }
        XCTAssertEqual(process.terminationStatus, 37)
        let directory = try XCTUnwrap(RecordingSession.discover(root: root).first)
        let record = try RecordingSession(directory: directory)
        XCTAssertEqual(record.manifest.state, "interrupted")
        XCTAssertEqual(record.manifest.segments[0].frames, 33_920, "Only the unfinished <20 ms analysis frame can be absent")
        let audio = try AVAudioFile(forReading: record.wav(for: record.manifest.segments[0]))
        XCTAssertEqual(audio.length, 33_920)
    }
    @MainActor func testHourCounterNeverStopsOrPastes() {
        let model = Model(); model.phase = .recording; model.elapsed = 1799
        for _ in 0..<5402 { model.recordingTick(error: nil) }
        XCTAssertEqual(model.phase, .recording); XCTAssertEqual(model.elapsed, 7201)
        XCTAssertFalse(model.insertionWasAutomatic); XCTAssertEqual(model.lastText, "")
        model.recordingTick(error: "Simulated unplug")
        XCTAssertEqual(model.phase, .failed); XCTAssertFalse(model.insertionWasAutomatic)
    }
    @MainActor func testTimeoutThenRestartResumesOnlyUnfinishedChunks() async throws {
        var policy = SegmentedPCMWriter.Policy(); policy.preferredSeconds = 1; policy.maximumSeconds = 2; policy.overlapSeconds = 0.1
        let record = try session(policy: policy, blocks: [[Float](repeating: 0.1, count: 96_000)])
        var requests = 0
        let first = SessionTranscriber { _, _ in
            requests += 1
            if requests == 2 { throw URLError(.timedOut) }
            return "First segment."
        }
        do { _ = try await first.run(record); XCTFail("Expected timeout") } catch { }
        let recovered = try RecordingSession(directory: record.directory)
        XCTAssertEqual(recovered.manifest.segments.filter { $0.text != nil }.count, 1)
        var resumed = 0
        let next = SessionTranscriber { _, _ in resumed += 1; return "Remaining segment \(resumed)." }
        let text = try await next.run(recovered)
        XCTAssertEqual(resumed, recovered.manifest.segments.count - 1)
        XCTAssertTrue(text.hasPrefix("First segment."))
        XCTAssertEqual(try String(contentsOf: recovered.transcriptURL), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.directory.appendingPathComponent(recovered.manifest.segments[0].filename).path))
    }
    @MainActor func testCancellationCheckpointAndNoWorkDuringRecording() async throws {
        let record = try session(blocks: [[Float](repeating: 0.1, count: 1600)])
        record.manifest.state = "recording"
        let runner = SessionTranscriber { _, _ in XCTFail("Must not transcribe while recording"); return "bad" }
        do { _ = try await runner.run(record); XCTFail() } catch { }
        record.manifest.state = "ready"
        let cancellable = SessionTranscriber { _, _ in throw CancellationError() }
        do { _ = try await cancellable.run(record); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try RecordingSession(directory: record.directory)
        XCTAssertNil(recovered.manifest.segments[0].text)
        XCTAssertGreaterThan(recovered.seconds, 0)
    }
    @MainActor func testEmptyAudibleResultFailsButSilentChunksAreSkipped() async throws {
        let audible = try session(blocks: [[Float](repeating: 0.1, count: 1000)])
        do { _ = try await SessionTranscriber { _, _ in "" }.run(audible); XCTFail() } catch { }
        XCTAssertNil(audible.manifest.segments[0].text)
        let silent = try session(blocks: [[Float](repeating: 0, count: 1000)])
        do { _ = try await SessionTranscriber { _, _ in XCTFail("Digital silence must not hallucinate"); return "" }.run(silent); XCTFail() } catch { }
        XCTAssertEqual(silent.manifest.segments[0].text, "")
    }
    @MainActor func testPaddingFallbackIsBoundedAndDoesNotModifyArchive() async throws {
        let record = try session(blocks: [[Float](repeating: 0.1, count: 32_000)])
        let hash = record.manifest.segments[0].sha256
        var calls = 0
        let runner = SessionTranscriber { url, _ in
            calls += 1
            let wav = try AVAudioFile(forReading: url)
            if calls == 1 { XCTAssertEqual(wav.length, 40_000); throw VellaError.noSpeech }
            XCTAssertEqual(wav.length, 35_200)
            return "Speech recovered with context."
        }
        let text = try await runner.run(record)
        XCTAssertEqual(text, "Speech recovered with context.")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try RecordingSession(directory: record.directory).manifest.segments[0].sha256, hash)
        record.manifest.segments[0].text = nil; calls = 0
        do { _ = try await SessionTranscriber { _, _ in calls += 1; throw VellaError.noSpeech }.run(record); XCTFail() } catch { }
        XCTAssertEqual(calls, 3, "Unrecognized loud audio must fail with retained audio, not retry forever")
    }
    @MainActor func testUnrecognizedChunkDoesNotLoseLaterSpeechOrPretendCompletion() async throws {
        var policy = SegmentedPCMWriter.Policy(); policy.preferredSeconds = 1; policy.maximumSeconds = 2; policy.overlapSeconds = 0.1
        let record = try session(policy: policy, blocks: [[Float](repeating: 0.1, count: 64_000)])
        var index = 0
        let runner = SessionTranscriber { _, _ in
            if index == 2 { throw VellaError.noSpeech }
            return "Recognized segment \(index)."
        }
        runner.onChunk = { _, _, current, _ in index = current }
        do { _ = try await runner.run(record); XCTFail() } catch { }
        XCTAssertNil(record.manifest.segments[1].text)
        XCTAssertNotNil(record.manifest.segments.last?.text)
        let partial = try String(contentsOf: record.directory.appendingPathComponent("partial-transcript.txt"))
        XCTAssertTrue(partial.contains("Incomplete transcript")); XCTAssertTrue(partial.contains("Unrecognized audio"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.transcriptURL.path))
    }
    @MainActor func testRecoveryAndShutdownUseDurableTextWithoutAutomaticInsertion() async throws {
        let record = try session(blocks: [[Float](repeating: 0.1, count: 1000)])
        record.manifest.segments[0].text = "A durable saved transcript."
        _ = try record.complete()
        let clipboard = NSPasteboard(name: .init("vella-recovery-test-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        let model = Model(pasteboard: clipboard)
        model.recover(record.directory)
        for _ in 0..<100 { if model.phase == .success || model.phase == .failed { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.phase, .success)
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertEqual(clipboard.string(forType: .string), "A durable saved transcript.")
        model.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.transcriptURL.path))
        let restarted = Model(pasteboard: clipboard)
        restarted.recover(record.directory)
        for _ in 0..<100 { if restarted.phase == .success || restarted.phase == .failed { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(restarted.lastText, "A durable saved transcript.")
        XCTAssertFalse(restarted.insertionWasAutomatic)
        try restarted.deleteSavedRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.directory.path))
    }
    @MainActor func testModelEmptyResultOnQuietIntervalIsRecordedWithoutLosingAudio() async throws {
        let record = try session(blocks: [[Float](repeating: 0.0005, count: 16_000)])
        do { _ = try await SessionTranscriber { _, _ in throw VellaError.noSpeech }.run(record); XCTFail("An entirely unrecognized recording must not count as success") } catch { }
        let recovered = try RecordingSession(directory: record.directory)
        XCTAssertEqual(recovered.manifest.segments[0].text, "")
        XCTAssertEqual(recovered.manifest.segments[0].quietSlices, 1)
        XCTAssertEqual(recovered.manifest.segments[0].frames, 16_000)
    }
    func testDefaultSegmentationTakesEarlyPauseButDoesNotCutOngoingSpeechEarly() throws {
        let policy = SegmentedPCMWriter.Policy()
        XCTAssertEqual(policy.preferredSeconds, 5)
        XCTAssertEqual(policy.maximumSeconds, 25)
        let record = try session(blocks: [[Float](repeating: 0.1, count: 6 * 16_000), [Float](repeating: 0, count: 8_000), [Float](repeating: 0.1, count: 2 * 16_000)])
        XCTAssertEqual(record.manifest.segments.count, 2)
        XCTAssertEqual(record.manifest.segments[0].seconds, 6.4, accuracy: 0.03)
        XCTAssertEqual(record.manifest.segments[1].overlapFrames, 0)
    }
    func testOverlapJoinAndProgressNeverInventCompletion() {
        XCTAssertEqual(RecordingSession.join("A clear test.", "clear test continues.", overlaps: true), "A clear test. continues.")
        XCTAssertEqual(RecordingSession.join("Yes yes", "yes indeed", overlaps: false), "Yes yes yes indeed")
        XCTAssertEqual(RecordingSession.join("no no", "no no thanks", overlaps: true), "no no no no thanks", "Ambiguous repeated speech must not be deleted")
        XCTAssertEqual(RecordingSession.join("end", "start", overlaps: true), "end start")
        for elapsed in [0.0, 1, 600, 100000] {
            let estimate = TranscriptionEstimate(totalSeconds: 3600, completedSeconds: 0, currentSeconds: 25, currentElapsed: elapsed, speed: 234)
            XCTAssertLessThan(estimate.fraction, 0.01, "A slow first chunk cannot fake whole-session progress")
        }
        XCTAssertLessThan(TranscriptionEstimate(totalSeconds: 25, completedSeconds: 0, currentSeconds: 25, currentElapsed: 600, speed: 234).fraction, 1)
    }
}
