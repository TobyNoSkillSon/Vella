import XCTest
@testable import Vella
@testable import VellaCore

/// How a saved selection maps onto the catalog (the shipped models.json, an isolated registry and config.json): a
/// catalog download, a stored conversion and a derived precision are identified; a folder outside the catalog is not.
/// The launch registry migration drops ids the catalog does not have and never touches files or config.json.
final class CatalogSelectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-catalog-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var support: URL { root.appendingPathComponent("support") }
    private var configURL: URL { support.appendingPathComponent("config.json") }

    struct Paths { var plain, stored, derived, outside, ultra: String }

    /// Qwen3 ASR 0.6B 4b (a download), Parakeet v3 BF16 (a stored conversion), Parakeet v3 Ultra 8b (derived from
    /// the installed BF16), an unregistered folder outside the catalog, and a registry entry for a non-catalog id.
    @MainActor private func controller() throws -> (ModelsController, Paths) {
        let models = support.appendingPathComponent("Models")
        func folder(_ base: URL, _ name: String, _ config: String) throws -> String {
            let url = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: url.appendingPathComponent("config.json"))
            try Data("w".utf8).write(to: url.appendingPathComponent("model.safetensors"))
            return url.path
        }
        let nemo = #"{"target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"}"#
        let plain = try folder(models, "Qwen3-ASR-0.6B-4bit", #"{"model_type": "qwen3_asr", "quantization": {"bits": 4, "group_size": 64}}"#)
        let stored = try folder(models, "parakeet-tdt-0.6b-v3-mlx-bf16-local", nemo)
        let ultra = try folder(models, "parakeet-ultra-mlx-bf16", nemo)
        let outside = try folder(root.appendingPathComponent("outside"), "parakeet-tdt-ctc-110m", #"{"target": "nemo.collections.asr.models.EncDecHybridRNNTCTCBPEModel"}"#)
        let imported = try folder(root.appendingPathComponent("outside"), "whisper-small", #"{"model_type": "whisper"}"#)
        let registry: [String: InstalledModel] = [
            "Qwen3-ASR-0.6B-4bit": InstalledModel(path: plain, name: "Qwen3 ASR 0.6B", quantization: "4-bit"),
            "parakeet-tdt-0.6b-v3-mlx-bf16-local": InstalledModel(path: stored, name: "Parakeet v3", quantization: "BF16"),
            "parakeet-ultra-mlx-bf16": InstalledModel(path: ultra, name: "Parakeet v3 Ultra", quantization: "BF16"),
            "imported-whisper-small": InstalledModel(path: imported, name: "Whisper small", quantization: "FP16"),
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: support.appendingPathComponent("models-installed.json"))
        let resources = ModelLibrary.resourceDirectory()
        let registryURL = support.appendingPathComponent("models-installed.json")
        let c = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registryURL),
                                 streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registryURL),
                                 benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: configURL)
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let derived = try prepareDerivedModel(family: family, precision: "8b", sourcePath: ultra, modelsDirectory: models)
        return (c, Paths(plain: plain, stored: stored, derived: derived, outside: outside, ultra: ultra))
    }

    @MainActor func testCatalogPathsAreIdentifiedAndOthersAreNot() throws {
        let (c, p) = try controller()
        XCTAssertEqual(c.identify(path: p.plain, mode: .dictation).map { "\($0.family.id) \($0.precision)" }, "qwen3-asr-0.6b 4b")
        XCTAssertEqual(c.identify(path: p.stored, mode: .dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3 BF16")
        XCTAssertEqual(c.identify(path: p.derived, mode: .dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3-ultra 8b")
        XCTAssertNil(c.identify(path: p.outside, mode: .dictation))
        XCTAssertNil(c.identify(path: p.plain, mode: .streaming), "a dictation model is not a streaming selection")
    }

    @MainActor func testRegistryMigrationDropsNonCatalogIDsOnly() throws {
        let (c, p) = try controller()
        var config = Configuration(model: p.derived)
        config.lastLoaded = ["parakeet-v3-ultra": "8b"]
        try JSONEncoder().encode(config).write(to: configURL)
        let before = try Data(contentsOf: configURL)
        let result = c.dictation.migrateRegistry(catalog: c.catalog)
        XCTAssertEqual(result.dropped, ["imported-whisper-small"])
        XCTAssertEqual(result.rekeyed, [:])
        let registered = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: support.appendingPathComponent("models-installed.json")))
        XCTAssertEqual(Set(registered.keys), ["Qwen3-ASR-0.6B-4bit", "parakeet-tdt-0.6b-v3-mlx-bf16-local", "parakeet-ultra-mlx-bf16"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside/whisper-small/model.safetensors").path),
                      "the migration never deletes files")
        XCTAssertEqual(try Data(contentsOf: configURL), before, "config.json is not the registry migration's")
    }

    /// Launch migration (catalog-only ruling, D-5): a mode's model outside the catalog is cleared from config.json and
    /// its files stay; catalog paths (a download, a stored conversion, a derived precision) are untouched.
    @MainActor func testSelectionsOutsideTheCatalogAreClearedAtLaunch() throws {
        let (c, p) = try controller()
        for kept in [p.plain, p.stored, p.derived] {
            var config = Configuration(model: kept)
            config.lastLoaded = ["parakeet-v3-ultra": "8b"]
            try JSONEncoder().encode(config).write(to: configURL)
            let before = try Data(contentsOf: configURL)
            XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
            XCTAssertEqual(try Data(contentsOf: configURL), before, kept)
        }
        var config = Configuration(model: p.outside, mode: .streaming, streamingModel: p.plain)
        config.lastLoaded = ["parakeet-v3-ultra": "8b"]
        try JSONEncoder().encode(config).write(to: configURL)
        // The streaming model here is a dictation checkpoint: not a streaming catalog precision either.
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [p.outside, p.plain])
        let after = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(after.model, ""); XCTAssertEqual(after.streamingModel, "")
        XCTAssertEqual(after.mode, .streaming); XCTAssertEqual(after.lastLoaded, ["parakeet-v3-ultra": "8b"])
        XCTAssertEqual(c.config?.model, "", "the table rereads config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.outside + "/model.safetensors"), "files are never touched")
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [], "nothing left to clear")
    }

    /// Without a readable registry nothing can be identified, so nothing is cleared.
    @MainActor func testNothingIsClearedWithoutARegistry() throws {
        let (c, p) = try controller()
        try Data("not json".utf8).write(to: support.appendingPathComponent("models-installed.json"))
        c.dictation.reload()
        try JSONEncoder().encode(Configuration(model: p.plain)).write(to: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)).model, p.plain)
    }
}
