import Foundation
import VellaCore

struct TranscriptionEstimate {
    /// Decide once for the pending job; don't flicker off as its remaining time falls.
    static func shouldDisplay(pendingAudioSeconds: Double, speed: Double?) -> Bool {
        guard pendingAudioSeconds.isFinite, pendingAudioSeconds > 0,
            let speed, speed.isFinite, speed > 0
        else { return false }
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
    /// A segment is retried after its worker crashed (1-based segment index, segment count).
    var onRetry: ((Int, Int) -> Void)?
    let request: Request
    init(request: @escaping Request) { self.request = request }

    func run(_ session: RecordingSession, available: Range<Int>? = nil) async throws -> String {
        guard session.manifest.state != "recording" else {
            throw VellaError.message("Finish recording before transcription. Nothing has been pasted.")
        }
        session.manifest.state = "transcribing"; session.manifest.failureCode = nil
        try session.save()
        var completed = session.manifest.segments.filter { $0.text != nil }.reduce(0.0) { $0 + $1.seconds }
        var requests = 0
        func recognize(_ file: URL, frames: Int, segment i: Int) async throws -> String {
            var start = ProcessInfo.processInfo.systemUptime
            var retried = false
            var recognized = ""
            while true {
                do { recognized = try await request(file, session.manifest.config); break } catch is WorkerExited where !retried {
                    // One automatic retry of this segment on a fresh worker. Finished segments are already saved;
                    // the caller's Finish-time destination and paste decision are untouched (this stays inside
                    // the same transcription). A second failure falls through to the manual Retry.
                    try Task.checkCancellation()
                    retried = true; onRetry?(i + 1, session.manifest.segments.count)
                    start = ProcessInfo.processInfo.systemUptime
                }
            }
            let text = recognized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            try Task.checkCancellation()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            // Exclude the first (potentially cold) request, and a retry (it reloads the model), from warm calibration.
            if requests > 0, !retried, !text.isEmpty {
                onObservation?(session.manifest.config.model, Double(frames) / 16_000, elapsed)
            }
            requests += 1
            return text
        }
        // Cut points were decided while recording; the final segments may still be recognized as one unit.
        let merge = available == nil ? try session.tailMerge(policy: .forModel(session.manifest.config.model)) : nil
        for i in available ?? session.manifest.segments.indices {
            try Task.checkCancellation()
            let segment = session.manifest.segments[i]
            if segment.text != nil { continue }
            if let merge, i == merge.segments.lowerBound {
                let unit = Array(session.manifest.segments[merge.segments])
                let seconds = unit.reduce(0.0) { $0 + $1.seconds }
                onChunk?(completed, seconds, i + 1, session.manifest.segments.count)
                var audio = try session.samples(for: segment)
                for later in unit.dropFirst() { audio += try session.samples(for: later).dropFirst(later.overlapFrames) }
                var text = ""
                for (k, range) in merge.requests.enumerated() {
                    let piece = try await recognize(try session.wav(samples: audio[range]), frames: range.count, segment: i)
                    text = k == 0 ? piece : RecordingSession.join(text, piece, overlaps: true)
                }
                try Task.checkCancellation()
                for index in merge.segments {
                    session.manifest.segments[index].text = index == i ? text : ""
                    session.manifest.segments[index].textThroughIndex = nil
                    session.manifest.segments[index].quietSlices = nil
                }
                // One save: the unit's texts land together, so it is recognized, and its text used, exactly once.
                do { try session.save() } catch { session.manifest.segments.replaceSubrange(merge.segments, with: unit); throw error }
                completed += seconds
                continue
            }
            onChunk?(completed, segment.seconds, i + 1, session.manifest.segments.count)
            let text: String
            if segment.seconds <= 0 {
                // An exact redundant overlap is a storage boundary, not a speech judgment.
                try session.verifyRedundantTail(at: i)
                text = ""
            } else {
                text = try await recognize(try session.wav(for: segment), frames: segment.frames, segment: i)
            }
            try Task.checkCancellation()
            session.manifest.segments[i].text = text
            session.manifest.segments[i].textThroughIndex = nil
            session.manifest.segments[i].quietSlices = nil
            do { try session.save() } catch { session.manifest.segments[i] = segment; throw error }
            completed += segment.seconds
        }
        try Task.checkCancellation()
        if available != nil { return "" }
        let segments = session.manifest.segments
        let assembly = Task.detached(priority: .userInitiated) { try RecordingSession.assemble(segments) }
        let text = try await withTaskCancellationHandler(operation: { try await assembly.value }, onCancel: { assembly.cancel() })
        try Task.checkCancellation()
        return try session.finalizeTranscript(text)
    }
}
