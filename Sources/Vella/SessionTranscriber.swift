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
    /// A short final slice may be an undecodable clipped phoneme, not missing audio.
    /// Retry once with its entire recognized predecessor; never classify by duration.
    private func retryTail(_ session: RecordingSession, at i: Int) async throws -> String? {
        let segments = session.manifest.segments
        guard i > 0, i == segments.count - 1 else { return nil }
        let tail = segments[i], previous = segments[i - 1]
        guard tail.frames > 0, tail.overlapFrames == 0, tail.seconds <= 1,
              previous.index + 1 == tail.index,
              let anchor = previous.text, !anchor.isEmpty,
              previous.frames + tail.frames - tail.overlapFrames + 8000 <= 30 * 16_000 else { return nil }
        func verified(_ segment: RecordingSession.Segment) throws -> Data {
            let raw = try Data(contentsOf: session.directory.appendingPathComponent(segment.filename))
            guard raw.count == segment.frames * 4,
                  segment.sha256 == RecordingSession.digest(raw) else {
                throw VellaError.message("Saved audio integrity check failed. Original audio is retained.")
            }
            return raw
        }
        let left = try verified(previous), right = try verified(tail)
        var combined = left
        combined.append(right.dropFirst(tail.overlapFrames * 4))
        // Isolated disposable request, never rewrite source PCM or existing checkpoints.
        let scratch = try RecordingSession(root: session.directory, config: session.manifest.config)
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let source = RecordingSession.Segment(index: 0, frames: combined.count / 4,
            peakRMS: max(previous.peakRMS, tail.peakRMS), finalized: true,
            sha256: RecordingSession.digest(combined))
        try scratch.durableWrite(combined, to: scratch.directory.appendingPathComponent(source.filename))
        let provenance: [String: Any] = ["version": 1, "previousIndex": previous.index,
            "tailIndex": tail.index, "previousSHA256": RecordingSession.digest(left),
            "tailSHA256": RecordingSession.digest(right), "previousRange": [0, previous.frames],
            "tailRange": [tail.overlapFrames, tail.frames], "paddingFrames": 4000,
            "combinedSHA256": RecordingSession.digest(combined)]
        func record(_ outcome: String, decodedContext: String? = nil) throws {
            var entry = provenance; entry["outcome"] = outcome
            // Private recovery evidence only; never used as an insertion fallback.
            if let decodedContext { entry["decodedContext"] = decodedContext }
            try session.durableWrite(JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                to: session.directory.appendingPathComponent(String(format: "context-retry-%06d.json", tail.index)))
        }
        try record("requested")
        try Task.checkCancellation()
        let decoded: String
        do { decoded = try await request(scratch.wav(for: source, paddingFrames: 4000), session.manifest.config) }
        catch VellaError.noSpeech { try record("noSpeech"); return nil }
        try Task.checkCancellation()
        guard let suffix = Self.contextSuffix(anchor: anchor, decoded: decoded) else {
            try record("anchorMismatch", decodedContext: decoded); return nil
        }
        try record(suffix.isEmpty ? "recognizedAnchorOnly" : "recognizedSuffix")
        return suffix
    }
    static func contextSuffix(anchor: String, decoded: String) -> String? {
        let a = anchor.split(whereSeparator: \.isWhitespace)
        let b = decoded.split(whereSeparator: \.isWhitespace)
        func key(_ word: Substring) -> String {
            let normalized = word.lowercased().replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'")
            // Only token-edge punctuation is ignorable. Internal apostrophes and
            // hyphens distinguish real words (we're/were, re-sign/resign).
            return String(normalized.drop(while: { !$0.isLetter && !$0.isNumber })
                .reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
        }
        let keys = a.map(key)
        guard !keys.isEmpty, !keys.contains(""), b.count >= a.count,
              keys == b.prefix(a.count).map(key) else { return nil }
        return b.dropFirst(a.count).joined(separator: " ")
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
            if segment.seconds <= 0 {
                try session.verifyRedundantTail(at: i)
                text = "" // Exact duplicate/empty PCM, not a duration-based speech decision.
            } else if segment.peakRMS <= 0.00001 {
                text = "" // Only near-digital silence, not ordinary quiet speech.
            } else {
                let start = ProcessInfo.processInfo.systemUptime
                do { text = try await transcribe(session, segment: segment, range: 0..<segment.frames, depth: 0) }
                catch VellaError.noSpeech {
                    // Don't throw away later recognizable speech because one noisy
                    // interval is undecodable. Leave it pending for explicit Retry.
                    if let recovered = try await retryTail(session, at: i) {
                        session.manifest.segments[i].text = recovered
                        session.manifest.segments[i].quietSlices = 0
                        try session.save()
                        completed += segment.seconds
                    } else { try session.save() }
                    // Context includes the predecessor and earlier empty retries:
                    // never calibrate its elapsed time against just the tiny tail.
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
