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
@main struct StreamingMain {
    static func main() {
        let output = dup(STDOUT_FILENO)
        let sink = open("/dev/null", O_WRONLY)
        guard output >= 0, sink >= 0 else { exit(1) }
        dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO); Darwin.close(sink)
        guard installOfflineSandbox() else { exit(1) }
        guard FastPathGate.applyDeviceOverride() else { exit(1) }
        Memory.cacheLimit = 64 * 1024 * 1024
        // FastPathGate's child: stock vs optimized streaming self-test, verdict in the exit status.
        if CommandLine.arguments.dropFirst().first == "fast-selftest" {
            exit(StreamingSelfTest.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        }
        let cache = StreamingModelCache { path in try withError { try loadStreamingNative(path) } }
        func newSession() -> StreamingSession { StreamingSession { path in try cache.native(for: path) } }
        var session = newSession()
        defer { cache.close(); Darwin.close(output) }
        let watchdog = StreamingWatchdog(output: output)
        while true {
            // One autorelease pool per request: this loop never returns to a run loop, so every autoreleased
            // Foundation object (JSONSerialization dictionaries, the base64 PCM string, reply data) otherwise
            // stays alive for the life of the process: ~8 MB of heap per audio minute before this pool.
            let proceed: Bool = autoreleasepool {
                // The deadline covers handling a request, not waiting for one: a hot worker idles between sessions.
                // At most 10,000 bytes; a longer line is refused (and ends the process), never drained.
                // stdin EOF: the app is gone or retired this worker.
                guard let line = readProtocolLine(stdin, limit: 10000, drainOverlong: false) else { return false }
                watchdog.arm()
                let value = line.count <= 10000 && line.last == 10 ? try? JSONSerialization.jsonObject(with: line) : nil
                let request = value as? [String: Any]
                let identifier = requestIdentifier(request?["id"])
                watchdog.identify(identifier)
                // Residency control between sessions: preload or drop the model without starting a session.
                if let request, let identifier, session.native == nil, let op = request["op"] as? String, op == "load" || op == "unload" {
                    var reply: [String: Any] = ["id": identifier, "frames": 0]
                    if op == "load", Set(request.keys) == ["id", "op", "model"] {
                        do {
                            _ = try withError { try cache.native(for: try streamingModelPath(request["model"])) }
                            watchdog.write(["status": cache.status("load")]); reply["loaded"] = true
                        } catch {
                            cache.close(); watchdog.write(["status": cache.status("load-failed")])
                            reply["error"] = "The streaming model failed to load."
                        }
                    } else if op == "unload", Set(request.keys) == ["id", "op"] {
                        cache.close(); watchdog.write(["status": cache.status("unload")]); reply["unloaded"] = true
                    } else { reply["error"] = "Invalid local streaming request." }
                    watchdog.disarm(); watchdog.write(reply)
                    if reply["error"] != nil { return false }
                    return true
                }
                let before = cache.path, engineBefore = cache.native?.engine.0
                let reply: [String: Any]
                do { reply = try withError { session.reply(value) } }
                catch { session.done = true; reply = ["id": identifier as Any? ?? NSNull(), "error": "Local streaming transcription failed."] }
                watchdog.disarm()
                if cache.path != before { watchdog.write(["status": cache.status(cache.path == nil ? "unload" : "load")]) }
                else if cache.native?.engine.0 != engineBefore { watchdog.write(["status": cache.status("fallback")]) }
                watchdog.write(reply)
                if session.done {
                    // A clean finish keeps the model hot for the next session; any failure ends the process.
                    guard reply["error"] == nil, reply["done"] as? Bool == true else { return false }
                    session = newSession()
                }
                return true
            }
            if !proceed { break }
        }
    }
}
