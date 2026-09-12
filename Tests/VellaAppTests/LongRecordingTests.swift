import XCTest
import AVFoundation
import CryptoKit
@testable import Vella
import VellaCore

final class LongRecordingTests: XCTestCase {
    // Same lexical normalization as benchmark_worker.words; integer-token DP keeps
    // hour-long scoring bounded in memory without an external Python dependency.
    static func lexicalErrors(_ reference: String, _ hypothesis: String) -> (Int, Int) {
        func tokens(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "[^\\w\\s']|_", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace)
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
        }
        var ids: [String: Int] = [:]
        func encode(_ words: [String]) -> [Int] { words.map { word in
            if let value = ids[word] { return value }; let value = ids.count; ids[word] = value; return value
        } }
        let ref = encode(tokens(reference)), hyp = encode(tokens(hypothesis))
        var previous = Array(0...hyp.count), current = [Int](repeating: 0, count: hyp.count + 1)
        for (i, word) in ref.enumerated() {
            current[0] = i + 1
            for (j, other) in hyp.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (word == other ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return (previous[hyp.count], ref.count)
    }
    func testLongReplayScorerNormalizesWithoutHidingWordErrors() {
        let equal = Self.lexicalErrors("'Hello', don’t stop.", "hello don't STOP")
        XCTAssertEqual(equal.0, 0); XCTAssertEqual(equal.1, 3)
        XCTAssertEqual(Self.lexicalErrors("one two three", "one four").0, 2)
        XCTAssertEqual(Self.lexicalErrors("sea going", "seagoing").0, 2)
        XCTAssertEqual(Self.lexicalErrors("", "extra words").0, 2)
    }
    struct Suite: Decodable { struct Clip: Decodable { let file: String; let reference: String; let speaker: Int }; let clips: [Clip] }
    static func sample(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription, sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VellaError.message("QA sample creation failed") }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr else { throw VellaError.message("QA sample data failed") }
        return sample
    }
    @MainActor func testHourOfCorpusThroughCaptureAndRealBackend() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_LONG_SUITE"] else { throw XCTSkip("Opt-in hour-long real-backend replay; no microphone or paste") }
        let suiteRoot = URL(fileURLWithPath: path)
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: suiteRoot.appendingPathComponent("manifest.json")))
        let selectedClips: [Suite.Clip]
        if let speaker = ProcessInfo.processInfo.environment["VELLA_LONG_SPEAKER"].flatMap(Int.init) {
            selectedClips = suite.clips.filter { $0.speaker == speaker }
        } else { selectedClips = suite.clips }
        XCTAssertFalse(selectedClips.isEmpty)
        guard !selectedClips.isEmpty else { return }
        let python = ProcessInfo.processInfo.environment["VELLA_TEST_RUNTIME_PYTHON"].map { URL(fileURLWithPath: $0) }
        let backend = Backend(python: python), config = try backend.configuration()
        defer { backend.stop() }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa/hour-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try RecordingSession(root: root, config: config)
        let sink = try CaptureSink(session: record)
        var seconds = 0.0, references: [String] = [], clips = 0
        var sourceHash = SHA256()
        let began = ProcessInfo.processInfo.systemUptime
        while seconds < 3600 {
            for clip in selectedClips {
                let file = try AVAudioFile(forReading: suiteRoot.appendingPathComponent(clip.file))
                XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
                XCTAssertEqual(file.processingFormat.channelCount, 1)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
                while file.framePosition < file.length {
                    try file.read(into: buffer, frameCount: 4096)
                    guard buffer.frameLength > 0 else { break }
                    let bytes = UnsafeRawBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength) * 4)
                    sourceHash.update(data: Data(bytes))
                    sink.consume(try Self.sample(buffer))
                }
                let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000)); silence.frameLength = 8000
                silence.floatChannelData![0].update(repeating: 0, count: 8000)
                sourceHash.update(data: Data(repeating: 0, count: 32_000))
                sink.consume(try Self.sample(silence))
                seconds += Double(file.length) / 16000 + 0.5; references.append(clip.reference); clips += 1
                if seconds >= 3600 { break }
            }
        }
        sink.finish(userStopped: true)
        XCTAssertNil(sink.error)
        XCTAssertGreaterThanOrEqual(record.seconds, 3600)
        XCTAssertEqual(record.seconds, seconds, accuracy: 0.001)
        let recovered = try RecordingSession(directory: record.directory)
        var savedHash = SHA256()
        for segment in recovered.manifest.segments {
            XCTAssertLessThanOrEqual(segment.frames, 400_000)
            let raw = try Data(contentsOf: recovered.directory.appendingPathComponent(segment.filename))
            savedHash.update(data: raw.dropFirst(segment.overlapFrames * 4))
        }
        let sourceDigest = sourceHash.finalize().map { String(format: "%02x", $0) }.joined()
        let savedDigest = savedHash.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sourceDigest, savedDigest, "Every original sample survives the full capture/conversion/segmentation/recovery path")
        let replaySeconds = ProcessInfo.processInfo.systemUptime - began
        var requests = 0
        var memorySamples: [[String: Double]] = []
        let transcriber = SessionTranscriber { url, config in
            requests += 1
            do {
                let text = try await backend.transcribe(url, config: config)
                memorySamples.append(backend.lastMetrics)
                return text
            }
            catch {
                try Data(contentsOf: url).write(to: root.deletingLastPathComponent().appendingPathComponent("hour-failed-segment.wav"))
                print("Failed real request \(requests); capture completed in \(replaySeconds) seconds; sample hash verified")
                throw error
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let text = try await transcriber.run(recovered)
        let processing = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThan(text.count, 10_000)
        XCTAssertEqual(recovered.manifest.state, "transcribed")
        XCTAssertEqual(recovered.manifest.segments.filter { $0.text == nil }.count, 0)
        XCTAssertEqual(backend.ownership, "Vella private worker")
        XCTAssertEqual(try String(contentsOf: recovered.transcriptURL), text)
        let (wordErrors, referenceWords) = Self.lexicalErrors(references.joined(separator: " "), text)
        let wer = Double(wordErrors) / Double(max(1, referenceWords))
        let report: [String: Any] = ["audioSeconds": recovered.seconds, "sourceClips": clips, "segments": recovered.manifest.segments.count,
            "requests": requests, "workerMetrics": memorySamples, "sourceSHA256": sourceDigest, "savedSHA256": savedDigest, "replaySeconds": replaySeconds,
            "processingSeconds": processing, "model": URL(fileURLWithPath: config.model).lastPathComponent,
            "wordErrors": wordErrors, "referenceWords": referenceWords, "lexicalWER": wer,
            "transcript": text, "reference": references.joined(separator: " "), "kind": "accelerated corpus replay, not an hour of physical microphone use"]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: root.deletingLastPathComponent().appendingPathComponent("hour-session-results.json"), options: .atomic)
        let maximumWER = Double(ProcessInfo.processInfo.environment["VELLA_MAX_LONG_WER"] ?? "0.05") ?? 0.05
        XCTAssertLessThanOrEqual(wer, maximumWER, "Retention/completion is not an accuracy pass. Inspect missing words and compare the same clips directly.")
        print("Long-replay lexical WER: \(wordErrors)/\(referenceWords) = \(wer)")
        print("Hour replay: \(Int(recovered.seconds)) audio seconds; \(requests) real requests; sample hashes match; \(Int(processing)) seconds transcription.")
    }
    @MainActor func testRealWorkerReplacementExitsPredecessor() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_TEST_RUNTIME_PYTHON"], ProcessInfo.processInfo.environment["VELLA_REAL_SWITCH_CHECK"] == "1" else { throw XCTSkip("Opt-in real worker replacement check; uses two paths to the same weights, not a second model") }
        let backend = Backend(python: URL(fileURLWithPath: path))
        defer { backend.shutdown() }
        var config = try backend.configuration()
        let original = config.model
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: original)
        defer { try? FileManager.default.removeItem(at: alias) }
        let audio = ModelLibrary.resourceDirectory().appendingPathComponent("Calibration/speech.wav")
        var previous: Int32?
        for path in [original, alias.path, original] {
            config.model = path
            _ = try await backend.transcribe(audio, config: config)
            let current = try XCTUnwrap(backend.processID)
            if let previous {
                XCTAssertNotEqual(current, previous)
                XCTAssertNotEqual(kill(previous, 0), 0, "Old process must be gone before replacement inference")
            }
            previous = current
        }
    }
    @MainActor func testRealWorkerUnloadsAfterSixtySecondsIdle() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_TEST_RUNTIME_PYTHON"], ProcessInfo.processInfo.environment["VELLA_REAL_IDLE_CHECK"] == "1" else { throw XCTSkip("Opt-in real worker idle-memory check") }
        let backend = Backend(python: URL(fileURLWithPath: path))
        defer { backend.shutdown() }
        let config = try backend.configuration()
        let audio = ModelLibrary.resourceDirectory().appendingPathComponent("Calibration/speech.wav")
        let started = ProcessInfo.processInfo.systemUptime
        _ = try await backend.transcribe(audio, config: config)
        let cold = ProcessInfo.processInfo.systemUptime - started
        let pid = try XCTUnwrap(backend.processID)
        let warmStart = ProcessInfo.processInfo.systemUptime
        _ = try await backend.transcribe(audio, config: config)
        print("Private worker cold/warm wall seconds: \(cold) / \(ProcessInfo.processInfo.systemUptime - warmStart)")
        XCTAssertEqual(backend.processID, pid)
        try await Task.sleep(nanoseconds: 63_000_000_000)
        XCTAssertNil(backend.processID)
        XCTAssertNotEqual(kill(pid, 0), 0, "Worker process and all its allocations must be gone")
    }
    @MainActor func testRealCalibrationForActiveModel() async throws {
        guard ProcessInfo.processInfo.environment["VELLA_REAL_CALIBRATION"] == "1" else { throw XCTSkip("Opt-in bounded local calibration") }
        let model = try Backend().configuration().model
        guard let path = ProcessInfo.processInfo.environment["VELLA_CALIBRATION_TEST_PYTHON"] else { throw XCTSkip("Set the private runtime interpreter") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CalibrationStore(directory: directory, python: { URL(fileURLWithPath: path) })
        if store.speed(modelPath: model) != nil { return }
        let done = expectation(description: "calibration completion")
        XCTAssertTrue(store.calibrate(modelPath: model, status: { _ in }, completion: { error in
            XCTAssertNil(error); done.fulfill()
        }))
        await fulfillment(of: [done], timeout: 130)
        XCTAssertNotNil(store.speed(modelPath: model))
    }
}
