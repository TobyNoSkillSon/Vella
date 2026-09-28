import Foundation

/// Streaming optimisations, each on by default and bit-identical to the stock path
/// (event streams compared on v2 clips) except the fused layer. `VELLA_NEMO_<NAME>=0` disables one;
/// `VELLA_FORCE_STOCK=1` disables all (diagnosis and reference runs). They are active only
/// after the load-time self-test (`FastPathGate`) passed for this model on this Mac.
/// Foundation only, so a lab test compiles it standalone with a `FastPathGate.forcedStock` stub.
public enum VellaNemotronOptions {
    /// The requested switches, and what actually runs once their dependencies are applied.
    public struct Switches: Equatable {
        public var f32Weights, coalesce, batchedDecode, positionCache, keyValueCache, fusedLayer: Bool
        /// One frontend call per request instead of one per 20-ms block (needs `coalesce`; exact).
        public var melBatch: Bool
        public init(f32Weights: Bool, coalesce: Bool, batchedDecode: Bool, positionCache: Bool, keyValueCache: Bool, fusedLayer: Bool,
                    melBatch: Bool = false) {
            self.f32Weights = f32Weights; self.coalesce = coalesce; self.batchedDecode = batchedDecode
            self.positionCache = positionCache; self.keyValueCache = keyValueCache; self.fusedLayer = fusedLayer
            self.melBatch = melBatch
        }
        public init(environment: [String: String], forcedStock: Bool) {
            func on(_ name: String) -> Bool { !forcedStock && environment["VELLA_NEMO_" + name] != "0" }
            self.init(f32Weights: on("F32"), coalesce: on("COALESCE"), batchedDecode: on("BATCHED_DECODE"),
                      positionCache: on("POSCACHE"), keyValueCache: on("KVCACHE"), fusedLayer: on("FUSED"),
                      melBatch: on("MELBATCH"))
        }
        /// The fused layer runs only on the K/V-cache path, and only when its encoder could be built for this checkpoint.
        public func fusedActive(prepared: Bool = true) -> Bool { fusedLayer && keyValueCache && prepared }
        /// Status `optimizations`: every component as it actually runs.
        public func effective(fusedPrepared: Bool = true) -> [String: Bool] {
            ["f32_weights": f32Weights, "coalesce": coalesce, "batched_decode": batchedDecode,
             "position_cache": positionCache, "kv_cache": keyValueCache, "fused_layer": fusedActive(prepared: fusedPrepared),
             "mel_batch": melBatch && coalesce]
        }
        /// At least one component would run: the fused layer alone (K/V cache off) runs nothing.
        public var anyEnabled: Bool { effective().values.contains(true) }
    }
    public static let requested = Switches(environment: ProcessInfo.processInfo.environment, forcedStock: FastPathGate.forcedStock)
    public static let f32Weights = requested.f32Weights
    public static let coalesce = requested.coalesce
    public static let batchedDecode = requested.batchedDecode
    public static let positionCache = requested.positionCache
    public static let keyValueCache = requested.keyValueCache
    /// Fused conformer layer (not bit-identical: gated by the self-test tolerance and the quick-set WER gate).
    public static let fusedLayer = requested.fusedLayer
    /// Per-request mel frontend (the session only defers the mel when the worker coalesces requests).
    public static let melBatch = requested.melBatch && requested.coalesce
    /// Bumped whenever an optimization or its self-test changes, so a persisted self-test verdict is not reused.
    public static let revision = "nemotron-stream-4"
    public static var anyEnabled: Bool { requested.anyEnabled }
    /// The requested components with their dependencies applied (before the fused encoder is built).
    public static var active: [String: Bool] { requested.effective() }

    /// Worker status (engine, reason, optimizations) for a streaming model. `fusedPrepared`: the fused encoder was
    /// actually built; a checkpoint it does not support runs the unfused layers and must not report the fused layer.
    public static func report(optimized: Bool, fusedPrepared: Bool, stockReason: String,
                              switches: Switches = requested) -> (String, String, [String: Bool]) {
        guard optimized else { return ("mlx", stockReason, switches.effective().mapValues { _ in false }) }
        return ("optimized", switches.fusedActive(prepared: fusedPrepared)
                ? "Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance)."
                : "Self-tested on this Mac against stock MLX (identical streamed text); output is bit-identical by construction.",
                switches.effective(fusedPrepared: fusedPrepared))
    }
}
