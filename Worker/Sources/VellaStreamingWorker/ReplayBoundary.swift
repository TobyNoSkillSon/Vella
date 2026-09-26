import Foundation

/// Where a stock replay may continue after the optimized streaming path failed mid-utterance.
/// Foundation only, so a lab test compiles it standalone (lab/tests/review/replay_boundary_test.swift).
enum ReplayBoundary {
    /// `consumed`: the utterance's text the app has already taken (committed); `replayed`: the stock replay of the
    /// whole utterance. Returns the replay text the app has not seen yet, or nil when the replay does not start with
    /// exactly the consumed bytes: then no boundary is safe (slicing would garble, re-emitting would duplicate).
    static func unconsumed(consumed: [UInt8], replayed: String) -> String? {
        let bytes = Array(replayed.utf8)
        guard bytes.count >= consumed.count, bytes.starts(with: consumed) else { return nil }
        return String(decoding: bytes[consumed.count...], as: UTF8.self)
    }
}
