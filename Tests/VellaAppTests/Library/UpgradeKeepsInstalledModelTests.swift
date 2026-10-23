import XCTest
@testable import Vella
@testable import VellaCore
import VellaWire

/// An update never takes away a working dictation model (Foster, 23 Oct: "The model is gone ... I need to get it
/// again"). The shipped catalog and benchmarks, an isolated support folder as the earlier version left it, and the
/// launch sequence (registry migration, manifest migration, selection migration, partial-download sweep). No model runs.
final class UpgradeKeepsInstalledModelTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-upgrade-keeps-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private static let nemo = "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"

    private func checkpoint(_ folder: URL, bits: Int?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let quant = bits.map { #", "quantization": {"bits": \#($0), "group_size": 64}"# } ?? ""
        try Data(#"{"target": "\#(Self.nemo)"\#(quant)}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
    }

    @MainActor private func controller(_ support: URL) -> ModelsController {
        let resources = ModelLibrary.resourceDirectory()
        let registry = support.appendingPathComponent("models-installed.json")
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: support.appendingPathComponent("config.json"))
        c.reloadConfig()
        return c
    }

    /// RuntimeBridge.migrateRegistry and sweepPartialDownloads, without a runtime.
    @MainActor private func launch(_ c: ModelsController) -> (cleared: [String], swept: [String]) {
        _ = c.dictation.migrateRegistry(catalog: c.catalog)
        c.streaming.reload()
        _ = migrateDerivedManifests(catalog: c.catalog, modelsDirectory: c.dictation.modelsDirectory)
        let cleared = c.clearSelectionsOutsideTheCatalog()
        let keep = c.dictation.keptModelPaths.union(c.streaming.keptModelPaths).union([c.config?.model, c.config?.streamingModel].compactMap { $0 })
        return (cleared, sweepStalePartialDownloads(modelsDirectory: c.dictation.modelsDirectory, keep: keep, removeFolders: true, olderThan: 0))
    }

    /// 0.8's recommended Parakeet v3 4-bit (and the 8-bit), downloaded from Hugging Face. 2.0 gave the tier made on
    /// this Mac the same id, so the launch migration cleared the dictation model and the next dictation offered
    /// "Get Parakeet v3 Ultra (1.3 GB)". Without the 16-bit source the files stay the dictation model and load as they
    /// are (under their folder name, never as the measured tier); nothing is cleared, swept or deletable while in use.
    @MainActor func testA08ParakeetDownloadStaysTheDictationModelWithoutADownload() async throws {
        for bits in [4, 8] {
            let support = root.appendingPathComponent("v08-\(bits)")
            let id = "parakeet-tdt-0.6b-v3-mlx-\(bits)bit"
            let legacy = support.appendingPathComponent("Models/" + id)
            try checkpoint(legacy, bits: bits)
            // A finished download keeps Hugging Face's cache folder; a stale partial there must not take the folder.
            let partial = legacy.appendingPathComponent(".cache/huggingface/download/model.safetensors.incomplete")
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("p".utf8).write(to: partial)
            try Data(#"{"\#(id)":{"name":"Parakeet v3","path":"\#(legacy.path)","quantization":"\#(bits)-bit","revision":"x"}}"#.utf8)
                .write(to: support.appendingPathComponent("models-installed.json"))
            // config.json as 0.8 wrote it (Python runtime path, no selections).
            let config = #"{"mode":"dictation","executable":"/py","streamingModel":"","model":"\#(legacy.path)","fallbackMicrophone":"","preferredMicrophone":""}"#
            try Data(config.utf8).write(to: support.appendingPathComponent("config.json"))
            let c = controller(support)
            let (cleared, _) = launch(c)
            XCTAssertEqual(cleared, [], "\(bits)-bit")
            let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: support.appendingPathComponent("config.json")))
            XCTAssertEqual(saved.model, legacy.path, "\(bits)-bit stays the dictation model")
            XCTAssertTrue(saved.clearedSelectionReasons.isEmpty)
            XCTAssertTrue(c.migrationNotices.isEmpty)
            XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("model.safetensors")), Data("weights".utf8))
            let family = try XCTUnwrap(c.catalog.family("parakeet-v3"))
            XCTAssertNotNil(c.keptLegacyCheckpoint(path: legacy.path, mode: .dictation))
            XCTAssertNil(c.identify(path: legacy.path, mode: .dictation), "never the measured tier")
            let selectedModel = saved.model
            c.dictation.currentModelPath = { selectedModel } // production reads config.json
            XCTAssertNotNil(c.dictation.deletionBlockReason(try XCTUnwrap(family.variants[bits == 4 ? "4b" : "8b"]?.id)), "in use: not deletable")
            // Every load path admits the files as they are, under their folder name.
            let runtime = try Runtime.isolated(support.appendingPathComponent("runtime"))
            try Data(config.utf8).write(to: runtime.configURL)
            let model = DictationController(configurationURL: runtime.configURL, monitorDefaultInput: false)
            defer { model.shutdown() }
            let bridge = RuntimeBridge(runtime: runtime)
            bridge.attach(controller: c, model: model)
            XCTAssertNil(bridge.recipeRefusal(path: legacy.path, mode: .dictation))
            let ref = runtime.resolve(legacy.path, mode: .dictation)
            XCTAssertEqual(ref.path, legacy.path)
            XCTAssertEqual(ref.id, id); XCTAssertEqual(ref.precision, "", "not presented as the measured tier")
            try await runtime.admit(ref)
            // Once another model is selected, the earlier download no longer loads by path.
            try JSONEncoder().encode(Configuration(model: "/elsewhere")).write(to: runtime.configURL)
            XCTAssertNotNil(bridge.recipeRefusal(path: legacy.path, mode: .dictation))
        }
    }

    /// What 2.0 to 2.1.0 left behind (Foster's Mac): the dictation model cleared with the legacy reason, the 0.8 files and
    /// registry entry kept. The next launch selects them again, once, with a notice; nothing is downloaded.
    @MainActor func testAModelClearedBy210IsSelectedAgain() throws {
        let support = root.appendingPathComponent("cleared")
        let legacy = support.appendingPathComponent("Models/parakeet-tdt-0.6b-v3-mlx-4bit")
        try checkpoint(legacy, bits: 4)
        try Data(#"{"parakeet-tdt-0.6b-v3-mlx-4bit":{"name":"Parakeet v3","path":"\#(legacy.path)","quantization":"4-bit"}}"#.utf8)
            .write(to: support.appendingPathComponent("models-installed.json"))
        var cleared = Configuration(model: "")
        cleared.clearedSelectionReasons["dictation"] =
            "Parakeet v3's legacy published quantization is kept on disk but no longer used. Get its 16-bit source in Models to prepare the measured local tier."
        try JSONEncoder().encode(cleared).write(to: support.appendingPathComponent("config.json"))
        let c = controller(support)
        _ = launch(c)
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: support.appendingPathComponent("config.json")))
        XCTAssertEqual(saved.model, legacy.path)
        XCTAssertNil(saved.clearedSelectionReasons["dictation"])
        XCTAssertEqual(c.migrationNotices, ["Dictation uses your earlier Parakeet v3 download again. Nothing was downloaded."])
        let bytes = try Data(contentsOf: support.appendingPathComponent("config.json"))
        _ = launch(c)
        XCTAssertTrue(c.migrationNotices.isEmpty, "disclosed once")
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("config.json")), bytes)
        // A mode the user emptied for another reason is left alone.
        var other = Configuration(model: "")
        other.clearedSelectionReasons["dictation"] = "Dictation no longer supports Whisper small."
        try JSONEncoder().encode(other).write(to: support.appendingPathComponent("config.json"))
        c.reloadConfig()
        _ = launch(c)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: support.appendingPathComponent("config.json"))).model, "")
    }

    /// Once the 16-bit source is installed, the existing rule takes over: the measured tier is made from it and the
    /// earlier download is kept on disk.
    @MainActor func testA08DownloadMovesToTheMeasuredTierOnceTheSourceIsHere() throws {
        let support = root.appendingPathComponent("v08-source")
        let legacy = support.appendingPathComponent("Models/parakeet-tdt-0.6b-v3-mlx-4bit")
        let source = support.appendingPathComponent("Models/parakeet-tdt-0.6b-v3-mlx-bf16-local")
        try checkpoint(legacy, bits: 4)
        try checkpoint(source, bits: nil)
        let registry = #"""
            {"parakeet-tdt-0.6b-v3-mlx-4bit":{"name":"Parakeet v3","path":"\#(legacy.path)","quantization":"4-bit"},
             "parakeet-tdt-0.6b-v3-mlx-bf16-local":{"name":"Parakeet v3","path":"\#(source.path)","quantization":"BF16"}}
            """#
        try Data(registry.utf8).write(to: support.appendingPathComponent("models-installed.json"))
        try JSONEncoder().encode(Configuration(model: legacy.path)).write(to: support.appendingPathComponent("config.json"))
        let c = controller(support)
        XCTAssertNil(c.keptLegacyCheckpoint(path: legacy.path, mode: .dictation))
        _ = launch(c)
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: support.appendingPathComponent("config.json")))
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: saved.model))?.precision, "4b")
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: saved.model))?.source, source.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("model.safetensors").path))
    }

    /// 2.0 → 2.1 (one Precision row; the Standard path is no longer a choice): Parakeet v3 Ultra stays selected and
    /// available at every 2.0 cell, its own weights or a tier made from them, and no file is removed.
    @MainActor func testEvery20UltraSelectionSurvivesTheOneRowTable() throws {
        for tier in ["16", "8", "4"] {
            for path in ["standard", "optimized"] {
                for mode in ["exact", "fast"] {
                    for made in tier == "16" ? [false] : [false, true] {
                        let label = "\(tier)/\(path)/\(mode)/\(made ? "made" : "bf16")"
                        let support = root.appendingPathComponent(label.replacingOccurrences(of: "/", with: "-"))
                        let ultra = support.appendingPathComponent("Models/parakeet-ultra-mlx-bf16")
                        try checkpoint(ultra, bits: nil)
                        try Data(#"{"parakeet-ultra-mlx-bf16":{"name":"Parakeet v3 Ultra","path":"\#(ultra.path)","quantization":"BF16"}}"#.utf8)
                            .write(to: support.appendingPathComponent("models-installed.json"))
                        let precision = tier == "16" ? "BF16" : tier == "8" ? "8b" : "4b"
                        var selected = ultra.path
                        if made {
                            let family = try XCTUnwrap(controller(support).catalog.family("parakeet-v3-ultra"))
                            selected = try prepareDerivedModel(
                                family: family, precision: precision, sourcePath: ultra.path, modelsDirectory: support.appendingPathComponent("Models"))
                        }
                        let config = #"""
                            {"model":"\#(selected)","mode":"dictation","streamingModel":"","preferredMicrophone":"","fallbackMicrophone":"",
                             "lastLoaded":{"parakeet-v3-ultra":"\#(precision)"},
                             "selections":{"parakeet-v3-ultra":{"tier":"\#(tier)","path":"\#(path)","mode":"\#(mode)"}}}
                            """#
                        try Data(config.utf8).write(to: support.appendingPathComponent("config.json"))
                        let c = controller(support)
                        let (cleared, swept) = launch(c)
                        XCTAssertEqual(cleared, [], label); XCTAssertEqual(swept, [], label)
                        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: support.appendingPathComponent("config.json")))
                        XCTAssertEqual(saved.model, selected, label)
                        let family = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
                        XCTAssertTrue(c.available(family, c.committed(family)), label)
                        XCTAssertEqual(saved.selections[family.id]?.tier.rawValue, tier, label)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: ultra.appendingPathComponent("model.safetensors").path), label)
                    }
                }
            }
        }
    }
}
