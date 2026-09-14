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
            if Self.isModelConfirmedQuiet(raw, range: range) {
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
    /// Called only after all three explicit noSpeech decodes. This is not VAD:
    /// tolerate isolated low-level clicks in long quiet spans, not word-length activity.
    static func isModelConfirmedQuiet(_ raw: Data, range: Range<Int>) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= raw.count / 4, !range.isEmpty else { return false }
        var levels: [Double] = []
        raw.withUnsafeBytes { bytes in
            for start in stride(from: range.lowerBound, to: range.upperBound, by: 320) {
                let end = min(start + 320, range.upperBound)
                var sum = 0.0
                for i in start..<end {
                    let value = Double(bytes.loadUnaligned(fromByteOffset: i * 4, as: Float.self))
                    sum += value * value
                }
                levels.append(sqrt(sum / Double(end - start)))
            }
        }
        guard levels.allSatisfy({ $0.isFinite }) else { return false }
        if levels.allSatisfy({ $0 < 0.0015 }) { return true } // Existing quiet policy.
        guard range.count >= 2 * 16_000, levels.max()! < 0.005,
              levels.sorted()[levels.count / 2] < 0.00075 else { return false }
        var active = 0, run = 0
        for level in levels {
            run = level >= 0.0015 ? run + 1 : 0
            if run > 2 { return false } // Never swallow a sustained 60+ ms possible word.
            if level >= 0.0015 { active += 1 }
        }
        return Double(active) / Double(levels.count) <= 0.02
    }

    private func verifiedPCM(_ session: RecordingSession, _ segment: RecordingSession.Segment) throws -> Data {
        let raw = try Data(contentsOf: session.directory.appendingPathComponent(segment.filename))
        guard raw.count == segment.frames * 4, segment.sha256 == RecordingSession.digest(raw) else {
            throw VellaError.message("Saved audio integrity check failed. Original audio is retained.")
        }
        return raw
    }

    /// Before either checkpoint exists, recognize a tiny final tail with its predecessor.
    /// No anchor has been committed, so one result owns both exact source ranges.
    private func freshTailGroup(_ session: RecordingSession, at i: Int) async throws -> String? {
        let segments = session.manifest.segments
        guard i + 2 == segments.count else { return nil }
        let previous = segments[i], tail = segments[i + 1]
        guard previous.text == nil, tail.text == nil, previous.frames > 0,
              max(previous.peakRMS, tail.peakRMS) > 0.00001,
              tail.frames > 0, tail.overlapFrames == 0, tail.seconds <= 1,
              previous.index + 1 == tail.index,
              previous.frames + tail.frames + 16000 <= 30 * 16000 else { return nil }
        var combined = try verifiedPCM(session, previous)
        combined.append(try verifiedPCM(session, tail))
        let scratch = try RecordingSession(root: session.directory, config: session.manifest.config)
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let source = RecordingSession.Segment(index: 0, frames: combined.count / 4,
            peakRMS: max(previous.peakRMS, tail.peakRMS), finalized: true,
            sha256: RecordingSession.digest(combined))
        try scratch.durableWrite(combined, to: scratch.directory.appendingPathComponent(source.filename))
        for padding in [4000, 1600, 8000] {
            try Task.checkCancellation()
            do {
                let text = try await request(scratch.wav(for: source, paddingFrames: padding), session.manifest.config)
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VellaError.message("A non-silent segment returned no text. Saved audio is retained for Retry.")
                }
                return text
            } catch VellaError.noSpeech { continue }
        }
        return nil // Keep standalone recognition and its conservative quiet policy.
    }
    /// A short final slice may be an undecodable clipped phoneme, not missing audio.
    /// Retry bounded alignments with its recognized predecessor; never classify by duration.
    private func retryTail(_ session: RecordingSession, at i: Int) async throws -> String? {
        let segments = session.manifest.segments
        guard i > 0, i == segments.count - 1 else { return nil }
        let tail = segments[i], previous = segments[i - 1]
        guard tail.frames > 0, tail.overlapFrames == 0, tail.seconds <= 1,
              previous.index + 1 == tail.index,
              let anchor = previous.text, !anchor.isEmpty,
              previous.frames + tail.frames - tail.overlapFrames + 16000 <= 30 * 16_000 else { return nil }
        let left = try verifiedPCM(session, previous), right = try verifiedPCM(session, tail)
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
            "tailRange": [tail.overlapFrames, tail.frames],
            "combinedSHA256": RecordingSession.digest(combined)]
        var attempts: [[String: Any]] = []
        func record(_ outcome: String, padding: Int, decodedContext: String? = nil) throws {
            var entry = provenance; entry["outcome"] = outcome; entry["paddingFrames"] = padding
            // Private recovery evidence only; never used as an insertion fallback.
            if let decodedContext { entry["decodedContext"] = decodedContext }
            attempts.append(entry)
            entry["attempts"] = attempts
            try session.durableWrite(JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                to: session.directory.appendingPathComponent(String(format: "context-retry-%06d.json", tail.index)))
        }
        for padding in [4000, 1600, 8000] {
            try record("requested", padding: padding)
            try Task.checkCancellation()
            let decoded: String
            do { decoded = try await request(scratch.wav(for: source, paddingFrames: padding), session.manifest.config) }
            catch VellaError.noSpeech { try record("noSpeech", padding: padding); continue }
            try Task.checkCancellation()
            guard let suffix = Self.contextSuffix(anchor: anchor, decoded: decoded) else {
                try record("anchorMismatch", padding: padding, decodedContext: decoded); continue
            }
            try record(suffix.isEmpty ? "recognizedAnchorOnly" : "recognizedSuffix", padding: padding)
            return suffix
        }
        return nil
    }
    /// A failed interior interval is retried only with both already-recognized neighbors.
    /// Exact full anchors protect checkpointed words; mismatch remains pending.
    private func retryInterior(_ session: RecordingSession, at i: Int) async throws -> String? {
        let segments = session.manifest.segments
        guard i > 0, i + 1 < segments.count, segments[i].text == nil else { return nil }
        let left = segments[i - 1], missing = segments[i], right = segments[i + 1]
        guard left.frames > 0, right.frames > 0, missing.frames > 0,
              missing.overlapFrames == 0, right.overlapFrames == 0,
              left.textThroughIndex == nil || left.textThroughIndex == left.index,
              left.index + 1 == missing.index, missing.index + 1 == right.index,
              let prefix = left.text, !prefix.isEmpty, let suffix = right.text, !suffix.isEmpty,
              left.frames + missing.frames + right.frames + 16000 <= 30 * 16000 else { return nil }
        var sources = [left, missing, right]
        if let through = right.textThroughIndex, through != right.index {
            // Only the exact final, adjacent, non-overlap tiny-tail group produced
            // above is supported. Metadata cannot authorize arbitrary extra coverage.
            guard i + 2 == segments.count - 1 else { return nil }
            let tail = segments[i + 2]
            guard tail.index == right.index + 1, through == tail.index,
                  tail.finalized, right.finalized, tail.frames > 0,
                  tail.overlapFrames == 0, tail.seconds <= 1,
                  tail.text == "", tail.textThroughIndex == nil else { return nil }
            sources.append(tail)
        }
        guard sources.reduce(0, { $0 + $1.frames }) + 16000 <= 30 * 16000 else { return nil }
        var combined = Data()
        for source in sources { combined.append(try verifiedPCM(session, source)) }
        let scratch = try RecordingSession(root: session.directory, config: session.manifest.config)
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let source = RecordingSession.Segment(index: 0, frames: combined.count / 4,
            peakRMS: sources.map(\.peakRMS).max() ?? 0, finalized: true,
            sha256: RecordingSession.digest(combined))
        try scratch.durableWrite(combined, to: scratch.directory.appendingPathComponent(source.filename))
        var attempts: [[String: Any]] = []
        func record(_ outcome: String, padding: Int, decoded: String? = nil) throws {
            var attempt: [String: Any] = ["paddingFrames": padding, "outcome": outcome]
            if let decoded { attempt["decodedContext"] = decoded }
            attempts.append(attempt)
            let entry: [String: Any] = ["version": 1, "indices": sources.map(\.index),
                "sourceSHA256": sources.map { $0.sha256! },
                "sourceRanges": sources.map { [0, $0.frames] },
                "combinedSHA256": source.sha256!, "attempts": attempts]
            try session.durableWrite(JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                to: session.directory.appendingPathComponent(String(format: "interior-context-retry-%06d.json", missing.index)))
        }
        for padding in [4000, 1600, 8000] {
            try Task.checkCancellation()
            try record("requested", padding: padding)
            let decoded: String
            do { decoded = try await request(scratch.wav(for: source, paddingFrames: padding), session.manifest.config) }
            catch VellaError.noSpeech { try record("noSpeech", padding: padding); continue }
            try Task.checkCancellation()
            guard let middle = Self.contextMiddle(prefix: prefix, suffix: suffix, decoded: decoded) else {
                try record("anchorMismatch", padding: padding, decoded: decoded); continue
            }
            try record(middle.isEmpty ? "recognizedAnchorsOnly" : "recognizedInterior", padding: padding)
            return middle
        }
        return nil
    }

    static func contextMiddle(prefix: String, suffix: String, decoded: String) -> String? {
        guard let remainder = contextSuffix(anchor: prefix, decoded: decoded) else { return nil }
        let words = remainder.split(whereSeparator: \.isWhitespace)
        let count = suffix.split(whereSeparator: \.isWhitespace).count
        guard count > 0, words.count >= count,
              contextSuffix(anchor: suffix, decoded: words.suffix(count).joined(separator: " ")) == "" else { return nil }
        return words.dropLast(count).joined(separator: " ")
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
            if let grouped = try await freshTailGroup(session, at: i) {
                // One atomic manifest write: never leave half of a joint decode cached.
                let originalTail = session.manifest.segments[i + 1]
                session.manifest.segments[i].text = grouped
                session.manifest.segments[i].textThroughIndex = session.manifest.segments[i + 1].index
                session.manifest.segments[i].quietSlices = 0
                session.manifest.segments[i + 1].text = ""
                session.manifest.segments[i + 1].textThroughIndex = nil
                session.manifest.segments[i + 1].quietSlices = 0
                do { try session.save() }
                catch {
                    session.manifest.segments[i] = segment
                    session.manifest.segments[i + 1] = originalTail
                    throw error
                }
                completed += segment.seconds + session.manifest.segments[i + 1].seconds
                // Joint requests/retries are not a single-segment warm observation.
                requestCount += 1
                continue
            }
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
                        session.manifest.segments[i].textThroughIndex = nil
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
            session.manifest.segments[i].textThroughIndex = nil
            session.manifest.segments[i].quietSlices = quietSlices
            try session.save() // Checkpoint before starting another request or any insertion.
            completed += segment.seconds
        }
        try Task.checkCancellation()
        // Later speech is now checkpointed, so both-side context cannot replace anchors.
        for i in session.manifest.segments.indices where session.manifest.segments[i].text == nil {
            try Task.checkCancellation()
            if let recovered = try await retryInterior(session, at: i) {
                let original = session.manifest.segments[i]
                session.manifest.segments[i].text = recovered
                session.manifest.segments[i].textThroughIndex = nil
                session.manifest.segments[i].quietSlices = 0
                do { try session.save() }
                catch { session.manifest.segments[i] = original; throw error }
            }
        }
        try Task.checkCancellation()
        guard session.manifest.segments.allSatisfy({ $0.text != nil }) else {
            _ = try session.savePartialTranscript()
            throw VellaError.unrecognizedAudio
        }
        let segments = session.manifest.segments
        // Resolved silence is a successful empty recording, not a recognition error.
        // This follows the all-resolved guard: missing audio can never become empty success.
        if segments.allSatisfy({ ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return try session.finalizeTranscript("")
        }
        let assembly = Task.detached(priority: .userInitiated) { try RecordingSession.assemble(segments) }
        let text = try await withTaskCancellationHandler(operation: { try await assembly.value }, onCancel: { assembly.cancel() })
        try Task.checkCancellation()
        return try session.finalizeTranscript(text)
    }
}
