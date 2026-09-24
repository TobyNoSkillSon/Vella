import Foundation
import Darwin

/// Matches Python buffered readline(MAX_LINE + 1), including draining one overlong line.
/// Only one bounded buffer survives, even if the peer never sends a newline.
func readBoundedLine(_ source: UnsafeMutablePointer<FILE>) -> Data? {
    var data = Data(); var over = false
    while true {
        let c = fgetc(source)
        if c == EOF { return data.isEmpty && !over ? nil : data }
        if !over { data.append(UInt8(c)) }
        if !over && data.count > maximumLine { over = true; alarm(120) }
        if c == 10 { return data }
    }
}

/// JSON protocol is ASCII-only, matching json.dumps(ensure_ascii=True).
func responseBytes(_ response: [String: Any]) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    var ascii = ""
    for unit in String(decoding: json, as: UTF8.self).utf16 {
        if unit < 128 { ascii.append(Character(UnicodeScalar(unit)!)) }
        else { ascii += String(format: "\\u%04x", unit) }
    }
    ascii += "\n"
    return Data(ascii.utf8)
}
