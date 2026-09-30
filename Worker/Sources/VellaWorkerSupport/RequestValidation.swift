import Darwin
import Foundation

/// A request or checkpoint the helpers refuse.
public enum RequestError: Error { case invalid }

/// A request id as Python's uuid.UUID accepts it (hyphenless, braced and urn:uuid: forms too); the original text is
/// echoed. Both helpers.
public func requestIdentifier(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let stripped = s.replacingOccurrences(of: "urn:", with: "").replacingOccurrences(of: "uuid:", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        .replacingOccurrences(of: "-", with: "")
    guard stripped.utf8.count == 32, stripped.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
    return s
}

// MARK: Dictation helper: paths, JSON, audio

public func localPath(_ value: Any?) throws -> URL {
    guard let path = value as? String, path.hasPrefix("/"), !path.contains("\0"),
        let resolved = realpath(path, nil)
    else { throw RequestError.invalid }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}
// CPython JSON accepts these nonstandard constants. None is meaningful to
// model admission/request fields; use a truthy, non-admissible numeric sentinel.
// Do not replace quoted text (including paths or tokenizer configuration).
public func decodeJSON(_ data: Data) throws -> Any {
    let bytes = Array(data)
    var normalized = Data(); var index = 0; var quoted = false; var escaped = false
    let tokens = [Array("-Infinity".utf8), Array("Infinity".utf8), Array("NaN".utf8)]
    while index < bytes.count {
        let byte = bytes[index]
        if quoted {
            normalized.append(byte)
            if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            index += 1
        } else if byte == 34 {
            quoted = true; normalized.append(byte); index += 1
        } else if let token = tokens.first(where: { index + $0.count <= bytes.count && Array(bytes[index..<index + $0.count]) == $0 }) {
            normalized.append(49); index += token.count
        } else {
            normalized.append(byte); index += 1
        }
    }
    return try JSONSerialization.jsonObject(with: normalized, options: [.fragmentsAllowed])
}
public func pythonTruthy(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let number = value as? NSNumber { return number.doubleValue != 0 }
    if let string = value as? String { return !string.isEmpty }
    if let array = value as? [Any] { return !array.isEmpty }
    if let object = value as? [String: Any] { return !object.isEmpty }
    return true
}
public func jsonObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try decodeJSON(data) as? [String: Any] else { throw RequestError.invalid }
    return object
}
public struct Audio {
    public let samples: [Float]
    public var seconds: Double { Double(samples.count) / 16000 }
    public init(_ value: Any?) throws {
        let path = try localPath(value)
        let info = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, (44...2 * 1024 * 1024).contains(size) else { throw RequestError.invalid }
        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
        let d = [UInt8](try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data())
        guard d.count <= 2 * 1024 * 1024, d.count >= 44 else { throw RequestError.invalid }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func tag(_ i: Int) -> String { String(bytes: d[i..<i + 4], encoding: .ascii) ?? "" }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { throw RequestError.invalid }
        var cursor = 12; var format = false; var pcm: [Float]?
        let riffEnd = min(d.count, 8 + u32(4))
        while cursor + 8 <= riffEnd {
            let name = tag(cursor); let length = u32(cursor + 4); cursor += 8
            if name == "fmt " {
                guard length >= 16, cursor + length <= riffEnd else { throw RequestError.invalid }
                let code = u16(cursor)
                guard u16(cursor + 2) == 1, u32(cursor + 4) == 16000, u16(cursor + 14) == 16 else { throw RequestError.invalid }
                if code == 0xfffe {
                    guard length >= 40, Array(d[cursor + 24..<cursor + 40]) == [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113] else { throw RequestError.invalid }
                } else if code != 1 {
                    throw RequestError.invalid
                }
                format = true
            } else if name == "data" {
                let frames = length / 2
                guard format, frames > 0, frames <= 480000, cursor + frames * 2 <= riffEnd else { throw RequestError.invalid }
                pcm = stride(from: cursor, to: cursor + frames * 2, by: 2).map { Float(Int16(bitPattern: UInt16(u16($0)))) / 32768 }
                break
            }
            cursor += length + length % 2
        }
        guard let pcm else { throw RequestError.invalid }; samples = pcm
    }
}
