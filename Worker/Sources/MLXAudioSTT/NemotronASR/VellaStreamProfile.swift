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
