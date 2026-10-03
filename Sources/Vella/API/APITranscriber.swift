import AVFoundation
import Foundation
import VellaCore

/// Audio files for the API: any format AVFoundation decodes, resampled to 16 kHz mono Float32 and cut by the same
/// `SegmentedPCMWriter` the microphone path uses (cut at pauses after 5 s, 20 s for Whisper; 25 s maximum with a 0.5 s
/// overlap on forced cuts; a short or silent final segment is recognized with its predecessor).
enum APIAudio {
    static let unreadable = "Vella could not decode this audio file. Send WAV, MP3, M4A/AAC, FLAC, CAF or AIFF."

    /// Duration in seconds, read from the file header without decoding.
    static func duration(_ file: URL) throws -> Double {
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) } catch { throw APIError(400, unreadable, param: "file", code: "invalid_audio") }
        let rate = audio.processingFormat.sampleRate
        guard rate > 0, audio.processingFormat.channelCount > 0 else { throw APIError(400, unreadable, param: "file", code: "invalid_audio") }
        return Double(audio.length) / rate
    }

    /// Decodes `file` into a new session under `root` (its own directory; never Recordings). The caller removes it.
    static func segment(_ file: URL, root: URL, config: Configuration, maxSeconds: Double = apiMaxAudioSeconds) throws -> (RecordingSession, Double) {
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) } catch { throw APIError(400, unreadable, param: "file", code: "invalid_audio") }
        let format = audio.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(400, unreadable, param: "file", code: "invalid_audio") }
        let seconds = Double(audio.length) / format.sampleRate
        guard audio.length > 0 else { throw APIError(400, "The audio file contains no samples.", param: "file", code: "invalid_audio") }
        guard seconds <= maxSeconds else {
            throw APIError(
                400, String(format: "The audio is %.0f min long; Vella transcribes up to %.0f min per request. Split it and send the parts.", seconds / 60, maxSeconds / 60),
                param: "file", code: "audio_too_long")
        }
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: output),
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768),
            let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384)
        else {
            throw APIError(400, unreadable, param: "file", code: "invalid_audio")
        }
        converter.downmix = true
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = try RecordingSession(root: root, config: config)
        do {
            let writer = try SegmentedPCMWriter(session: session)
            var ended = false, readFailure: Error?
            while true {
                try Task.checkCancellation()
                converted.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, state in
                    // AVAudioFile.read throws (rather than returning 0 frames) at the end of the file.
                    if ended || audio.framePosition >= audio.length { ended = true; state.pointee = .endOfStream; return nil }
                    do { try audio.read(into: input, frameCount: input.frameCapacity) } catch { readFailure = error; ended = true; state.pointee = .endOfStream; return nil }
                    if input.frameLength == 0 { ended = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return input
                }
                if readFailure != nil || status == .error { throw APIError(400, unreadable, param: "file", code: "invalid_audio") }
                if converted.frameLength > 0, let channel = converted.floatChannelData?[0] {
                    try writer.append(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
                }
                if status == .endOfStream || (ended && converted.frameLength == 0) { break }
            }
            try writer.finish(userStopped: true)
            guard writer.totalFrames > 0 else { throw APIError(400, "The audio file contains no samples.", param: "file", code: "invalid_audio") }
            return (session, Double(writer.totalFrames) / 16_000)
        } catch {
            try? FileManager.default.removeItem(at: session.directory)
            throw error
        }
    }

    /// Timed pieces of a finished session: each segment's text with the overlap its predecessor already covered
    /// removed (the same trimming as the dictation transcript), placed at its unique audio. Empty pieces are dropped.
    /// A final unit recognized as one request (`RecordingSession.tailMerge`) spans all of its segments' audio.
    static func segments(_ session: RecordingSession) -> (text: String, segments: [TranscriptSegment]) {
        var pieces: [TranscriptSegment] = [], tail = "", start = 0.0
        let segments = session.manifest.segments
        let unit = (try? session.tailMerge(policy: .forModel(session.manifest.config.model), pendingOnly: false))?.segments
        for (i, segment) in segments.enumerated() {
            let next = RecordingSession.trimOverlap(tail, segment.text ?? "", overlaps: segment.overlapFrames > 0)
            var end = start + segment.seconds
            if let unit, i == unit.lowerBound { end = start + segments[unit].reduce(0.0) { $0 + $1.seconds } }
            if !next.isEmpty {
                pieces.append(TranscriptSegment(id: pieces.count, start: start, end: end, text: next))
                tail = String((tail + " " + next).suffix(2048))
            }
            start += segment.seconds
        }
        return (pieces.map(\.text).joined(separator: " "), pieces)
    }
}

/// A resolved API model: what it is called and the files it loads.
struct APIModel: Equatable {
    var id: String
    var name: String
    var precision: String
    var path: String
    var languages: [String] = []
    var loaded = false
    /// The current dictation model.
    var current = false
    /// What a request runs (loaded: what runs now, a stock fallback included; else what a load would run).
    var selection: ModelSelection?
    /// The requested selection when it differs from `selection` (an Optimized one on stock MLX).
    var requested: ModelSelection?
}

struct APITranscript {
    var text: String
    var segments: [TranscriptSegment]
    var duration: Double
    var model: APIModel
    var language: String?
}

/// Runs API transcriptions on the dictation runtime without ever getting in dictation's way: one file at a time
/// (FIFO), a segment starts only while no dictation is active and no model is being loaded or selected, every model
/// load (for the first segment or any later one) happens outside the request lane, and the dictation model is kept out
/// of eviction while an API job runs. Audio and text stay in a private temporary directory that is removed when the
/// request ends; nothing is pasted, journalled or kept.
///
/// The model is resolved again right before every load and every segment (with no suspension point before the worker
/// call), and so is the current dictation model that is kept out of eviction. A request that waited while the user
/// loaded another precision or selected another model therefore uses what is committed then; it never loads the
/// precision it saw when it arrived over the user's later choice.
@MainActor final class APITranscriber {
    let backend: Backend
    let root: URL
    /// True while a dictation records, finishes or transcribes (the app wires its phase).
    var dictationActive: () -> Bool = { false }
    var maxWaiting = 8
    private var tickets: [UUID] = []
    private(set) var completed = 0
    var running: Int { tickets.isEmpty ? 0 : 1 }
    var waiting: Int { max(0, tickets.count - 1) }
    /// Poll interval while waiting for dictation or the queue.
    var pollNanoseconds: UInt64 = 20_000_000

    init(backend: Backend, root: URL) { self.backend = backend; self.root = root }
    static let workerExited = "Vella's inference worker stopped twice while transcribing this file; nothing was kept. Try again."

    /// `resolve`: the model the request names, as it stands now (with its files prepared). `current`: the family id of
    /// the current dictation model, kept out of eviction while this request loads another one.
    func transcribe(_ file: URL, resolve: @escaping () throws -> APIModel, current: @escaping () -> String?) async throws -> APITranscript {
        guard tickets.count <= maxWaiting else { throw APIError(429, "Vella is already transcribing \(tickets.count) files; try again when they finish.") }
        let ticket = UUID(); tickets.append(ticket)
        defer { tickets.removeAll { $0 == ticket } }
        while tickets.first != ticket { try await Task.sleep(nanoseconds: pollNanoseconds) }

        var model = try resolve()
        let config = Configuration(model: model.path)
        let root = self.root
        let decode = Task.detached(priority: .utility) { try APIAudio.segment(file, root: root, config: config) }
        let (session, duration) = try await withTaskCancellationHandler(operation: { try await decode.value }, onCancel: { decode.cancel() })
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let runtime = backend.runtime
        var shielded: String?
        defer { if let shielded { runtime.unshield(shielded) } }
        /// The model to use now and the current dictation model kept out of eviction (when it is another family).
        /// Synchronous: nothing can change the selection between this and the worker call that follows it.
        func now() throws -> ModelRef {
            model = try resolve()
            let ref = runtime.resolve(model.path, mode: .dictation)
            let protect = current().flatMap { $0 == ref.id ? nil : $0 }
            if protect != shielded {
                if let shielded { runtime.unshield(shielded) }
                if let protect { runtime.shield(protect) }
                shielded = protect
            }
            return ref
        }
        /// Waits for its turn with the model `now()` names loaded, loading it outside the request lane whenever it is
        /// not (the first segment, a model selected between segments, one evicted or unloaded meanwhile), so a
        /// dictation that finishes during the load never waits for it. After every load the turn and the model are
        /// checked again: a dictation that started meanwhile goes first, and a selection made meanwhile wins. Returns
        /// with no suspension point left before the caller's worker call.
        func ready() async throws {
            var loads = 0
            while true {
                try await waitForTurn()
                let ref = try now()
                if backend.isReady(ref) { return }
                guard loads < 3 else { throw APIError(500, "\(ref.displayName) did not stay loaded; try again.", code: "model_load_failed") }
                loads += 1
                do { try await backend.preload(ref, residency: .onDemand) } catch let error as VellaError {
                    if let refused = runtime.status.refused, refused.model == ref.id, Date().timeIntervalSince1970 - refused.at < 5 {
                        throw APIError(507, refused.message, type: "server_error", code: "insufficient_memory")
                    }
                    throw APIError(500, error.localizedDescription, code: "model_load_failed")
                }
            }
        }
        // A worker that dies while the model loads gets one fresh start, as a segment does (SessionTranscriber).
        do { try await retryingDictationStops { try await ready() } } catch is WorkerExited {
            do { try await retryingDictationStops { try await ready() } } catch is WorkerExited { throw APIError(500, Self.workerExited, code: "worker_exited") }
        }
        var detectedLanguages = Set<String>()
        let runner = SessionTranscriber { [weak self] url, config in
            guard let self else { throw CancellationError() }
            return try await self.retryingDictationStops {
                var attempts = 0
                while true {
                    try await ready()
                    var segment = config; segment.model = model.path
                    do {
                        let text = try await self.backend.transcribe(url, config: segment, lane: .api)
                        if let language = self.backend.lastLanguage { detectedLanguages.insert(language) }
                        return text
                    } catch is Backend.ModelNotReady {
                        // Unloaded between the check and the call: load it again, outside the lane.
                        attempts += 1
                        if attempts >= 3 { throw APIError(500, "\(model.name) did not stay loaded; try again.", code: "model_load_failed") }
                    }
                }
            }
        }
        do { _ = try await runner.run(session) } catch let error as VellaError {
            throw APIError(500, error.localizedDescription, code: "transcription_failed")
        } catch is WorkerExited {
            // Its text ("Saved audio is retained") is the dictation's; the API keeps nothing.
            throw APIError(500, Self.workerExited, code: "worker_exited")
        }
        completed += 1
        let (text, segments) = APIAudio.segments(session)
        var used = model; used.loaded = true
        return APITranscript(text: text, segments: segments, duration: duration, model: used, language: detectedLanguages.count == 1 ? detectedLanguages.first : nil)
    }

    /// Waits while a dictation is active, another request is in the worker, or a model is loading or being selected
    /// (until that ends, what is loaded and what config.json selects may disagree). Returns with no suspension point
    /// left before the caller's backend call, so a dictation or a selection cannot slip in between.
    private func waitForTurn() async throws {
        let runtime = backend.runtime
        while dictationActive() || backend.isBusy || runtime.selectionsInFlight > 0 || runtime.status.loading != nil {
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }
    /// A dictation's Stop or Cancel ends whatever the worker is doing (`Backend.stop`); API work then simply resumes.
    private func retryingDictationStops<T>(_ body: () async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            do { return try await body() } catch is CancellationError where !Task.isCancelled && attempts < 5 { attempts += 1 }
        }
    }
}
