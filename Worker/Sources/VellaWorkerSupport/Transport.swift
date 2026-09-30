import Darwin
import Foundation

/// One line of the helpers' stdio protocol: sorted keys, unescaped slashes, every non-ASCII UTF-16 unit as `\uXXXX`
/// (Python's json.dumps(ensure_ascii=True)), then a newline. `fragmentsAllowed`: the dictation helper's writer
/// allows JSON fragments inside the object; the streaming helper's does not.
public func asciiJSONLine(_ object: [String: Any], fragmentsAllowed: Bool) throws -> Data {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if fragmentsAllowed { options.insert(.fragmentsAllowed) }
    let json = try JSONSerialization.data(withJSONObject: object, options: options)
    var ascii = ""
    for unit in String(decoding: json, as: UTF8.self).utf16 {
        if unit < 128 { ascii.append(Character(UnicodeScalar(unit)!)) } else { ascii += String(format: "\\u%04x", unit) }
    }
    ascii += "\n"
    return Data(ascii.utf8)
}

/// Writes all of `data` to `fd`; false when a write fails (the peer is gone).
public func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

/// Reads one protocol line (with its newline); nil at end of input. Only `limit + 1` bytes are ever kept, even if
/// the peer never sends a newline. On the first byte beyond `limit`, `onOverlong` runs; then `drainOverlong` true
/// reads on to the newline, discarding (the dictation helper answers "invalid" and continues, like Python's
/// buffered readline(limit + 1)); false returns at once (the streaming helper refuses the request and exits).
public func readProtocolLine(
    _ source: UnsafeMutablePointer<FILE>, limit: Int, drainOverlong: Bool,
    onOverlong: () -> Void = {}
) -> Data? {
    var data = Data(); var over = false
    while true {
        let c = fgetc(source)
        if c == EOF { return data.isEmpty && !over ? nil : data }
        if !over { data.append(UInt8(c)) }
        if !over && data.count > limit {
            over = true
            onOverlong()
            if !drainOverlong { return data }
        }
        if c == 10 { return data }
    }
}
