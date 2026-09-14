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

/// A successful model response is authoritative, including an empty string.
/// Only execution, transport, cancellation and persistence failures leave work pending.
@MainActor final class SessionTranscriber {
    typealias Request = (URL, Configuration) async throws -> String
    var onChunk: ((Double, Double, Int, Int) -> Void)?
    var onObservation: ((String, Double, Double) -> Void)?
    let request: Request
    init(request: @escaping Request) { self.request = request }

    func run(_ session: RecordingSession) async throws -> String {
        guard session.manifest.state != "recording" else {
            throw VellaError.message("Finish recording before transcription. Nothing has been pasted.")
        }
        session.manifest.state = "transcribing"; session.manifest.failureCode = nil
        try session.save()
        var completed = session.manifest.segments.filter { $0.text != nil }.reduce(0.0) { $0 + $1.seconds }
        var requests = 0
        for i in session.manifest.segments.indices {
            try Task.checkCancellation()
            let segment = session.manifest.segments[i]
            if segment.text != nil { continue }
            onChunk?(completed, segment.seconds, i + 1, session.manifest.segments.count)
            let text: String
            if segment.seconds <= 0 {
                // An exact redundant overlap is a storage boundary, not a speech judgment.
                try session.verifyRedundantTail(at: i)
                text = ""
            } else {
                let file = try session.wav(for: segment)
                let start = ProcessInfo.processInfo.systemUptime
                text = try await request(file, session.manifest.config).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                try Task.checkCancellation()
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                // Exclude the first (potentially cold) request from warm calibration.
                if requests > 0, !text.isEmpty {
                    onObservation?(session.manifest.config.model, Double(segment.frames) / 16_000, elapsed)
                }
                requests += 1
            }
            try Task.checkCancellation()
            session.manifest.segments[i].text = text
            session.manifest.segments[i].textThroughIndex = nil
            session.manifest.segments[i].quietSlices = nil
            do { try session.save() }
            catch { session.manifest.segments[i] = segment; throw error }
            completed += segment.seconds
        }
        try Task.checkCancellation()
        let segments = session.manifest.segments
        let assembly = Task.detached(priority: .userInitiated) { try RecordingSession.assemble(segments) }
        let text = try await withTaskCancellationHandler(operation: { try await assembly.value }, onCancel: { assembly.cancel() })
        try Task.checkCancellation()
        return try session.finalizeTranscript(text)
    }
}
