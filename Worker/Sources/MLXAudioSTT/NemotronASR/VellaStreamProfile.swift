import Foundation
import MLX

/// Opt-in streaming profile (`VELLA_STREAM_PROFILE=<file>`): counts host syncs and, in
/// profile mode only, splits time into mel / encoder / decode with extra evals.
/// Written as one JSON line when the session closes. Off by default; no cost when unset.
public enum VellaStreamProfile {
    public static let path = ProcessInfo.processInfo.environment["VELLA_STREAM_PROFILE"]
    public static var enabled: Bool { path != nil }
    public static var counters: [String: Double] = [:]
    @inline(__always) public static func add(_ key: String, _ value: Double = 1) {
        guard enabled else { return }
        counters[key, default: 0] += value
    }
    public static func time<T>(_ key: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let t = CFAbsoluteTimeGetCurrent(); let r = body()
        counters[key + "_ms", default: 0] += (CFAbsoluteTimeGetCurrent() - t) * 1000
        return r
    }
    public static func flush() {
        guard let path, !counters.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: counters, options: [.sortedKeys]) else { return }
        if let handle = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
            handle.seekToEndOfFile(); handle.write(data + Data([10])); try? handle.close()
        }
        counters = [:]
    }
}

/// Streaming optimisations, each on by default and bit-identical to the stock path
/// (event streams compared on v2 clips). `VELLA_NEMO_<NAME>=0` disables one;
/// `VELLA_FORCE_STOCK=1` disables all (diagnosis and reference runs). They are active only
/// after the load-time self-test (`FastPathGate`) passed for this model on this Mac.
public enum VellaNemotronOptions {
    public static func on(_ name: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return !FastPathGate.forcedStock && env["VELLA_NEMO_" + name] != "0"
    }
    public static let f32Weights = on("F32")
    public static let coalesce = on("COALESCE")
    public static let batchedDecode = on("BATCHED_DECODE")
    public static let positionCache = on("POSCACHE")
    public static let keyValueCache = on("KVCACHE")
    /// Fused conformer layer (not bit-identical: gated by the self-test tolerance and the quick-set WER gate).
    public static let fusedLayer = on("FUSED")
    /// Bumped whenever an optimization changes, so a persisted self-test verdict is not reused.
    public static let revision = "nemotron-stream-2"
    public static var anyEnabled: Bool { f32Weights || coalesce || batchedDecode || positionCache || keyValueCache || fusedLayer }
    public static var active: [String: Bool] {
        ["f32_weights": f32Weights, "coalesce": coalesce, "batched_decode": batchedDecode,
         "position_cache": positionCache, "kv_cache": keyValueCache, "fused_layer": fusedLayer && keyValueCache]
    }
}
