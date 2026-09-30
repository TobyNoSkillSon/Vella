import Foundation

/// A speech model family as the app sees it. The runtime (loader, fast paths, kernels, self-test) lives in the worker,
/// `Worker/Sources/MLXAudioSTT/<Model>/`; the app never links it and knows a model only through its descriptor.
/// Adding a model: a runtime folder in the worker, a descriptor folder here (one line in `ModelRegistry.all`) and its
/// families in Resources/models.json.
public struct ModelDescriptor: Equatable, Sendable {
    /// The checkpoint architecture: config.json's `model_type`, or "parakeet" for the NeMo TDT target
    /// (`checkpointArchitecture`). The worker's admission uses the same names.
    public let architecture: String
    public let mode: RecognitionMode
    /// Dictation recordings of this model are cut at a pause only after this many seconds (nil: the default policy).
    public let preferredSegmentSeconds: Double?
    /// Local speed calibration applies (dictation models).
    public let calibratable: Bool
    /// The Resources/models.json families that run on this architecture.
    public let catalogFamilies: [String]
}
