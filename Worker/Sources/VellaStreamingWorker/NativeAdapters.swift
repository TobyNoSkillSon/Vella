import Foundation
import MLX
import MLXAudioSTT

final class NemotronNative: StreamingNative {
    var text = ""
    private var model: NemotronASRModel?
    private var session: VellaNemotronSession?
    /// Optimized path active: the gate qualified it for this model on this Mac and it has not failed at runtime.
    private(set) var optimized = false
    private var stockReason: String
    /// Self-test child: failures propagate (no fallback, no injected faults) so they count as evidence.
    var strict = false
    private(set) var sawNonFinite = false
    private var deferred = false
    private let path: URL
    private var gated = false
    /// Set when a fallback replay disagreed with text already committed; taken once by the session (reply flag).
    private var incompleteFlag = false
    // Runtime fallback journal: every push since the last reset, in the stock grouping (one entry per 20-ms block),
    // plus all text produced since then, so a failed optimized session can be replayed on stock mid-utterance.
    private var journal: [([Float], Bool)] = []
    private var journalSamples = 0
    private var replayable = true
    private var produced = ""
    /// ~10 min of 16-kHz audio (38 MB). A longer unbroken utterance can no longer be replayed; a runtime failure
    /// past that point ends the session with an error (as before the fallback existed).
    static let journalLimit = 16_000 * 600
    private static let optimizedFault = ProcessInfo.processInfo.environment["VELLA_TEST_OPTIMIZED_FAULT"].flatMap { $0.isEmpty ? nil : $0 }
    private static var faultFired = false

    /// `gate` false loads stock only (the self-test child); true asks `FastPathGate` (child-process self-test,
    /// persisted verdict) whether the optimized path may run.
    init(_ path: URL, gate: Bool = true) throws {
        self.path = path
        model = try NemotronASRModel.fromDirectory(path)
        VellaNemotronNumerics.useReferencePositionTable(model!)
        if !VellaNemotronOptions.anyEnabled {
            stockReason = FastPathGate.forcedStock ? "Stock path forced for diagnosis (VELLA_FORCE_STOCK)." : "Every streaming optimization is disabled by environment."
        } else if !gate {
            stockReason = "Self-test reference (stock MLX)."
        } else {
            gated = true
            switch FastPathGate.qualify(path, revision: VellaNemotronOptions.revision, requiredFamily: nil) {
            case .fast: stockReason = ""; enableOptimized()
            case .stock(let reason): stockReason = reason
            }
        }
        try reset()
    }
    func enableOptimized() {
        guard !optimized, let model else { return }
        if VellaNemotronOptions.f32Weights { VellaNemotronNumerics.convertFloat32Weights(model) }
        optimized = true
    }
    private func disableOptimized(_ reason: String) {
        guard optimized, let model else { return }
        if VellaNemotronOptions.f32Weights { VellaNemotronNumerics.restoreBF16Weights(model) }
        optimized = false; stockReason = reason
    }
    var engine: (String, String, [String: Bool]) {
        guard optimized else { return ("mlx", stockReason, VellaNemotronOptions.active.mapValues { _ in false }) }
        return ("optimized", "Self-tested on this Mac against stock MLX (identical streamed text); output is bit-identical by construction.", VellaNemotronOptions.active)
    }
    var nonFinite: Bool { session?.nonFinite ?? false }
    func takeIncomplete() -> Bool { defer { incompleteFlag = false }; return incompleteFlag }
    func reset() throws {
        VellaStreamProfile.flush()
        session = nil; text = ""; deferred = false
        journal.removeAll(); journalSamples = 0; replayable = true; produced = ""
        session = try VellaNemotronSession(model: model!, optimized: optimized)
        Memory.clearCache()
    }
    private func record(_ samples: [Float], final: Bool) {
        guard replayable else { return }
        journalSamples += samples.count
        if journalSamples > Self.journalLimit { replayable = false; journal.removeAll(); return }
        journal.append((samples, final))
    }
    private func append(_ piece: String) { text += piece; if replayable { produced += piece } }
    func push(_ samples: [Float], final: Bool) throws {
        record(samples, final: final)
        guard optimized else { append(try session!.push(samples, final: final)); return }
        try guarded {
            // Coalesce: the frontend ingests every 20-ms block as before (lazy graph);
            // the encoder, decoder and host sync run once per request in flush().
            if VellaNemotronOptions.coalesce && !final { session!.ingest(samples); deferred = true; return }
            _ = try flushOptimized()
            append(try session!.push(samples, final: final))
        }
    }
    func flush() throws -> Bool {
        guard deferred else { return false }
        var pushed = false
        try guarded { pushed = try flushOptimized() }
        return pushed
    }
    private func flushOptimized() throws -> Bool {
        guard deferred else { return false }
        deferred = false
        append(try session!.push([], final: false))
        return true
    }
    /// Runtime fallback: the optimized path threw or produced non-finite values → switch the model to stock for
    /// good (until reload) and replay this utterance's audio on a fresh stock session; the text the caller has not
    /// yet taken continues from the stock transcript. Stock failing too propagates the error.
    private func guarded(_ body: () throws -> Void) throws {
        do {
            try withError { try body() }
            if nonFinite { sawNonFinite = true }
            if !strict, Self.optimizedFault != nil, !Self.faultFired, journalSamples >= 48_000 {
                Self.faultFired = true
                if Self.optimizedFault == "throw" { throw StreamingFailure.inference }
            }
            if nonFinite || (!strict && Self.faultFired && Self.optimizedFault == "nonfinite" && optimized) { throw StreamingFailure.inference }
        } catch {
            guard optimized, replayable, !strict else { throw error }
            // The bytes of this utterance the app has already taken (drained as committed text).
            let consumed = Array(produced.utf8.prefix(max(0, produced.utf8.count - text.utf8.count)))
            disableOptimized(Self.faultFired ? "Test fault injected into the optimized streaming path; stock MLX until the model is reloaded."
                             : "The optimized streaming path failed at runtime; stock MLX until the model is reloaded.")
            deferred = false
            let entries = journal
            session = try VellaNemotronSession(model: model!, optimized: false)
            var replayed = ""
            try withError { for (samples, final) in entries { replayed += try session!.push(samples, final: final) } }
            if let rest = ReplayBoundary.unconsumed(consumed: consumed, replayed: replayed) {
                // The replay starts with exactly what was consumed: continue with the unseen suffix.
                produced = replayed
                text = rest
            } else {
                // The replay disagrees with committed text: no safe boundary. Never duplicate or garble: withhold this
                // utterance's replay, flag the session incomplete (the app keeps the audio and stops live insertion;
                // Retry replays the saved audio), and continue on a fresh stock session. The verdict is persisted as
                // stock so that Retry, in a new worker, runs stock and completes.
                incompleteFlag = true
                session = try VellaNemotronSession(model: model!, optimized: false)
                journal.removeAll(); journalSamples = 0; produced = ""; text = ""
                if gated, let url = try? FastPathGate.statusURL(path, revision: VellaNemotronOptions.revision) { FastPathGate.persist("stock", to: url) }
            }
        }
    }
    func close() { VellaStreamProfile.flush(); session = nil; model = nil; journal.removeAll(); Stream.gpu.synchronize(); Memory.clearCache() }
}
func loadStreamingNative(_ path: URL) throws -> any StreamingNative {
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("config.json"))) as! [String: Any]
    if config["model_type"] as? String == "nemotron_asr" { return try NemotronNative(path) }
    return try VoxtralNative(path)
}
final class VoxtralNative: StreamingNative {
    var text = ""
    private var model: VoxtralRealtimeModel?
    private var session: VellaVoxtralSession?
    private var pending: [Float] = []
    init(_ path: URL) throws { model = try VoxtralRealtimeModel.fromDirectory(path); try reset() }
    func reset() throws {
        session = nil; text = ""; pending.removeAll()
        session = VellaVoxtralSession(model: model!)
        Memory.clearCache()
    }
    func push(_ samples: [Float], final: Bool) throws {
        guard let session, !session.done else { throw StreamingFailure.inference }
        pending += samples
        if !final && pending.count < 1280 { return }
        try session.feed(pending, final: final); pending.removeAll(keepingCapacity: true)
        text += session.step()
        if final {
            for _ in 0..<32 { if session.done { break }; text += session.step() }
            guard session.done else { throw StreamingFailure.inference }
        } else if session.done { throw StreamingFailure.inference }
    }
    func close() { session = nil; model = nil; pending.removeAll(); Stream.gpu.synchronize(); Memory.clearCache() }
}
