// Only linked by CPU wire checks, never a production package target.
import Foundation
import Darwin
enum Memory { static var cacheLimit = 0 }
func withError<T>(_ body: () throws -> T) throws -> T { try body() }
final class CPUWireNative: StreamingNative {
    var text = ""
    func push(_ samples: [Float], final: Bool) throws {
        if samples.first == 16 { sleep(5) }
        if !samples.isEmpty && samples.contains(where: { $0 != 0 }) { text += " naïve 😀" }
    }
    func reset() throws { text = "" }
    func close() {}
}
func loadStreamingNative(_ path: URL) throws -> any StreamingNative { CPUWireNative() }
