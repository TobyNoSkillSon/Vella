import XCTest
@testable import Vella
@testable import VellaCore

/// Admission identity and sizes for a locally derived precision (vq-quant): the worker is handed the derived manifest
/// directory, which is not in the installed registry; RuntimeBridge must still resolve it to family + precision and
/// size it from its recipe, not from the ~300-byte manifest.
final class DerivedAdmissionTests: XCTestCase {
    @MainActor func testDerivedManifestPathResolvesWithEstimatedSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-derived-admission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bf16 = CatalogVariant(id: "alpha-bf16", repository: "o/a", revision: String(repeating: "b", count: 40), downloadBytes: 1_200_000_000, architecture: "parakeet")
        let family = ModelFamily(id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "0.6B", license: "test", native: "BF16",
                                 variants: ["BF16": bf16, "4b": CatalogVariant(id: "alpha-4bit-local", architecture: "parakeet", derivedFrom: "BF16", bits: 4, groupSize: 64)])
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [family])).write(to: resources.appendingPathComponent("models.json"))
        let bench = root.appendingPathComponent("benchmarks.json")
        try Data(#"{"schema":1,"models":{"alpha":{"precisions":{"BF16":{"memory_mb":1500}}}}}"#.utf8).write(to: bench)
        let registry = root.appendingPathComponent("support/models-installed.json")
        let controller = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                          streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: bench, selectionsURL: root.appendingPathComponent("model-precision.json"))
        let source = controller.dictation.modelsDirectory.appendingPathComponent("alpha-bf16")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        controller.dictation.installed["alpha-bf16"] = InstalledModel(path: source.path)
        let path = try prepareDerivedModel(family: family, precision: "4b", sourcePath: source.path, modelsDirectory: controller.dictation.modelsDirectory)

        let bridge = RuntimeBridge(runtime: try Runtime.isolated(root))
        let model = Model(configurationURL: root.appendingPathComponent("config.json")); defer { model.shutdown() }
        bridge.attach(controller: controller, model: model)
        let ref = try XCTUnwrap(bridge.ref(path: path, mode: .dictation))
        XCTAssertEqual(ref.id, "alpha"); XCTAssertEqual(ref.precision, "4b"); XCTAssertEqual(ref.path, path)
        // 1500 MB measured at BF16, scaled by weight size: 1500 × (0.85 × 4.5/16 + 0.15) ≈ 583.6 MB (not measured).
        XCTAssertEqual(try XCTUnwrap(ref.memoryMB), 1500 * (0.85 * 4.5 / 16 + 0.15), accuracy: 0.1)
        XCTAssertEqual(Double(try XCTUnwrap(ref.diskBytes)), 1_200_000_000 * (0.85 * 4.5 / 16 + 0.15), accuracy: 1)
        // The source still resolves as itself at its measured size.
        let sourceRef = try XCTUnwrap(bridge.ref(path: source.path, mode: .dictation))
        XCTAssertEqual(sourceRef.precision, "BF16"); XCTAssertEqual(sourceRef.memoryMB, 1500)
    }
}
