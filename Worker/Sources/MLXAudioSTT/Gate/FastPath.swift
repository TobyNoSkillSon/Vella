import MLX

/// A model with an optional optimized path. Conforming is all a model needs: the worker's `FastPathGate` self-tests
/// it against stock MLX in a child process before first use (persisted per model fingerprint, GPU family, macOS
/// build, worker version and `fastPathRevision`; failure is sticky), and the runtime fallback reruns a request on
/// stock when the optimized path throws or returns non-finite values (stock until the model is reloaded).
public protocol FastPathCapable: AnyObject {
    /// Enable or disable the optimized path. false = unsupported for this checkpoint; stock must stay active.
    func configureFastPath(enabled: Bool, component: String) -> Bool
    /// false when the last optimized run produced non-finite values.
    var fastPathFinite: Bool { get }
    /// Deterministic output compared stock against fast by the self-test (token IDs, not formatted text).
    func qualificationTokens(audio: MLXArray) -> [Int]
    /// Components the optimized path uses for this checkpoint, e.g. ["decoder": true, "encoder": false].
    var fastPathComponents: [String: Bool] { get }
    /// Self-test clips in the worker bundle (names without extension).
    var fastPathSelfTestClips: [String] { get }
    /// Changes whenever kernels, fused components or the clip set change, so an old persisted "fast" is not reused.
    static var fastPathRevision: String { get }
    /// Inexact components that can be dropped on their own (two-stage gate, lab/notes/GATE-REVISION.md). Each is
    /// self-tested within a tolerance on top of the exact path, and a failure disables only that component. Only
    /// components that would actually run on this checkpoint and Mac are listed.
    var fastPathTolerantComponents: [String] { get }
    /// Tolerant components the next `configureFastPath(enabled: true, …)` leaves off (a gate verdict or the self-test).
    var fastPathDisabledComponents: Set<String> { get set }
    /// Words of a qualification token sequence, for the tolerance self-test's word-edit count.
    func qualificationWords(_ tokens: [Int]) -> [String]
}

public extension FastPathCapable {
    var fastPathComponents: [String: Bool] { [:] }
    var fastPathSelfTestClips: [String] { ["clip-a", "clip-b", "clip-c", "clip-d", "clip-e"] }
    static var fastPathRevision: String { "" }
    var fastPathTolerantComponents: [String] { [] }
    var fastPathDisabledComponents: Set<String> { get { [] } set {} }
    /// One word per token: the strictest reading when a model does not say how its tokens form words.
    func qualificationWords(_ tokens: [Int]) -> [String] { tokens.map(String.init) }
}
