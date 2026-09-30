import Darwin
import Foundation
import VellaWorkerSupport

/// The dictation helper's line policy: at most `maximumLine` bytes; an overlong line arms the request deadline and is
/// drained to its newline (the request is then answered "invalid").
func readBoundedLine(_ source: UnsafeMutablePointer<FILE>) -> Data? {
    readProtocolLine(source, limit: maximumLine, drainOverlong: true) { alarm(120) }
}

/// One reply line (JSON fragments allowed inside the object).
func responseBytes(_ response: [String: Any]) throws -> Data { try asciiJSONLine(response, fragmentsAllowed: true) }
