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
}

public extension FastPathCapable {
    var fastPathComponents: [String: Bool] { [:] }
    var fastPathSelfTestClips: [String] { ["clip-a", "clip-b", "clip-c", "clip-d", "clip-e"] }
    static var fastPathRevision: String { "" }
}

/// ParakeetModel's members live in Parakeet/ (vo-parakeet); only the conformance is declared here.
extension ParakeetModel: FastPathCapable {}
