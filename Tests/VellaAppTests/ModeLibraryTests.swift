import XCTest
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
        let model = try XCTUnwrap(streaming.models.first { $0.id == "nemotron-3.5-asr-streaming-0.6b-bf16" })
        XCTAssertEqual(model.architecture, "nemotron_asr")
        XCTAssertEqual(model.revision, "e550040c0478027ed679b2b6b0d055502c103663")
        XCTAssertFalse(model.license.isEmpty)
        XCTAssertEqual(model.recommended, true)
        XCTAssertFalse(model.recommendation.isEmpty)
        let selection = dictation.selectedID
        streaming.selectedID = model.id
        streaming.reload(); dictation.reload()
        XCTAssertEqual(dictation.selectedID, selection)
        XCTAssertEqual(streaming.selectedID, model.id)
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
        let stream = try XCTUnwrap(streaming.models.first { $0.quantization == "BF16" })
        let folder = streaming.modelsDirectory.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"model_type":"nemotron_asr"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("fixture only".utf8).write(to: folder.appendingPathComponent("weights.safetensors"))
        XCTAssertNoThrow(try streaming.validateModel(folder, expected: stream))
        XCTAssertThrowsError(try dictation.validateModel(folder, expected: stream))
        let dictationModel = try XCTUnwrap(dictation.models.first { $0.quantization == "BF16" && $0.architecture == "qwen3_asr" })
        try Data(#"{"model_type":"qwen3_asr"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertNoThrow(try dictation.validateModel(folder, expected: dictationModel))
        XCTAssertThrowsError(try streaming.validateModel(folder, expected: dictationModel))
    }
}
