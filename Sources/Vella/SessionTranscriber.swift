import Foundation
import VellaCore

struct TranscriptionEstimate {
    /// Decide once for the pending job; don't flicker off as its remaining time falls.
    static func shouldDisplay(pendingAudioSeconds: Double, speed: Double?) -> Bool {
        guard pendingAudioSeconds.isFinite, pendingAudioSeconds > 0,
              let speed, speed.isFinite, speed > 0 else { return false }
        return pendingAudioSeconds / speed > 5
    }
    let totalSeconds: Double
    let completedSeconds: Double
    let currentSeconds: Double
    let currentElapsed: Double
    let speed: Double
    var fraction: Double {
        guard totalSeconds > 0 else { return 0 }
        guard speed.isFinite, speed > 0 else { return min(0.99, max(0, completedSeconds / totalSeconds)) }
        let estimated = min(currentSeconds * 0.95, max(0, currentElapsed) * speed)
        return min(0.99, max(0, (completedSeconds + estimated) / totalSeconds))
    }
    var remainingSeconds: Double { max(0, totalSeconds * (1 - fraction) / max(0.01, speed)) }
}

@MainActor final class SessionTranscriber {
    typealias Request = (URL, Configuration) async throws -> String
    var onChunk: ((Double, Double, Int, Int) -> Void)?
    var onObservation: ((String, Double, Double) -> Void)?
    private var quietSlices = 0
    let request: Request
    init(request: @escaping Request) { self.request = request }
    private func transcribe(_ session: RecordingSession, segment: RecordingSession.Segment, range: Range<Int>, depth: Int) async throws -> String {
        try Task.checkCancellation()
        do {
            // 250 ms context padding avoids Parakeet's empty decode on abruptly
            // cropped speech. It changes only the request, never the saved samples.
            return try await request(session.wav(for: segment, range: range, paddingFrames: 4000), session.manifest.config)
        } catch VellaError.noSpeech {
            // Bounded alternative context alignment; no gain changes or invented text.
            for padding in [1600, 8000] {
                try Task.checkCancellation()
                do { return try await request(session.wav(for: segment, range: range, paddingFrames: padding), session.manifest.config) }
                catch VellaError.noSpeech { continue }
            }
            // Some models return empty for otherwise audible longer inputs. Retry
            // only this explicit condition, on smaller slices, with a strict bound.
            // Transport/timeout errors are never silently retried.
            let raw = try Data(contentsOf: session.directory.appendingPathComponent(segment.filename))
            // A model-confirmed empty result on very quiet audio is a pause, not a
            // failed hour-long dictation. Keep the original and record this decision.
            if RecordingSession.peakRMS(raw, range: range) < 0.0015 {
                quietSlices += 1; return ""
            }
            guard depth < 2, range.count > 4 * 16_000 else { throw VellaError.noSpeech }
            let middle = range.lowerBound + range.count / 2
            var cut = middle, quiet = false, minimum = Double.infinity
            raw.withUnsafeBytes { bytes in
                for start in stride(from: max(range.lowerBound + 320, middle - 16000), to: min(range.upperBound - 320, middle + 16000), by: 320) {
                    var sum = 0.0
                    for i in start..<(start + 320) { let value = Double(bytes.loadUnaligned(fromByteOffset: i * 4, as: Float.self)); sum += value * value }
                    let rms = sqrt(sum / 320)
                    if rms < minimum { minimum = rms; cut = start + 160 }
                }
                quiet = minimum < 0.003
            }
            let overlap = quiet ? 0 : 4000
            let left = try await transcribe(session, segment: segment, range: range.lowerBound..<cut, depth: depth + 1)
            let right = try await transcribe(session, segment: segment, range: max(range.lowerBound, cut - overlap)..<range.upperBound, depth: depth + 1)
            return RecordingSession.join(left, right, overlaps: overlap > 0)
        }
    }
    func run(_ session: RecordingSession) async throws -> String {
        guard session.manifest.state != "recording" else { throw VellaError.message("Finish recording before transcription. Nothing has been pasted.") }
        session.manifest.state = "transcribing"; session.manifest.failureCode = nil; try session.save()
        var completed = session.manifest.segments.filter { $0.text != nil }.reduce(0.0) { $0 + $1.seconds }
        var requestCount = 0
        for i in session.manifest.segments.indices {
            try Task.checkCancellation()
            let segment = session.manifest.segments[i]
            if segment.text != nil { continue }
            onChunk?(completed, segment.seconds, i + 1, session.manifest.segments.count)
            let text: String
            quietSlices = 0
            if segment.seconds <= 0 || segment.peakRMS <= 0.00001 {
                text = "" // Only near-digital silence, not ordinary quiet speech.
            } else {
                let start = ProcessInfo.processInfo.systemUptime
                do { text = try await transcribe(session, segment: segment, range: 0..<segment.frames, depth: 0) }
                catch VellaError.noSpeech {
                    // Don't throw away later recognizable speech because one noisy
                    // interval is undecodable. Leave it pending for explicit Retry.
                    try session.save()
                    continue
                }
                try Task.checkCancellation()
                guard quietSlices > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VellaError.message("A non-silent segment returned no text. Saved audio is retained for Retry.")
                }
                let seconds = ProcessInfo.processInfo.systemUptime - start
                // The first request may include model loading/queueing. Don't call it warm speed.
                if requestCount > 0, !text.isEmpty, quietSlices == 0 { onObservation?(session.manifest.config.model, Double(segment.frames) / 16_000, seconds) }
                requestCount += 1
            }
            session.manifest.segments[i].text = text
            session.manifest.segments[i].quietSlices = quietSlices
            try session.save() // Checkpoint before starting another request or any insertion.
            completed += segment.seconds
        }
        try Task.checkCancellation()
        guard session.manifest.segments.allSatisfy({ $0.text != nil }) else {
            _ = try session.savePartialTranscript()
            throw VellaError.unrecognizedAudio
        }
        let segments = session.manifest.segments
        let assembly = Task.detached(priority: .userInitiated) { try RecordingSession.assemble(segments) }
        let text = try await withTaskCancellationHandler(operation: { try await assembly.value }, onCancel: { assembly.cancel() })
        try Task.checkCancellation()
        return try session.finalizeTranscript(text)
    }
}
