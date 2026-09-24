// QA only: retain weights between clips, just like streaming_benchmark_worker.py.
// Recognition runs through the SAME production Session and native adapters.
import Foundation
import MLX
@main struct Probe {
    static func main() throws {
        Memory.cacheLimit = 64 * 1024 * 1024
        var resident: (any StreamingNative)?
        var residentPath: URL?
        func fresh() -> StreamingSession {
            StreamingSession { path in
                if path != residentPath {
                    resident?.close(); resident = nil
                    resident = try loadStreamingNative(path); residentPath = path
                } else { try resident?.reset() }
                return resident!
            }
        }
        var session = fresh()
        defer { resident?.close() }
        while let line = readLine() {
            let request = try? JSONSerialization.jsonObject(with: Data(line.utf8))
            let reply = try withError { session.reply(request) }
            let bytes = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            FileHandle.standardOutput.write(bytes + Data([10]))
            if (request as? [String: Any])?["op"] as? String == "start" { Memory.peakMemory = 0 }
            if session.done {
                var metrics: [String: Any] = processMemory()
                metrics["peakMLXBytes"] = Memory.peakMemory
                metrics["activeMLXBytes"] = Memory.activeMemory
                metrics["cacheMLXBytes"] = Memory.cacheMemory
                if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]) {
                    FileHandle.standardError.write(data + Data([10]))
                }
                guard reply["done"] as? Bool == true else { break }
                session.native = nil; session.close(); session = fresh()
            }
        }
    }
}
