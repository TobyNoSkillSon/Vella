import Foundation

// A stored conversion (Toby, 29 Sep 2026): an fp32-only checkpoint (Parakeet v3) is converted once at Get to bf16 and
// only the bf16 weights are kept; fp32 is never a tier. The conversion runs on the CPU, off the main thread, right after
// the verified download (ModelLibrary.download), tensor by tensor: every F32 tensor becomes BF16 with round-to-nearest-even (the rounding of MLX's `astype(bfloat16)`), every
// other tensor is copied unchanged. The folder then records what was done in `vella-converted.json`.

/// `description` keeps the technical detail (for the log); `errorDescription` is the user-facing reason.
public enum StoredConversionError: LocalizedError, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String { if case .invalid(let s) = self { return s }; return "invalid" }
    public var errorDescription: String? { "the downloaded weights are incomplete or damaged" }
}

/// Provenance of a stored conversion, written beside the converted weights.
public struct StoredConversionManifest: Codable, Equatable {
    public static let fileName = "vella-converted.json"
    public var schema: Int
    public var family: String
    public var precision: String
    public var sourceRepository: String
    public var sourceRevision: String
    public var from: String
    public var to: String
    public var rounding: String
    public var tensors: Int
    public var bytes: Int64
}

/// Float32 → bfloat16 bits, round to nearest even; NaN stays a quiet NaN (MLX's `float_to_bfloat_bits`).
@inline(__always) public func bfloat16Bits(_ value: Float) -> UInt16 {
    let bits = value.bitPattern
    if value.isNaN { return UInt16(truncatingIfNeeded: (bits >> 16) | 0x0040) }
    return UInt16(truncatingIfNeeded: (bits &+ 0x7FFF &+ ((bits >> 16) & 1)) >> 16)
}

/// One safetensors file's header: tensor name → (dtype, shape, data range), plus `__metadata__`.
struct SafetensorsHeader {
    var tensors: [(name: String, dtype: String, shape: [Int], start: Int, end: Int)]
    var metadata: [String: String]?
    var dataOffset: Int
}

func readSafetensorsHeader(_ handle: FileHandle, fileSize: Int) throws -> SafetensorsHeader {
    try handle.seek(toOffset: 0)
    guard let lengthBytes = try handle.read(upToCount: 8), lengthBytes.count == 8 else { throw StoredConversionError.invalid("truncated header") }
    let length = lengthBytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    guard length > 0, length < 100_000_000, 8 + Int(length) <= fileSize,
        let json = try handle.read(upToCount: Int(length)), json.count == Int(length),
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
    else { throw StoredConversionError.invalid("bad header") }
    var tensors: [(String, String, [Int], Int, Int)] = []
    var metadata: [String: String]?
    for (name, value) in object {
        if name == "__metadata__" { metadata = value as? [String: String]; continue }
        guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
            let shape = (entry["shape"] as? [NSNumber])?.map(\.intValue), let offsets = (entry["data_offsets"] as? [NSNumber])?.map(\.intValue),
            offsets.count == 2, offsets[0] >= 0, offsets[1] >= offsets[0], 8 + Int(length) + offsets[1] <= fileSize
        else {
            throw StoredConversionError.invalid("bad tensor entry \(name)")
        }
        tensors.append((name, dtype, shape, offsets[0], offsets[1]))
    }
    tensors.sort { $0.3 < $1.3 }
    return SafetensorsHeader(tensors: tensors, metadata: metadata, dataOffset: 8 + Int(length))
}

/// Converts one safetensors file's F32 tensors to BF16 into `output`. Returns (tensors converted, bytes written).
@discardableResult
public func convertSafetensorsToBF16(_ input: URL, output: URL) throws -> (converted: Int, bytes: Int64) {
    let fileSize = (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let reader = try FileHandle(forReadingFrom: input); defer { try? reader.close() }
    let header = try readSafetensorsHeader(reader, fileSize: fileSize)
    // New layout: same order, F32 halved.
    var entries: [String: Any] = [:]
    var offset = 0
    var plan: [(start: Int, end: Int, convert: Bool)] = []
    var converted = 0
    for t in header.tensors {
        let convert = t.dtype == "F32"
        let size = convert ? (t.end - t.start) / 2 : t.end - t.start
        guard !convert || (t.end - t.start) % 4 == 0 else { throw StoredConversionError.invalid("\(t.name): F32 data not a multiple of 4 bytes") }
        entries[t.name] = ["dtype": convert ? "BF16" : t.dtype, "shape": t.shape, "data_offsets": [offset, offset + size]]
        offset += size; plan.append((t.start, t.end, convert)); if convert { converted += 1 }
    }
    if let metadata = header.metadata { entries["__metadata__"] = metadata }
    var json = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    while json.count % 8 != 0 { json.append(0x20) } // pad with spaces: the data starts 8-byte aligned
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
    var length = UInt64(json.count).littleEndian
    try writer.write(contentsOf: Data(bytes: &length, count: 8))
    try writer.write(contentsOf: json)
    let chunk = 16 << 20
    for step in plan {
        try reader.seek(toOffset: UInt64(header.dataOffset + step.start))
        var remaining = step.end - step.start
        while remaining > 0 {
            try autoreleasepool {
                let count = min(chunk, remaining)
                guard let data = try reader.read(upToCount: count), data.count == count else { throw StoredConversionError.invalid("truncated tensor data") }
                remaining -= count
                if !step.convert { try writer.write(contentsOf: data); return }
                var out = Data(count: count / 2)
                data.withUnsafeBytes { raw in
                    out.withUnsafeMutableBytes { dst in
                        let n = count / 4
                        let d = dst.bindMemory(to: UInt16.self)
                        for i in 0..<n {
                            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                            d[i] = bfloat16Bits(Float(bitPattern: bits)).littleEndian
                        }
                    }
                }
                try writer.write(contentsOf: out)
            }
        }
    }
    return (converted, Int64(8 + json.count + offset))
}

/// Converts every `*.safetensors` in `folder` to BF16 in place (each file written beside, then swapped in), updates
/// `model.safetensors.index.json`'s total size, and writes `vella-converted.json`. Idempotent: a folder that already
/// holds the manifest is left alone. Returns the manifest.
@discardableResult
public func convertFolderToBF16(
    _ folder: URL, family: String, precision: String, sourceRepository: String,
    sourceRevision: String
) throws -> StoredConversionManifest {
    let fm = FileManager.default
    let manifestURL = folder.appendingPathComponent(StoredConversionManifest.fileName)
    if let data = try? Data(contentsOf: manifestURL), let done = try? JSONDecoder().decode(StoredConversionManifest.self, from: data) { return done }
    let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw StoredConversionError.invalid("no weights to convert") }
    var tensors = 0
    var total: Int64 = 0
    for file in files {
        let staged = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".bf16")
        try? fm.removeItem(at: staged)
        do {
            let result = try convertSafetensorsToBF16(file, output: staged)
            tensors += result.converted; total += result.bytes
            _ = try fm.replaceItemAt(file, withItemAt: staged)
        } catch { try? fm.removeItem(at: staged); throw error }
    }
    let index = folder.appendingPathComponent("model.safetensors.index.json")
    if var object = (try? Data(contentsOf: index)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
        var metadata = object["metadata"] as? [String: Any], metadata["total_size"] != nil
    {
        metadata["total_size"] = total
        object["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: index, options: .atomic)
    }
    let manifest = StoredConversionManifest(
        schema: 1, family: family, precision: precision, sourceRepository: sourceRepository,
        sourceRevision: sourceRevision, from: "float32", to: "bfloat16",
        rounding: "round to nearest even (as mx.astype)", tensors: tensors, bytes: total)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    return manifest
}

/// The stored conversion's rate for the Get pop-up's time estimate, in source bytes per second: the conversion loop
/// runs at ~6 GB/s on M5 Max (release build, 29 Sep 2026); 1 GB/s leaves room for reading and writing the files and
/// for slower Macs. An estimate, stated as "about".
public let storedConversionBytesPerSecond: Double = 1.0e9
/// A quantization made at load (mx.quantize g64 on the GPU, tensor by tensor): an estimate for the pop-up, in source
/// bytes per second, including reading the source weights.
public let loadQuantizationBytesPerSecond: Double = 1.0e9

/// `about 3 s`: a conversion estimate, never below 1 s.
public func formatConversionSeconds(_ bytes: Int64, rate: Double) -> String {
    "about \(max(1, Int((Double(bytes) / rate).rounded(.up)))) s"
}
