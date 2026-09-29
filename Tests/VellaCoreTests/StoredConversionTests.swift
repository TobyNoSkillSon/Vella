import XCTest
@testable import VellaCore

/// Parakeet v3's 16 tier: the FP32 download converted once to BF16 (round to nearest even, as mx.astype), stored only
/// as BF16.
final class StoredConversionTests: XCTestCase {
    func testRoundToNearestEven() {
        XCTAssertEqual(bfloat16Bits(1.0), 0x3F80)
        XCTAssertEqual(bfloat16Bits(-2.0), 0xC000)
        // 1 + 2^-8 is exactly halfway between two bf16 values: ties go to the even one (down here) ...
        XCTAssertEqual(bfloat16Bits(Float(bitPattern: 0x3F80_8000)), 0x3F80)
        // ... and up when the lower neighbour is odd.
        XCTAssertEqual(bfloat16Bits(Float(bitPattern: 0x3F81_8000)), 0x3F82)
        XCTAssertEqual(bfloat16Bits(Float(bitPattern: 0x3F80_8001)), 0x3F81, "above halfway rounds up")
        XCTAssertEqual(bfloat16Bits(.infinity), 0x7F80)
        XCTAssertEqual(bfloat16Bits(Float(bitPattern: 0x7F7F_FFFF)), 0x7F80, "the largest float rounds to infinity, as MLX")
        XCTAssertTrue(bfloat16Bits(.nan) & 0x7FC0 == 0x7FC0, "NaN stays a quiet NaN")
    }

    /// A safetensors file: 8-byte header length, JSON header, data.
    private func safetensors(_ tensors: [(String, String, [Int], Data)], metadata: [String: String]? = ["format": "mlx"]) -> Data {
        var header: [String: Any] = [:]
        var offset = 0
        var body = Data()
        for (name, dtype, shape, data) in tensors {
            header[name] = ["dtype": dtype, "shape": shape, "data_offsets": [offset, offset + data.count]]
            offset += data.count; body += data
        }
        if let metadata { header["__metadata__"] = metadata }
        let json = try! JSONSerialization.data(withJSONObject: header)
        var length = UInt64(json.count).littleEndian
        return Data(bytes: &length, count: 8) + json + body
    }
    private func floats(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    func testFolderConversionKeepsOnlyBF16AndIsIdempotent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vella-convert-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let weights: [Float] = [1.0, -2.0, 0.1, Float(bitPattern: 0x3F81_8000), 3.14159]
        let ints = Data([1, 0, 0, 0, 2, 0, 0, 0])
        let file = folder.appendingPathComponent("model.safetensors")
        try safetensors([("encoder.w", "F32", [5], floats(weights)), ("steps", "I32", [2], ints)]).write(to: file)
        try Data("{\"model_type\": null}".utf8).write(to: folder.appendingPathComponent("config.json"))

        let manifest = try convertFolderToBF16(folder, family: "parakeet-v3", precision: "BF16", sourceRepository: "o/p", sourceRevision: "r")
        XCTAssertEqual(manifest.tensors, 1)
        XCTAssertEqual(manifest.from, "float32"); XCTAssertEqual(manifest.to, "bfloat16")
        // Read back: the F32 tensor is BF16 with the rounded bits, the I32 tensor is unchanged, the metadata kept.
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let size = try XCTUnwrap(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let header = try readSafetensorsHeader(handle, fileSize: size)
        XCTAssertEqual(header.metadata, ["format": "mlx"])
        XCTAssertEqual(header.dataOffset % 8, 0, "data starts 8-byte aligned")
        let w = try XCTUnwrap(header.tensors.first { $0.name == "encoder.w" })
        XCTAssertEqual(w.dtype, "BF16"); XCTAssertEqual(w.shape, [5]); XCTAssertEqual(w.end - w.start, 10)
        try handle.seek(toOffset: UInt64(header.dataOffset + w.start))
        let bf = try XCTUnwrap(try handle.read(upToCount: 10))
        let bits = (0..<5).map { i in UInt16(bf[2 * i]) | UInt16(bf[2 * i + 1]) << 8 }
        XCTAssertEqual(bits, weights.map(bfloat16Bits))
        let steps = try XCTUnwrap(header.tensors.first { $0.name == "steps" })
        XCTAssertEqual(steps.dtype, "I32")
        try handle.seek(toOffset: UInt64(header.dataOffset + steps.start))
        XCTAssertEqual(try handle.read(upToCount: 8), ints)
        XCTAssertEqual(Int64(size), manifest.bytes)
        // Nothing of the FP32 file is left beside it, and a second run changes nothing.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["config.json", "model.safetensors", StoredConversionManifest.fileName])
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try convertFolderToBF16(folder, family: "parakeet-v3", precision: "BF16", sourceRepository: "o/p", sourceRevision: "r"), manifest)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testTruncatedFileIsRefusedAndLeavesTheSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vella-convert-bad-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("model.safetensors")
        let full = safetensors([("w", "F32", [4], floats([1, 2, 3, 4]))])
        try full.prefix(full.count - 3).write(to: file)
        XCTAssertThrowsError(try convertFolderToBF16(folder, family: "f", precision: "BF16", sourceRepository: "o", sourceRevision: "r"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["model.safetensors"])
    }
}
