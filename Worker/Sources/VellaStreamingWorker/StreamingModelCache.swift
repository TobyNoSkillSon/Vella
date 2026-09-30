import Foundation
import Darwin
import MLX
import MLXAudioSTT
import VellaWorkerSupport
import VellaWire

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
        let memory = HelperStatus.Memory(
            footprintMB: processFootprintBytes().map { Double($0) / 1e6 },
            mlxActiveMB: Double(Memory.activeMemory) / 1e6, mlxCacheMB: Double(Memory.cacheMemory) / 1e6)
        return HelperStatus(
            worker: .streaming, pid: Int(getpid()), version: FastPathGate.version, event: event, model: path?.path,
            engine: native.map { $0.engine.0 }, engineReason: native.map { $0.engine.1 },
            optimizations: native?.engine.2 ?? [:], loadSeconds: loadSeconds, memory: memory,
            recipe: FastPathGate.recipe.rawValue, testHooks: FastPathGate.reportedEnvironment()
        ).jsonObject
    }
}

// Duplicated descriptor isolates native-library diagnostics from the JSON stream.
