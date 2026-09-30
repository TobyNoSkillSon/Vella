import Foundation
import Darwin
import MLX
import MLXAudioSTT
import VellaWorkerSupport

/// Keeps one loaded streaming model across sessions (Keep Hot). A session that ends with a clean `done` reply
/// leaves the model loaded for the next `start` with the same path; any error still ends the process (fail closed).
final class StreamingModelCache {
    private(set) var path: URL?
    private(set) var native: (any StreamingNative)?
    private(set) var loadSeconds: Double?
    let loader: (URL) throws -> any StreamingNative
    init(loader: @escaping (URL) throws -> any StreamingNative) { self.loader = loader }
    func native(for url: URL) throws -> any StreamingNative {
        if let native, path == url { try native.reset(); return native }
        close()
        if FaultHooks.loadFails(url) { throw StreamingFailure.inference }
        let start = ProcessInfo.processInfo.systemUptime
        let loaded = try loader(url)
        native = loaded; path = url; loadSeconds = ProcessInfo.processInfo.systemUptime - start
        return loaded
    }
    func close() { native?.close(); native = nil; path = nil; loadSeconds = nil }
    func status(_ event: String) -> [String: Any] {
        var memory: [String: Any] = ["mlx_active_mb": Double(Memory.activeMemory) / 1e6, "mlx_cache_mb": Double(Memory.cacheMemory) / 1e6]
        if let footprint = processFootprintBytes() { memory["footprint_mb"] = Double(footprint) / 1e6 }
        let hooks = FastPathGate.reportedEnvironment()
        var object: [String: Any] = [
            "worker": "streaming", "pid": Int(getpid()), "version": FastPathGate.version, "event": event, "model": path?.path ?? NSNull(),
            "engine": native.map { $0.engine.0 } ?? NSNull(),
            "engine_reason": native.map { $0.engine.1 } ?? NSNull(),
            "optimizations": native?.engine.2 ?? [String: Bool](), "load_s": loadSeconds ?? NSNull(), "memory": memory,
            "recipe": FastPathGate.recipe.rawValue,
        ]
        if !hooks.isEmpty { object["test_hooks"] = hooks }
        return object
    }
}

// Duplicated descriptor isolates native-library diagnostics from the JSON stream.
