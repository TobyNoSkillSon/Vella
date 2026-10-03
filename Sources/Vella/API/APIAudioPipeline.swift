import Foundation
import VellaCore

/// One decoder owns its writer/session. One consumer owns the transcript/session. Only immutable closed PCM crosses
/// this queue. Backpressure blocks the decoder, never the main actor. Cancellation/error wakes both ends.
private final class APIAudioQueue: @unchecked Sendable {
    struct Piece {
        let segment: RecordingSession.Segment
        let audio: Data
        let voiced: Bool
    }
    private let condition = NSCondition()
    private var pieces: [Piece] = []
    private var waiter: CheckedContinuation<Piece?, Error>?
    private var ended = false
    private var failure: Error?
    private let capacity = 3

    func send(_ piece: Piece) throws {
        condition.lock()
        while pieces.count >= capacity && !ended { condition.wait() }
        if ended {
            let error = failure ?? CancellationError()
            condition.unlock()
            throw error
        }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: piece)
        } else {
            pieces.append(piece)
            condition.unlock()
        }
    }
    func next() async throws -> Piece? {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            if let failure {
                condition.unlock()
                continuation.resume(throwing: failure)
            } else if !pieces.isEmpty {
                let piece = pieces.removeFirst()
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: piece)
            } else if ended {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                condition.unlock()
            }
        }
    }
    func finish(_ error: Error? = nil) {
        condition.lock()
        ended = true
        if let error { failure = error; pieces.removeAll() }
        let waiter = self.waiter
        self.waiter = nil
        condition.broadcast()
        condition.unlock()
        if let waiter {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }
}

extension APIAudio {
    /// Decode and recognize concurrently. A bounded final lookbehind preserves the *existing* tailMerge rule,
    /// including arbitrarily many quiet 5 s segments and its evenly re-split final pair. A merge can consume at most
    /// twice (maximum + slack); older audio is irrevocably outside that unit. No model work starts before header
    /// validation (the three-hour cap), and no producer task survives a return/throw.
    @MainActor static func overlapping(
        _ file: URL, root: URL, config: Configuration, runner: SessionTranscriber,
        maxSeconds: Double = apiMaxAudioSeconds, prepare: () async throws -> Void = {}
    ) async throws -> (RecordingSession, Double) {
        let seconds = try duration(file)
        guard seconds > 0 else { throw APIError(400, "The audio file contains no samples.", param: "file", code: "invalid_audio") }
        guard seconds <= maxSeconds else {
            throw APIError(
                400, String(format: "The audio is %.0f min long; Vella transcribes up to %.0f min per request. Split it and send the parts.", seconds / 60, maxSeconds / 60),
                param: "file", code: "audio_too_long")
        }
        let session = try RecordingSession(root: root, config: config, transient: true)
        session.manifest.state = "ready"
        let queue = APIAudioQueue()
        let policy = SegmentedPCMWriter.Policy.forModel(config.model)
        let decode = Task.detached(priority: .userInitiated) {
            do {
                let (producer, duration) = try segment(file, root: root, config: config, maxSeconds: maxSeconds) { producer, closed in
                    try Task.checkCancellation()
                    // Keep the immediate predecessor on the producer for exact redundant-overlap validation.
                    if closed.frames == closed.overlapFrames { try producer.verifyRedundantTail(at: closed.index) }
                    let voiced =
                        try closed.frames > closed.overlapFrames
                        && RecordingSession.hasVoicedBlock(
                            try producer.samples(for: closed), from: closed.overlapFrames, threshold: policy.silenceRMS)
                    try queue.send(.init(segment: closed, audio: try producer.transientAudio(for: closed), voiced: voiced))
                    producer.releaseTransient(before: closed.index)
                }
                try? FileManager.default.removeItem(at: producer.directory)
                queue.finish()
                return duration
            } catch {
                queue.finish(error)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            do {
                try await prepare()
                let lookbehind = 2 * (policy.maximumSeconds + policy.mergeSlackSeconds)
                var pending = 0
                var barrier = 0
                var heldSeconds = 0.0
                while let piece = try await queue.next() {
                    try Task.checkCancellation()
                    session.receiveTransient(piece.segment, audio: piece.audio)
                    heldSeconds += piece.segment.seconds
                    // A later voiced cut with >= minimum new audio stops every possible final-tail merge before
                    // its predecessor. Typically this releases the first cut as soon as the second cut is ready;
                    // an all-quiet run instead uses the fixed upper bound below.
                    if piece.voiced && piece.segment.seconds >= policy.minimumSeconds { barrier = piece.segment.index }
                    let begin = pending
                    while pending < session.manifest.segments.count,
                        pending < barrier || heldSeconds - session.manifest.segments[pending].seconds > lookbehind
                    {
                        heldSeconds -= session.manifest.segments[pending].seconds
                        pending += 1
                    }
                    if pending > begin {
                        _ = try await runner.run(session, available: begin..<pending)
                        session.releaseTransient(before: pending)
                    }
                }
                let duration = try await decode.value
                try Task.checkCancellation()
                _ = try await runner.run(session)
                return (session, duration)
            } catch {
                // Wake a producer blocked on a full queue, cancel conversion between buffers, then join it before
                // deleting anything. The consumer's worker is awaited in this task, so there is no orphan request.
                queue.finish(error)
                decode.cancel()
                _ = try? await decode.value
                try? FileManager.default.removeItem(at: session.directory)
                throw error
            }
        } onCancel: {
            queue.finish(CancellationError())
            decode.cancel()
        }
    }
}
