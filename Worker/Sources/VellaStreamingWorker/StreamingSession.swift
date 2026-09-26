import Foundation

// Mirrors Resources/streaming_worker.py. Model code never owns transport state.
enum StreamingFailure: Error { case invalid, inference }
protocol StreamingNative: AnyObject {
    var text: String { get set }
    func push(_ samples: [Float], final: Bool) throws
    func reset() throws
    func close()
    /// Push audio a coalescing adapter deferred; true when text may have grown.
    func flush() throws -> Bool
    /// Worker-status engine fields: (engine, reason, optimizations).
    var engine: (String, String, [String: Bool]) { get }
}
extension StreamingNative {
    func flush() throws -> Bool { false }
    var engine: (String, String, [String: Bool]) { ("mlx", "No optimized path for this streaming model yet.", [:]) }
    func drain(final: Bool = false) throws -> String {
        if final { let result = text.streamingTrim; text = ""; return result }
        let bytes = Array(text.utf8)
        guard bytes.count >= 2048 else { return "" }
        // ASCII space cannot occur inside a multibyte UTF-8 scalar. Work in
        // bytes so a following combining mark does not hide a Python boundary.
        guard let offset = bytes.prefix(2048).lastIndex(of: 32), offset > 0 else {
            if bytes.count > 8192 { throw StreamingFailure.inference }
            return ""
        }
        let result = String(decoding: bytes[..<offset], as: UTF8.self).streamingTrim
        text = String(decoding: bytes[offset...], as: UTF8.self)
        return result
    }
}
extension String {
    var streamingTrim: String { trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{001c}\u{001d}\u{001e}\u{001f}"))) }
}
func streamingIdentifier(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    // uuid.UUID accepts URN/braced/hyphenless forms too; echo the original ID.
    let raw = value.replacingOccurrences(of: "urn:", with: "").replacingOccurrences(of: "uuid:", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "{}" )).replacingOccurrences(of: "-", with: "")
    guard raw.utf8.count == 32, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
    return value
}
func streamingPCM(_ value: Any?) throws -> [Float] {
    guard let string = value as? String, string.utf8.count <= 8536,
          let bytes = Data(base64Encoded: string), !bytes.isEmpty,
          bytes.count <= 6400, bytes.count % 4 == 0 else { throw StreamingFailure.invalid }
    var samples: [Float] = []; samples.reserveCapacity(bytes.count / 4)
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        let bits = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        let sample = Float(bitPattern: bits)
        guard sample.isFinite, abs(sample) <= 16 else { throw StreamingFailure.invalid }
        samples.append(sample)
    }
    return samples
}
func streamingModelPath(_ value: Any?) throws -> URL {
    guard let path = value as? String, path.hasPrefix("/") else { throw StreamingFailure.invalid }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw StreamingFailure.invalid }
    func configuration(_ name: String) throws -> [String: Any] {
        let file = url.appendingPathComponent(name).resolvingSymlinksInPath()
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 1048576,
              let data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], data["auto_map"] == nil else { throw StreamingFailure.invalid }
        return data
    }
    do {
        let config = try configuration("config.json")
        guard let type = config["model_type"] as? String, ["nemotron_asr", "voxtral_realtime"].contains(type),
              try FileManager.default.contentsOfDirectory(atPath: url.path).contains(where: { $0.hasSuffix(".safetensors") }) else { throw StreamingFailure.invalid }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("tokenizer_config.json").path) { _ = try configuration("tokenizer_config.json") }
        return url
    } catch { throw StreamingFailure.invalid }
}
final class StreamingSession {
    let factory: (URL) throws -> any StreamingNative
    var native: (any StreamingNative)?
    var frames = 0
    var active = false
    var silent = 0
    var pending: [Float] = []
    var preroll: [[Float]] = []
    var done = false
    init(factory: @escaping (URL) throws -> any StreamingNative) { self.factory = factory }
    func endpoint() throws -> String {
        guard active, let native else { return "" }
        _ = try native.flush()
        try native.push([], final: true)
        let text = try native.drain(final: true)
        try native.reset()
        active = false; silent = 0
        return text
    }
    func block(_ samples: [Float]) throws -> String {
        guard let native else { throw StreamingFailure.invalid }
        // Float32 transport, Double accumulation matches Python unpack + sum.
        let quiet = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count) < 0.0003 * 0.0003
        if !active {
            preroll.append(samples)
            if preroll.count > 15 { preroll.removeFirst() }
            if quiet { return "" }
            active = true
            for block in preroll { try native.push(block, final: false) }
            preroll.removeAll(keepingCapacity: true)
        } else { try native.push(samples, final: false) }
        silent = quiet ? silent + 1 : 0
        if silent >= 40 { return try endpoint() }
        return try native.drain()
    }
    func handle(_ value: Any?) throws -> [String: Any] {
        guard let request = value as? [String: Any], let id = streamingIdentifier(request["id"]), !done else { throw StreamingFailure.invalid }
        let op = request["op"] as? String
        let expected: Set<String> = op == "start" ? ["id", "op", "model"] : op == "audio" ? ["id", "op", "pcm"] : ["id", "op"]
        guard Set(request.keys) == expected else { throw StreamingFailure.invalid }
        if op == "start" {
            guard native == nil else { throw StreamingFailure.invalid }
            native = try factory(streamingModelPath(request["model"]))
            return ["id": id, "frames": 0]
        }
        guard let native else { throw StreamingFailure.invalid }
        var committed: [String] = []
        if op == "audio" {
            let samples = try streamingPCM(request["pcm"])
            frames += samples.count; pending += samples
            while pending.count >= 320 {
                let chunk = Array(pending.prefix(320)); pending.removeFirst(320)
                committed.append(try block(chunk))
            }
        } else if op == "finish" {
            if !pending.isEmpty { committed.append(try block(pending)); pending.removeAll() }
            committed.append(try endpoint()); done = true
        } else { throw StreamingFailure.invalid }
        // A coalescing adapter defers the 20-ms blocks to one push per request.
        // Text is append-only, so draining after the flush cuts at the same place
        // (the first 2048 bytes are unchanged) and lands in the same reply.
        if active, try native.flush() { committed.append(try native.drain()) }
        let partial = active ? native.text.streamingTrim : ""
        let text = committed.filter { !$0.isEmpty }.joined(separator: " ")
        guard (text + partial).utf8.count <= 8192 else { throw StreamingFailure.inference }
        var reply: [String: Any] = ["id": id, "frames": frames, "partial": partial, "committed": text]
        if done { reply["done"] = true }
        return reply
    }
    func reply(_ value: Any?) -> [String: Any] {
        do { return try handle(value) }
        catch {
            done = true
            let identifier: Any = streamingIdentifier((value as? [String: Any])?["id"]) as Any? ?? NSNull()
            return ["id": identifier, "error": (error as? StreamingFailure) == .invalid ? "Invalid local streaming request." : "Local streaming transcription failed."]
        }
    }
    func close() { native?.close(); native = nil; pending.removeAll(); preroll.removeAll() }
}
