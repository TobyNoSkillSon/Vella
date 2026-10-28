import Foundation
import VellaWire

/// A speech model family as the app sees it. The runtime (loader, fast paths, kernels, self-test) lives in the worker,
/// `Worker/Sources/MLXAudioSTT/<Model>/`; the app never links it and knows a model only through its descriptor.
/// Adding a model: a runtime folder in the worker, a descriptor folder here (one line in `ModelRegistry.all`) and its
/// families in Resources/models.json.
public struct ModelDescriptor: Equatable, Sendable {
    /// The checkpoint architecture (`checkpointArchitecture`); the worker's admission uses the same vocabulary.
    public let architecture: Architecture
    public let mode: RecognitionMode
    /// Dictation recordings of this model are cut at a pause only after this many seconds (nil: the default policy).
    public let preferredSegmentSeconds: Double?
    /// Local speed calibration applies (dictation models).
    public let calibratable: Bool
    /// The Resources/models.json families that run on this architecture.
    public let catalogFamilies: [String]
    /// What Exact and Fast mean for this model, when they differ in a way the general switch tooltip does not say: one
    /// line under it (Nemotron 3.5 Transcribe: plain decoding vs draft-and-verify). Nil: the general tooltip only.
    public var switchHelp: String? = nil
    /// The layers a derived tier quantizes when the architecture's loader applies its own mix (the Precision cell's
    /// flavour while benchmarks.json has no recipe for it). Nil: the catalog's recipe says it.
    public var tierRecipes: [ModelTier: String]? = nil
}
