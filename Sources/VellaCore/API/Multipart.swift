import Foundation

// MARK: Multipart

public struct MultipartPart: Equatable {
    public var name: String
    public var filename: String?
    public var contentType: String?
    /// Byte range of the part's body within the parsed data.
    public var range: Range<Int>
}

public enum Multipart {
    /// The boundary parameter of a multipart Content-Type, unquoted; nil when absent or invalid (RFC 2046: 1–70 chars).
    public static func boundary(_ contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return (1...70).contains(value.utf8.count) ? value : nil
        }
        return nil
    }

    /// Splits a multipart/form-data body into parts (ranges into `data`, no copies). Throws on malformed framing.
    public static func parse(_ data: Data, boundary: String) throws -> [MultipartPart] {
        let bad = APIError(400, "malformed multipart/form-data body")
        let base = data.startIndex
        let delimiter = Data("--\(boundary)".utf8)
        let separator = Data("\r\n--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8), blank = Data("\r\n\r\n".utf8)
        // The first delimiter starts the body or follows a preamble line.
        var cursor: Int
        if data.starts(with: delimiter) { cursor = base + delimiter.count }
        else if let first = data.range(of: separator) { cursor = first.upperBound }
        else { throw bad }
        var parts: [MultipartPart] = []
        while true {
            guard cursor + 2 <= data.endIndex else { throw bad }
            if data[cursor] == UInt8(ascii: "-"), data[cursor + 1] == UInt8(ascii: "-") { return parts }
            // Transport padding (spaces/tabs) may precede the CRLF after a delimiter.
            while cursor < data.endIndex, data[cursor] == 0x20 || data[cursor] == 0x09 { cursor += 1 }
            guard data[cursor..<min(data.endIndex, cursor + 2)] == crlf else { throw bad }
            cursor += 2
            guard let headEnd = data.range(of: blank, in: cursor..<data.endIndex), headEnd.lowerBound - cursor <= 16 * 1024 else { throw bad }
            let headText = String(decoding: data[cursor..<headEnd.lowerBound], as: UTF8.self)
            guard let next = data.range(of: separator, in: headEnd.upperBound..<data.endIndex) else { throw bad }
            var name: String?, filename: String?, type: String?
            for line in headText.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw bad }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "content-disposition" {
                    let params = dispositionParameters(value)
                    name = params["name"]; filename = params["filename"]
                } else if key == "content-type" { type = value }
            }
            guard let name else { throw bad }
            parts.append(MultipartPart(name: name, filename: filename, contentType: type, range: (headEnd.upperBound - base)..<(next.lowerBound - base)))
            cursor = next.upperBound
            if parts.count > 64 { throw APIError(400, "too many multipart fields") }
        }
    }

    /// `form-data; name="file"; filename="a b.wav"` → ["name": "file", "filename": "a b.wav"]. Quoted values may
    /// contain semicolons and escaped quotes.
    static func dispositionParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var chars = Array(value)[...]
        // Skip the disposition type.
        while let c = chars.first, c != ";" { chars = chars.dropFirst() }
        while !chars.isEmpty {
            chars = chars.drop { $0 == ";" || $0 == " " || $0 == "\t" }
            var key = ""
            while let c = chars.first, c != "=", c != ";" { key.append(c); chars = chars.dropFirst() }
            guard chars.first == "=" else { continue }
            chars = chars.dropFirst()
            var val = ""
            if chars.first == "\"" {
                chars = chars.dropFirst()
                while let c = chars.first {
                    chars = chars.dropFirst()
                    if c == "\\", let n = chars.first { val.append(n); chars = chars.dropFirst(); continue }
                    if c == "\"" { break }
                    val.append(c)
                }
            } else {
                while let c = chars.first, c != ";" { val.append(c); chars = chars.dropFirst() }
                val = val.trimmingCharacters(in: .whitespaces)
            }
            result[key.trimmingCharacters(in: .whitespaces).lowercased()] = val
        }
        return result
    }
}
