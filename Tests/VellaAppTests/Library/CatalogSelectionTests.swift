import XCTest
@testable import Vella
@testable import VellaCore
import VellaWire

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

    /// Qwen3 ASR 0.6B 4b (a legacy published import), Parakeet v3 bf16 (a stored conversion), Parakeet v3 Ultra 8b (derived from
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
            "imported-whisper-small": InstalledModel(path: imported, name: "Whisper small", quantization: "FP16")
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: support.appendingPathComponent("models-installed.json"))
        let resources = ModelLibrary.resourceDirectory()
        let registryURL = support.appendingPathComponent("models-installed.json")
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registryURL),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registryURL),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: configURL)
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let derived = try prepareDerivedModel(family: family, precision: "8b", sourcePath: ultra, modelsDirectory: models)
        return (c, Paths(plain: plain, stored: stored, derived: derived, outside: outside, ultra: ultra))
    }

    @MainActor func testCatalogPathsAreIdentifiedAndOthersAreNot() throws {
        let (c, p) = try controller()
        XCTAssertNil(c.identify(path: p.plain, mode: .dictation), "published low-bit imports are not locally derived tiers")
        XCTAssertEqual(c.identify(path: p.stored, mode: .dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3 BF16")
        XCTAssertEqual(c.identify(path: p.derived, mode: .dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3-ultra 8b")
        XCTAssertNil(c.identify(path: p.outside, mode: .dictation))
        XCTAssertNil(c.identify(path: p.plain, mode: .streaming), "a dictation model is not a streaming selection")
    }

    @MainActor func testRejectedSavedCellMigratesWithExistingLaunchNoticeAndKeepsFiles() throws {
        let (c, p) = try controller()
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        var benchmark = try XCTUnwrap(c.benchmarks.models[family.id])
        for tier in benchmark.tiers.keys {
            for segment in Recipe.allCases {
                benchmark.tiers[tier]?.cells[segment]?.gate = SegmentGate(
                    status: .pass, presence: TierPresence(offered: tier == .t16 && segment == .standard))
            }
        }
        c.benchmarks.models[family.id] = benchmark
        var config = Configuration(model: p.derived)
        config.lastLoaded = [family.id: "8b"]
        config.selections[family.id] = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        try JSONEncoder().encode(config).write(to: configURL)
        let manifestURL = URL(fileURLWithPath: p.derived).appendingPathComponent("vella-derived.json")
        let manifest = try Data(contentsOf: manifestURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(saved.selections[family.id], ModelSelection(tier: .t16, path: .standard, mode: .fast))
        XCTAssertEqual(saved.model, p.ultra, "migration switches the active path to the offered installed precision")
        XCTAssertEqual(saved.lastLoaded, config.lastLoaded, "migration is not a successful Load")
        XCTAssertEqual(c.committedSelection(family), saved.selections[family.id])
        XCTAssertEqual(c.migrationNotices.count, 1)
        XCTAssertTrue(c.migrationNotices[0].contains("earlier cell is no longer offered"))
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        XCTAssertTrue(c.migrationNotices.isEmpty, "the change is disclosed once")
    }

    /// The current configuration shape: Ultra BF16 uses the implicit Optimized Fast default; Streaming already uses
    /// a local Nemotron int8 derivation at Optimized Fast. Corrected cell presence must not migrate either selection.
    @MainActor func testCorrectedDataKeepsCurrentSelectionsWithoutMigrationNotice() throws {
        let (c, p) = try controller()
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let nemotron = try XCTUnwrap(c.catalog.family("nemotron-3.5-streaming-0.6b"))
        let source = support.appendingPathComponent("Models/" + nemotron.variants["BF16"]!.id)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        try Data("fixture".utf8).write(to: source.appendingPathComponent("model.safetensors"))
        c.streaming.installed[nemotron.variants["BF16"]!.id] = InstalledModel(path: source.path)
        let derived = try prepareDerivedModel(family: nemotron, precision: "8b", sourcePath: source.path, modelsDirectory: source.deletingLastPathComponent())
        let selected = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        var config = Configuration(model: p.ultra, streamingModel: derived)
        config.selections[nemotron.id] = selected
        let bytes = try JSONEncoder().encode(config)
        try bytes.write(to: configURL)
        c.reloadConfig()
        XCTAssertEqual(c.rules(ultra).runnable(recorded: nil, precision: "BF16"), .fallback)
        XCTAssertEqual(c.rules(nemotron).valid(selected), selected)
        XCTAssertNotNil(c.identify(path: derived, mode: .streaming))
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        XCTAssertTrue(c.migrationNotices.isEmpty)
        XCTAssertNil(c.lastError)
        XCTAssertEqual(try Data(contentsOf: configURL), bytes, "no selection or configuration migration")
        XCTAssertEqual(c.committedSelection(ultra), .fallback)
        XCTAssertEqual(c.committedSelection(nemotron), selected)
    }

    @MainActor func testRejectedSavedCellWithoutOfferedWeightsClearsActivePathAndExplainsGet() throws {
        let (c, p) = try controller()
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        var benchmark = try XCTUnwrap(c.benchmarks.models[family.id])
        for tier in benchmark.tiers.keys {
            for segment in Recipe.allCases {
                benchmark.tiers[tier]?.cells[segment]?.gate = SegmentGate(
                    status: .pass, presence: TierPresence(offered: tier == .t16 && segment == .standard))
            }
        }
        c.benchmarks.models[family.id] = benchmark
        c.dictation.installed.removeValue(forKey: "parakeet-ultra-mlx-bf16")
        var config = Configuration(model: p.derived)
        config.lastLoaded = [family.id: "8b"]
        config.selections[family.id] = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        try JSONEncoder().encode(config).write(to: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [p.derived])
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(saved.model, "")
        XCTAssertEqual(saved.selections[family.id], ModelSelection(tier: .t16, path: .standard, mode: .fast))
        XCTAssertEqual(saved.lastLoaded, config.lastLoaded)
        XCTAssertTrue(saved.clearedSelectionReasons["dictation"]?.contains("Get or Load") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.derived + "/vella-derived.json"))
        XCTAssertEqual(c.migrationNotices.count, 1)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
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
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("outside/whisper-small/model.safetensors").path),
            "the migration never deletes files")
        XCTAssertEqual(try Data(contentsOf: configURL), before, "config.json is not the registry migration's")
    }

    /// Launch migration (catalog-only ruling, D-5): a mode's model outside the catalog is cleared from config.json and
    /// its files stay; catalog paths (a download, a stored conversion, a derived precision) are untouched.
    @MainActor func testSelectionsOutsideTheCatalogAreClearedAtLaunch() throws {
        let (c, p) = try controller()
        for kept in [p.stored, p.derived] {
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

    @MainActor func testLegacyPublishedQuantSelectionClearsButKeepsItsWeights() throws {
        let (c, p) = try controller()
        try JSONEncoder().encode(Configuration(model: p.plain)).write(to: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [p.plain])
        XCTAssertTrue(c.lastError?.contains("16-bit source") == true)
        XCTAssertEqual(c.migrationNotices.count, 1)
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertTrue(saved.clearedSelectionReasons["dictation"]?.contains("16-bit source") == true)
        var replacement = saved
        replacement.selectModel(p.stored, for: .dictation)
        XCTAssertNil(replacement.clearedSelectionReasons["dictation"])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)).model, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.plain + "/model.safetensors"))
    }

    /// With an unreadable (corrupt) registry nothing can be identified, so nothing is cleared.
    @MainActor func testNothingIsClearedWithACorruptRegistry() throws {
        let (c, p) = try controller()
        try Data("not json".utf8).write(to: support.appendingPathComponent("models-installed.json"))
        c.dictation.reload()
        try JSONEncoder().encode(Configuration(model: p.plain)).write(to: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)).model, p.plain)
    }

    /// Without a registry file (a support folder from before v0.6.0, or one the user deleted) nothing can be identified,
    /// so nothing is cleared: a catalog download stays selected instead of offering Get again.
    @MainActor func testNothingIsClearedWithoutARegistryFile() throws {
        let (c, p) = try controller()
        try? FileManager.default.removeItem(at: support.appendingPathComponent("models-installed.json"))
        c.dictation.reload()
        XCTAssertTrue(c.dictation.registryReadable, "a missing registry reads as empty")
        try JSONEncoder().encode(Configuration(model: p.plain, streamingModel: p.outside)).write(to: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        let after = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(after.model, p.plain); XCTAssertEqual(after.streamingModel, p.outside)
    }
    /// Representative subset of the 3 Oct upgrader (external registry entries omitted): Ultra BF16 dictation, Nemotron published int8 streaming,
    /// BF16 Nemotron root and unoffered v3 Q4. No user paths, recordings or weights are copied.
    @MainActor func testLegacyPublishedStreamingQuantMigratesToCorrectedLocalInt8() async throws {
        let models = support.appendingPathComponent("Models")
        let names = [
            "nemotron-3.5-asr-streaming-0.6b-8bit", "nemotron-3.5-asr-streaming-0.6b-bf16",
            "parakeet-tdt-0.6b-v3-mlx-4bit", "parakeet-ultra-mlx-bf16"
        ]
        var registry: [String: InstalledModel] = [:]
        for name in names {
            let folder = models.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
            try Data("legacy-weight-fixture".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
            registry[name] = InstalledModel(path: folder.path, name: name, quantization: name.hasSuffix("8bit") ? "8-bit" : name.hasSuffix("4bit") ? "4-bit" : "BF16")
        }
        let registryURL = support.appendingPathComponent("models-installed.json")
        try JSONEncoder().encode(registry).write(to: registryURL)
        let old = models.appendingPathComponent(names[0]).path
        let dictation = models.appendingPathComponent(names[3]).path
        let config = Configuration(model: dictation, streamingModel: old)
        try JSONEncoder().encode(config).write(to: configURL)
        let resources = ModelLibrary.resourceDirectory()
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registryURL),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registryURL),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        let migrated = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(c.migrationNotices.count, 1)
        XCTAssertTrue(c.migrationNotices[0].contains("Streaming now uses"))
        XCTAssertTrue(c.migrationNotices[0].contains("made on this Mac"))
        XCTAssertTrue(c.migrationNotices[0].contains("earlier download is kept"))
        XCTAssertEqual(migrated.lastLoaded, config.lastLoaded, "migration is not a successful Load")
        XCTAssertEqual(migrated.model, dictation)
        XCTAssertNotEqual(migrated.streamingModel, old)
        XCTAssertEqual(migrated.streamingModel, models.appendingPathComponent(names[0] + ".derived").path)
        XCTAssertEqual(migrated.selections["nemotron-3.5-streaming-0.6b"], ModelSelection(tier: .t8, path: .optimized, mode: .fast))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: old + "/model.safetensors")), Data("legacy-weight-fixture".utf8))
        let absent = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertFalse(c.options(absent).contains("4b"))
        XCTAssertEqual(try c.deletionPlan(absent, precision: "4b").path, models.appendingPathComponent(names[2]).path)
        let streamingFamily = try XCTUnwrap(c.catalog.family("nemotron-3.5-streaming-0.6b"))
        XCTAssertTrue(try c.deletionPlan(streamingFamily, precision: "8b").title.contains("earlier download (not used)"))
        let legacyPlan = try c.deletionPlan(streamingFamily, precision: "8b")
        XCTAssertTrue(legacyPlan.body.contains("cannot be downloaded again"))
        XCTAssertTrue(legacyPlan.body.contains("No recipe files depend"))
        XCTAssertFalse(legacyPlan.body.contains("You can download it again"))
        let menu = try XCTUnwrap(ModelsMenu(controller: c).modelItem().submenu)
        XCTAssertTrue(menu.items.contains { $0.title == "Delete Parakeet v3 4-bit…" })
        let bytes = try Data(contentsOf: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        XCTAssertEqual(try Data(contentsOf: configURL), bytes, "idempotent")
        let runtime = try Runtime.isolated(root.appendingPathComponent("api-fixture"))
        let controls = ModelControls(controller: c, runtime: runtime)
        let legacyFiles = try XCTUnwrap(controls.object(streamingFamily)["local_files"] as? [[String: Any]])
        let oldFile = try XCTUnwrap(legacyFiles.first { $0["legacy"] as? Bool == true })
        XCTAssertEqual(oldFile["precision"] as? String, "legacy published quantization")
        XCTAssertEqual(oldFile["catalog_precision"] as? String, "int8")
        XCTAssertEqual(oldFile["offered"] as? Bool, false); XCTAssertEqual(oldFile["used"] as? Bool, false)
        do {
            _ = try await controls.perform("delete", id: absent.id, fields: ["precision": "int4"])
            XCTFail("unoffered legacy Delete needs consent")
        } catch let error as APIError { XCTAssertEqual(error.code, "deletion_consent_required") }
        let trash = root.appendingPathComponent("fixture-trash")
        c.dictation.trashModel = { item in
            try FileManager.default.moveItem(at: item, to: trash)
            return trash
        }
        _ = try await controls.perform("delete", id: absent.id, fields: ["precision": "int4", "yes": true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old + "/model.safetensors"), "deleting another legacy tier preserves Streaming")
    }

    @MainActor func testUnofferedLegacyTierUsesInstalledNativeSourceInsteadOfClearing() throws {
        let (c, p) = try controller()
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertFalse(try c.deletionPlan(family, precision: "BF16").title.contains("earlier download"), "stored conversion is not a legacy download")
        let variant = try XCTUnwrap(family.variants["4b"])
        let legacy = support.appendingPathComponent("Models/" + variant.id)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("config.json"))
        try Data("keep".utf8).write(to: legacy.appendingPathComponent("model.safetensors"))
        let registryURL = support.appendingPathComponent("models-installed.json")
        var registry = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: registryURL))
        registry[variant.id] = InstalledModel(path: legacy.path, name: family.name, quantization: "4-bit")
        try JSONEncoder().encode(registry).write(to: registryURL)
        c.reload()
        try JSONEncoder().encode(Configuration(model: legacy.path)).write(to: configURL)
        XCTAssertEqual(c.clearSelectionsOutsideTheCatalog(), [])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)).model, p.stored)
        XCTAssertTrue(c.lastError?.contains("no longer offered") == true)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("model.safetensors")), Data("keep".utf8))
    }

    @MainActor func testFailedRecipePreparationDoesNotClaimTheSourceIsMissing() throws {
        let (c, paths) = try controller()
        let f = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let derived = URL(fileURLWithPath: paths.derived)
        try FileManager.default.removeItem(at: derived)
        try Data("blocks directory creation".utf8).write(to: derived)
        let fallback = c.dictation.modelsDirectory.appendingPathComponent(f.variants["8b"]!.id + ".derived")
        if !sameDirectory(fallback, derived) { try Data("blocks fallback directory creation".utf8).write(to: fallback) }
        let runtime = try Runtime.isolated(root.appendingPathComponent("derive-refusal"))
        let model = DictationController(configurationURL: runtime.configURL, monitorDefaultInput: false); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime); bridge.attach(controller: c, model: model)
        // An unused published int8 file identifies the requested precision; the current recipe cannot be written.
        let id = try XCTUnwrap(f.variants["8b"]?.id)
        let old = support.appendingPathComponent("Models/legacy-ultra-int8")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        c.dictation.installed[id] = InstalledModel(path: old.path)
        let reason = try XCTUnwrap(bridge.recipeRefusal(path: old.path, mode: .dictation))
        XCTAssertTrue(reason.contains("Could not prepare")); XCTAssertTrue(reason.contains("Existing weights are kept"))
        XCTAssertFalse(reason.contains("not on this Mac")); XCTAssertFalse(reason.contains("Get it"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.ultra + "/config.json"))
    }

    @MainActor func testImportedPublishedQuantIsNotTheMeasuredTier() throws {
        let (c, _) = try controller()
        let f = try XCTUnwrap(c.catalog.family("qwen3-asr-0.6b"))
        let runtime = try Runtime.isolated(root.appendingPathComponent("legacy-json"))
        let files = try XCTUnwrap(ModelControls(controller: c, runtime: runtime).object(f)["local_files"] as? [[String: Any]])
        let old = try XCTUnwrap(files.first)
        XCTAssertEqual(old["precision"] as? String, "legacy published quantization")
        XCTAssertEqual(old["offered"] as? Bool, false); XCTAssertEqual(old["used"] as? Bool, false)
        XCTAssertEqual(old["legacy"] as? Bool, true)
    }

    @MainActor func testExternalModelJSONAgreesWithDeleteRefusal() throws {
        let (c, _) = try controller()
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        let id = try XCTUnwrap(family.variants["BF16"]?.id)
        let external = root.appendingPathComponent("external-model")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: external.appendingPathComponent("config.json"))
        try Data("keep".utf8).write(to: external.appendingPathComponent("model.safetensors"))
        let registryURL = support.appendingPathComponent("models-installed.json")
        var registry = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: registryURL))
        registry[id] = InstalledModel(path: external.path, name: family.name, quantization: "BF16")
        try JSONEncoder().encode(registry).write(to: registryURL)
        c.reload()
        let runtime = try Runtime.isolated(root.appendingPathComponent("external-api-fixture"))
        let controls = ModelControls(controller: c, runtime: runtime)
        let files = try XCTUnwrap(controls.object(family)["local_files"] as? [[String: Any]])
        XCTAssertEqual(files.first { $0["precision"] as? String == "bf16" }?["deletable"] as? Bool, false)
        XCTAssertThrowsError(try c.deletionPlan(family, precision: "BF16"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("model.safetensors").path))
    }

}
