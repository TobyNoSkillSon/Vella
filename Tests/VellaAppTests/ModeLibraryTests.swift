import XCTest
import CryptoKit
@testable import Vella
@testable import VellaCore

final class ModeLibraryTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
    @MainActor private func libraries() throws -> (ModelLibrary, ModelLibrary) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-modes-\(UUID())")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("models-installed.json")
        let dictation = ModelLibrary(mode: .dictation, registryURL: registry)
        let streaming = ModelLibrary(mode: .streaming, registryURL: registry)
        dictation.currentModelPath = { "" }; streaming.currentModelPath = { "" }
        return (dictation, streaming)
    }
    @MainActor func testCatalogsAndSelectionAreIndependentWithModeQualifiedMetrics() throws {
        let (dictation, streaming) = try libraries()
        XCTAssertFalse(dictation.models.isEmpty)
        XCTAssertFalse(dictation.models.contains { $0.architecture == "nemotron_asr" })
        XCTAssertGreaterThanOrEqual(streaming.models.count, 1)
        let model = try XCTUnwrap(streaming.models.first { $0.id == "nemotron-3.5-asr-streaming-0.6b-8bit" })
        XCTAssertEqual(model.architecture, "nemotron_asr")
        XCTAssertEqual(model.revision, "7279359e4481b5e9e185a318bd618e429c6d86cd")
        XCTAssertFalse(model.license.isEmpty)
        XCTAssertEqual(model.recommended, true)
        XCTAssertFalse(model.recommendation.isEmpty)
        let selection = dictation.selectedID
        streaming.selectedID = model.id
        streaming.reload(); dictation.reload()
        XCTAssertEqual(dictation.selectedID, selection)
        XCTAssertEqual(streaming.selectedID, model.id)
        XCTAssertTrue(streaming.references.values.allSatisfy { $0.recognitionMode == .streaming && $0.streamingQualified == true })
        XCTAssertTrue(dictation.references.values.allSatisfy { ($0.recognitionMode ?? .dictation) == .dictation })
        XCTAssertFalse(streaming.supports("qwen3_asr"))
        XCTAssertFalse(dictation.supports("nemotron_asr"))
    }
    @MainActor func testRegistryMergesOnlyChangedEntryAcrossStaleLibraries() throws {
        let (dictation, streaming) = try libraries()
        dictation.installed["dictation"] = InstalledModel(path: "/fixture/dictation")
        try dictation.saveRegistry(updating: "dictation")
        streaming.installed["stream"] = InstalledModel(path: "/fixture/stream")
        try streaming.saveRegistry(updating: "stream")
        dictation.installed["dictation"] = nil
        try dictation.saveRegistry(updating: "dictation")
        streaming.installed["second"] = InstalledModel(path: "/fixture/second")
        try streaming.saveRegistry(updating: "second")
        let disk = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: streaming.registryURL))
        XCTAssertNil(disk["dictation"], "A stale library must not resurrect a deleted entry")
        XCTAssertNotNil(disk["stream"])
        XCTAssertNotNil(disk["second"])
    }
    @MainActor func testStreamingReferencesRejectBatchPilotMemoryAndStaleWorker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-stream-results-\(UUID())")
        roots.append(root)
        let references = root.appendingPathComponent("ReferenceResults")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let source = ModelLibrary.resourceDirectory()
        for file in ["streaming-models.json", "benchmark-policy.json", "streaming_worker.py"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: root.appendingPathComponent(file))
        }
        let policy = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("benchmark-policy.json"))) as! [String: Any]
        let workerHash = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("streaming_worker.py"))).map { String(format: "%02x", $0) }.joined()
        let sourceResults = try FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("ReferenceResults"), includingPropertiesForKeys: nil)
        let candidate = try XCTUnwrap(sourceResults.first { $0.lastPathComponent.hasPrefix("formatted-M5Max-") })
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as! [String: Any]
        record["modelID"] = "nemotron-3.5-asr-streaming-0.6b-8bit"; record["clips"] = []
        record["suiteID"] = policy["suiteID"]; record["suiteHash"] = policy["suiteHash"]
        record["repeats"] = 2; record["recognitionMode"] = "streaming"
        record["streamingQualified"] = true; record["streamingWorkerSHA256"] = workerHash
        record["complete"] = true; record["measurementKind"] = "timing"
        let library = ModelLibrary(mode: .streaming, resources: root, registryURL: root.appendingPathComponent("registry.json"))
        let path = references.appendingPathComponent("fixture.json")
        func write(_ data: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: data).write(to: path)
            library.reload()
        }
        try write(record)
        XCTAssertNotNil(library.references["nemotron-3.5-asr-streaming-0.6b-8bit"])
        for (key, value) in [("recognitionMode", "dictation" as Any), ("complete", false), ("streamingQualified", false), ("measurementKind", "memory"), ("streamingWorkerSHA256", "stale")] {
            var invalid = record; invalid[key] = value
            try write(invalid)
            XCTAssertNil(library.references["nemotron-3.5-asr-streaming-0.6b-8bit"], key)
        }
    }
    @MainActor func testBothSavedSelectionsProtectFilesRegardlessOfMode() throws {
        let (_, streaming) = try libraries()
        let id = try XCTUnwrap(streaming.models.first?.id)
        let folder = streaming.modelsDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        streaming.protectedModelPaths = { ["/fixture/dictation", folder.path] }
        XCTAssertNotNil(streaming.deletionBlockReason(id))
        streaming.protectedModelPaths = { [folder.path, "/fixture/stream"] }
        XCTAssertNotNil(streaming.deletionBlockReason(id))
        streaming.protectedModelPaths = { [] }
        XCTAssertNil(streaming.deletionBlockReason(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    @MainActor func testCrossModeImportsAreRejected() throws {
        let (dictation, streaming) = try libraries()
        let stream = try XCTUnwrap(streaming.models.first)
        let folder = streaming.modelsDirectory.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"model_type":"nemotron_asr","quantization":{"bits":8}}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("fixture only".utf8).write(to: folder.appendingPathComponent("weights.safetensors"))
        XCTAssertNoThrow(try streaming.validateModel(folder, expected: stream))
        XCTAssertThrowsError(try dictation.validateModel(folder, expected: stream))
        let dictationModel = try XCTUnwrap(dictation.models.first { $0.quantization == "8-bit" && $0.architecture == "qwen3_asr" })
        try Data(#"{"model_type":"qwen3_asr","quantization":{"bits":8}}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertNoThrow(try dictation.validateModel(folder, expected: dictationModel))
        XCTAssertThrowsError(try streaming.validateModel(folder, expected: dictationModel))
    }
}
