import XCTest
import AVFoundation
import CryptoKit
@testable import Vella
import VellaCore

/// Opt-in pipeline QA with a real VellaWorker and a real model (run under lab/bin/gpulock). No microphone, no paste:
/// PCM from a file enters `CaptureSink.consume`, the Recorder's own entry point, and goes through the conversion,
/// segmentation and durable journal, recovery from disk, and `SessionTranscriber` → `Backend` → VellaWorker.
///
///   VELLA_QA_WORKER    VellaWorker executable (a candidate app's Contents/MacOS/VellaWorker)
///   VELLA_QA_MODEL     model folder (e.g. a Parakeet v3 4-bit clone)
///   VELLA_QA_PCM       16 kHz mono Float32 PCM (lab long-dictation fixture long60.f32)
///   VELLA_QA_SECONDS   seconds of it to record (default 902.1: the first two clips, 15 min)
///   VELLA_QA_REFERENCE optional long60.json (clip references, for WER over the clips recorded)
///   VELLA_QA_OUT       directory for the JSON report and the session copies
final class LongDictationQATests: XCTestCase {
    struct Report: Encodable {
        var audioSeconds = 0.0, segments = 0, forcedCuts = 0
        var sourceSHA256 = "", savedSHA256 = ""
        var cleanRequests = 0, cleanSeconds = 0.0, cleanWordErrors = 0, referenceWords = 0
        var killWorker: [String: String] = [:]
        var doubleKill: [String: String] = [:]
        var appCrash: [String: String] = [:]
    }

    @MainActor func testLongDictationThroughTheJournalWithWorkerKillsAndACrashPoint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let worker = env["VELLA_QA_WORKER"], let modelPath = env["VELLA_QA_MODEL"], let pcmPath = env["VELLA_QA_PCM"],
            let outPath = env["VELLA_QA_OUT"]
        else { throw XCTSkip("Opt-in long-dictation pipeline QA (real worker and model)") }
        let seconds = Double(env["VELLA_QA_SECONDS"] ?? "") ?? 902.1
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = Report()

        // 1. Record: the file's PCM in 4096-frame capture buffers through the Recorder's sink.
        let config = Configuration(model: modelPath)
        let record = try RecordingSession(root: out.appendingPathComponent("recording"), config: config)
        let sink = try CaptureSink(session: record)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: pcmPath))
        defer { try? input.close() }
        let totalFrames = Int(seconds * 16_000)
        var fed = 0
        var sourceHash = SHA256()
        while fed < totalFrames {
            let count = min(4096, totalFrames - fed)
            guard let data = try input.read(upToCount: count * 4), data.count == count * 4 else { break }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            data.withUnsafeBytes { raw in buffer.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: count) }
            sourceHash.update(data: data)
            sink.consume(try LongRecordingTests.sample(buffer))
            fed += count
        }
        sink.finish(userStopped: true)
        XCTAssertNil(sink.error)
        report.audioSeconds = record.seconds
        XCTAssertEqual(record.seconds, Double(fed) / 16_000, accuracy: 0.001, "no audio lost between the capture buffers and the journal")
        let recovered = try RecordingSession(directory: record.directory)
        var savedHash = SHA256()
        for segment in recovered.manifest.segments {
            savedHash.update(data: try Data(contentsOf: recovered.directory.appendingPathComponent(segment.filename)).dropFirst(segment.overlapFrames * 4))
        }
        report.sourceSHA256 = sourceHash.finalize().map { String(format: "%02x", $0) }.joined()
        report.savedSHA256 = savedHash.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(report.sourceSHA256, report.savedSHA256, "every fed sample is on disk exactly once")
        report.segments = recovered.manifest.segments.count
        report.forcedCuts = recovered.manifest.segments.filter { $0.overlapFrames > 0 }.count

        // Identical copies of the finished recording (the journal as it is on disk after Finish).
        func copy(_ name: String) throws -> URL {
            let url = out.appendingPathComponent(name)
            try FileManager.default.copyItem(at: recovered.directory, to: url)
            return url
        }
        let killDir = try copy("kill-worker"), doubleDir = try copy("double-kill"), crashSource = try copy("app-crash-source")
        let crashPoint = out.appendingPathComponent("app-crash-at-segment")

        let backend = Backend(helper: URL(fileURLWithPath: worker), runtime: try Runtime.isolated(out.appendingPathComponent("runtime")))
        defer { backend.shutdown() }

        // 2. Clean transcription: the reference for the fault runs.
        var requests = 0
        let started = ProcessInfo.processInfo.systemUptime
        let clean = SessionTranscriber { url, config in requests += 1; return try await backend.transcribe(url, config: config) }
        let cleanText = try await clean.run(recovered)
        report.cleanSeconds = ProcessInfo.processInfo.systemUptime - started
        report.cleanRequests = requests
        let cleanSegments = recovered.manifest.segments.map(\.text)
        XCTAssertEqual(recovered.manifest.state, "transcribed")
        if let referencePath = env["VELLA_QA_REFERENCE"] {
            struct Clip: Decodable { let end: Int; let reference: String }
            struct Fixture: Decodable { let clips: [Clip] }
            let clips = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: referencePath))).clips
            let covered = clips.filter { $0.end <= fed }.map(\.reference).joined(separator: " ")
            (report.cleanWordErrors, report.referenceWords) = LongRecordingTests.lexicalErrors(covered, cleanText)
        }

        /// SIGKILLs the worker `delay` after one other than `previous` is running (a reload after a kill takes a moment).
        func killWorker(after delay: UInt64, avoiding previous: Int32?) async -> Int32? {
            for _ in 0..<600 {
                if let pid = backend.processID, pid != previous {
                    try? await Task.sleep(nanoseconds: delay)
                    kill(pid, SIGKILL); return pid
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
        let middle = max(2, report.segments / 2)

        // 3. Worker killed mid-segment once: the automatic retry on a fresh worker; the text must come out exactly once.
        do {
            let session = try RecordingSession(directory: killDir)
            var n = 0, retries = 0
            var killer: Task<Int32?, Never>?
            let runner = SessionTranscriber { url, config in
                n += 1
                if n == middle { killer = Task { await killWorker(after: 20_000_000, avoiding: nil) } }
                return try await backend.transcribe(url, config: config)
            }
            runner.onRetry = { _, _ in retries += 1 }
            let text = try await runner.run(session)
            let killed = await killer?.value
            report.killWorker = [
                "killedPid": killed.map { String($0) } ?? "none", "automaticRetries": String(retries), "requests": String(n),
                "transcriptIdentical": String(text == cleanText),
                "segmentsIdentical": String(session.manifest.segments.map(\.text) == cleanSegments)
            ]
            XCTAssertNotNil(killed); XCTAssertEqual(retries, 1)
            XCTAssertEqual(n, report.cleanRequests + 1, "exactly one extra request: the killed segment, once")
            XCTAssertEqual(text, cleanText, "no lost or duplicated text after the automatic retry")
        }

        // 4. Killed twice (the request and its automatic retry): the run fails with the saved segments kept, and the
        //    user's Retry (recover from disk, run again) finishes only the unfinished segments.
        do {
            var session = try RecordingSession(directory: doubleDir)
            var n = 0, firstError = ""
            var firstPid: Int32?
            let runner = SessionTranscriber { url, config in
                n += 1
                if n == middle { firstPid = backend.processID; Task { _ = await killWorker(after: 20_000_000, avoiding: nil) } }
                if n == middle + 1 { let avoid = firstPid; Task { _ = await killWorker(after: 20_000_000, avoiding: avoid) } }
                return try await backend.transcribe(url, config: config)
            }
            do { _ = try await runner.run(session); XCTFail("expected the second kill to end the run") } catch { firstError = error.localizedDescription }
            let doneBeforeRetry = session.manifest.segments.filter { $0.text != nil }.count
            session = try await RecordingSession.recover(doubleDir)
            XCTAssertEqual(session.manifest.segments.filter { $0.text != nil }.count, doneBeforeRetry, "saved per-segment text survives on disk")
            var retryRequests = 0
            let retry = SessionTranscriber { url, config in retryRequests += 1; return try await backend.transcribe(url, config: config) }
            let text = try await retry.run(session)
            report.doubleKill = [
                "firstError": firstError, "stateAfterFailure": try RecordingSession(directory: doubleDir).manifest.state,
                "segmentsSavedBeforeRetry": String(doneBeforeRetry), "retryRequests": String(retryRequests),
                "transcriptIdentical": String(text == cleanText),
                "segmentsIdentical": String(session.manifest.segments.map(\.text) == cleanSegments)
            ]
            XCTAssertEqual(text, cleanText)
        }

        // 5. App-process crash mid-segment: the journal is snapshotted while segment `middle` is in flight (the
        //    on-disk state a SIGKILL of the app leaves: every save is atomic and fsynced), then recovered and resumed.
        do {
            let session = try RecordingSession(directory: crashSource)
            var n = 0
            let runner = SessionTranscriber { url, config in
                n += 1
                if n == middle { try FileManager.default.copyItem(at: crashSource, to: crashPoint) }
                return try await backend.transcribe(url, config: config)
            }
            _ = try await runner.run(session)
            let atCrash = try RecordingSession(directory: crashPoint)
            let resumed = try await RecordingSession.recover(crashPoint)
            let saved = resumed.manifest.segments.filter { $0.text != nil }.count
            var resumedRequests = 0
            let retry = SessionTranscriber { url, config in resumedRequests += 1; return try await backend.transcribe(url, config: config) }
            let text = try await retry.run(resumed)
            report.appCrash = [
                "stateAtCrash": atCrash.manifest.state, "segmentsSavedAtCrash": String(saved),
                "resumeRequests": String(resumedRequests), "transcriptIdentical": String(text == cleanText),
                "segmentsIdentical": String(resumed.manifest.segments.map(\.text) == cleanSegments)
            ]
            XCTAssertEqual(text, cleanText)
            XCTAssertEqual(saved + resumedRequests, report.cleanRequests, "each segment recognized once across the crash")
        }

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        try json.write(to: out.appendingPathComponent("long-dictation-report.json"))
        try Data(cleanText.utf8).write(to: out.appendingPathComponent("clean-transcript.txt"))
        print("QA long dictation: \(String(decoding: json, as: UTF8.self))")
    }
}
