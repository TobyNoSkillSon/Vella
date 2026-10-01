import XCTest
import AppKit
@testable import Vella
import VellaCore
import VellaTestSupport

/// One resolution policy for a mixed recipe (float-kept modules) across the Models table's Load, on-demand dictation
/// (`Runtime.resolve` → `RuntimeBridge.ref`), the launch-set preload (`Runtime.launchRef`) and the API's paths: the
/// recipe is made from its 16-bit root into a folder that never collides with real weights; a registered checkpoint
/// under the tier's id (an imported uniform quantization) is never presented as the recipe and never fails it; a
/// manifest an earlier version wrote is rewritten at launch to the current recipe. No model runs, no GPU.
final class MixedRecipeResolutionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-mixed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let beta: ModelFamily = {
        var eight = CatalogVariant(id: "beta-8bit", architecture: "whisper", derivedFrom: "FP16", bits: 8, groupSize: 64)
        eight.floatModules = ["model.encoder"]; eight.floatShare = 0.4
        return ModelFamily(
            id: "beta", name: "Beta", mode: .dictation, languages: ["en"], params: "1.5B", license: "test", native: "FP16",
            variants: [
                "FP16": CatalogVariant(
                    id: "beta-fp16", repository: "org/beta-fp16", revision: String(repeating: "c", count: 40),
                    downloadBytes: 3_000_000_000, architecture: "whisper"),
                "8b": eight
            ])
    }()

    @MainActor private func setUp(rootInstalled: Bool) throws -> (ModelsController, RuntimeBridge, Runtime, DictationController, imported: String) {
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [beta])).write(to: resources.appendingPathComponent("models.json"))
        let registry = root.appendingPathComponent("support/models-installed.json")
        let controller = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: root.appendingPathComponent("no-benchmarks.json"))
        let models = controller.dictation.modelsDirectory
        // The imported uniform 8-bit checkpoint, registered under the tier's id AT the canonical derived path.
        let imported = models.appendingPathComponent("beta-8bit")
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        try Data(#"{"quantization":{"bits":8,"group_size":64}}"#.utf8).write(to: imported.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: imported.appendingPathComponent("model.safetensors"))
        controller.dictation.installed["beta-8bit"] = InstalledModel(path: imported.path)
        if rootInstalled {
            let source = models.appendingPathComponent("beta-fp16")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
            controller.dictation.installed["beta-fp16"] = InstalledModel(path: source.path)
        }
        try JSONEncoder().encode(controller.dictation.installed).write(to: controller.dictation.registryURL)
        let runtime = try Runtime.isolated(root)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        let model = DictationController(configurationURL: runtime.configURL)
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: model)
        return (controller, bridge, runtime, model, imported.standardizedFileURL.path)
    }

    @MainActor private func tableLoadPath(_ controller: ModelsController) throws -> String? {
        let lib = controller.dictation
        return try precisionLoadPath(beta, "8b", installedPath: { lib.installed[$0]?.path }, modelsDirectory: lib.modelsDirectory)
    }

    /// Without the 16-bit source: the imported uniform checkpoint is not the 8 tier anywhere (table, API identity,
    /// on-demand dictation, preload); nothing runs it as "8b".
    @MainActor func testImportedUniformCheckpointWithoutTheSourceIsNeverTheMixedTier() throws {
        let (controller, bridge, runtime, model, imported) = try setUp(rootInstalled: false)
        defer { model.shutdown() }
        XCTAssertFalse(controller.available(beta, "8b"))
        XCTAssertNil(controller.installed(beta, "8b"))
        XCTAssertNil(try tableLoadPath(controller))
        XCTAssertNil(controller.identify(path: imported, mode: .dictation))
        XCTAssertNil(bridge.ref(path: imported, mode: .dictation))
        XCTAssertNotEqual(runtime.resolve(imported, mode: .dictation).precision, "8b")
        let stored = ModelRef(id: "beta", precision: "8b", path: imported, mode: .dictation, name: "Beta")
        XCTAssertNil(runtime.launchRef(stored), "the preload never loads the import under the tier's name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported + "/model.safetensors"), "the import is preserved")
    }

    /// With the 16-bit source: every entry point runs the mixed recipe, derived into a folder beside (not inside) the
    /// imported checkpoint, which stays untouched; the derivation never fails on it.
    @MainActor func testImportedUniformCheckpointWithTheSourceResolvesToTheMixedRecipeEverywhere() throws {
        let (controller, bridge, runtime, model, imported) = try setUp(rootInstalled: true)
        defer { model.shutdown() }
        let derived = try XCTUnwrap(try tableLoadPath(controller))
        XCTAssertEqual(derived, controller.dictation.modelsDirectory.appendingPathComponent("beta-8bit.derived").standardizedFileURL.path)
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: derived))?.floatModules, ["model.encoder"])
        XCTAssertTrue(controller.available(beta, "8b"))
        // On-demand dictation with the recorded import path, and the preload of a launch-set entry recorded with it,
        // run the same folder and precision as Load.
        let onDemand = try XCTUnwrap(bridge.ref(path: imported, mode: .dictation))
        XCTAssertEqual(onDemand.path, derived); XCTAssertEqual(onDemand.precision, "8b")
        XCTAssertEqual(runtime.resolve(imported, mode: .dictation).path, derived)
        let preload = try XCTUnwrap(runtime.launchRef(ModelRef(id: "beta", precision: "8b", path: imported, mode: .dictation, name: "Beta")))
        XCTAssertEqual(preload.path, derived); XCTAssertEqual(preload.precision, "8b")
        XCTAssertEqual(bridge.ref(path: derived, mode: .dictation)?.path, derived)
        XCTAssertEqual(controller.identify(path: derived, mode: .dictation)?.precision, "8b")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: imported + "/model.safetensors"), encoding: .utf8), "weights")
    }

    /// An earlier version's uniform manifest for a tier that is now mixed is rewritten at launch, in place and only
    /// when it differs; startup preload and on-demand dictation of that recorded folder then run the new recipe.
    @MainActor func testUpgradedDerivedManifestIsRewrittenAtLaunch() throws {
        let (controller, bridge, runtime, model, imported) = try setUp(rootInstalled: true)
        defer { model.shutdown() }
        // No import this time: the old derived folder sits at the canonical path.
        try FileManager.default.removeItem(atPath: imported)
        controller.dictation.installed["beta-8bit"] = nil
        let source = try XCTUnwrap(controller.dictation.installed["beta-fp16"]?.path)
        let old = controller.dictation.modelsDirectory.appendingPathComponent("beta-8bit")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        // The uniform manifest an earlier version wrote (no floatModules).
        let uniform = Data(
            #"{"bits":8,"family":"beta","groupSize":64,"precision":"8b","schema":1,"source":"\#(source)","sourcePrecision":"FP16","sourceVariant":"beta-fp16"}"#.utf8)
        try uniform.write(to: old.appendingPathComponent(DerivedModelManifest.fileName))
        let catalog = ModelCatalog(schema: 2, families: [beta])
        XCTAssertEqual(migrateDerivedManifests(catalog: catalog, modelsDirectory: controller.dictation.modelsDirectory), [old.standardizedFileURL.path])
        XCTAssertEqual(derivedModelManifest(at: old)?.floatModules, ["model.encoder"])
        let file = old.appendingPathComponent(DerivedModelManifest.fileName)
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(migrateDerivedManifests(catalog: catalog, modelsDirectory: controller.dictation.modelsDirectory), [], "only when it differs")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, written)
        // Same folder for Load, on-demand dictation and preload.
        let path = old.standardizedFileURL.path
        XCTAssertEqual(try tableLoadPath(controller), path)
        XCTAssertEqual(bridge.ref(path: path, mode: .dictation)?.path, path)
        XCTAssertEqual(runtime.launchRef(ModelRef(id: "beta", precision: "8b", path: path, mode: .dictation, name: "Beta"))?.path, path)
        // A stale manifest that was not migrated (e.g. outside the models folder) still resolves to the current recipe.
        let elsewhere = root.appendingPathComponent("older-data/beta-8bit")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try uniform.write(to: elsewhere.appendingPathComponent(DerivedModelManifest.fileName))
        XCTAssertEqual(bridge.ref(path: elsewhere.path, mode: .dictation)?.path, path)
        XCTAssertNotNil(bridge.recipeRefusal(path: elsewhere.path, mode: .dictation), "the stale folder itself never starts a worker")
        XCTAssertNil(bridge.recipeRefusal(path: path, mode: .dictation))
    }

    /// Re-check regression: a stale external uniform manifest (an older data directory) whose 16-bit source files still
    /// exist but are not registered in this library. The table says Get; the bridge, the launch-set preload, the
    /// table's identity, the API and every worker start refuse it too; nothing runs the uniform recipe as the mixed tier.
    @MainActor func testStaleExternalManifestWithoutTheRegisteredSourceIsRefusedEverywhere() async throws {
        let (controller, bridge, runtime, model, imported) = try setUp(rootInstalled: true)
        defer { model.shutdown() }
        try FileManager.default.removeItem(atPath: imported)
        controller.dictation.installed["beta-8bit"] = nil
        let source = try XCTUnwrap(controller.dictation.installed["beta-fp16"]?.path)
        controller.dictation.installed["beta-fp16"] = nil // unregistered; its files stay
        try JSONEncoder().encode(controller.dictation.installed).write(to: controller.dictation.registryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source + "/config.json"))
        let elsewhere = root.appendingPathComponent("older-data/beta-8bit")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(
            #"{"bits":8,"family":"beta","groupSize":64,"precision":"8b","schema":1,"source":"\#(source)","sourcePrecision":"FP16","sourceVariant":"beta-fp16"}"#.utf8
        ).write(to: elsewhere.appendingPathComponent(DerivedModelManifest.fileName))
        let stale = elsewhere.path
        // Table: Get.
        XCTAssertFalse(controller.available(beta, "8b"))
        XCTAssertEqual(controller.action(beta), .get)
        XCTAssertNil(try tableLoadPath(controller))
        // Identity (launch clean-up, API's current model) and on-demand resolution: nothing.
        XCTAssertNil(controller.identify(path: stale, mode: .dictation))
        XCTAssertNil(bridge.ref(path: stale, mode: .dictation))
        XCTAssertNotEqual(runtime.resolve(stale, mode: .dictation).precision, "8b")
        // Launch-set preload: refused.
        XCTAssertNil(runtime.launchRef(ModelRef(id: "beta", precision: "8b", path: stale, mode: .dictation, name: "Beta")))
        // API: not listed.
        XCTAssertNil(ControllerModelSource(controller: controller, runtime: runtime).models().first { $0.id == "beta" })
        // Every worker start: refused with the table's reason, whatever identity the caller attached.
        let reason = try XCTUnwrap(bridge.recipeRefusal(path: stale, mode: .dictation))
        XCTAssertTrue(reason.contains("Get"), reason)
        do {
            try await runtime.admit(ModelRef(id: "beta", precision: "8b", path: stale, mode: .dictation, name: "Beta"))
            XCTFail("admitted a stale recipe")
        } catch { XCTAssertTrue("\(error)".contains("Get"), "\(error)") }
        do {
            try await runtime.admit(runtime.resolve(stale, mode: .dictation))
            XCTFail("admitted the stale folder under a generic identity")
        } catch {}
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent(DerivedModelManifest.fileName), encoding: .utf8).contains("floatModules"), false,
                       "the stale manifest outside the models folder is left as it is")
    }

    /// Re-check regression: a failed canonical preparation (both `<id>` and `<id>.derived` hold real weights) refuses
    /// the load instead of falling back to the recorded files.
    @MainActor func testFailedCanonicalPreparationRefusesTheLoad() throws {
        let (controller, bridge, runtime, model, imported) = try setUp(rootInstalled: true)
        defer { model.shutdown() }
        let occupied = controller.dictation.modelsDirectory.appendingPathComponent("beta-8bit.derived")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: occupied.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try tableLoadPath(controller))
        XCTAssertNil(bridge.runnablePath(beta, "8b"))
        XCTAssertNil(bridge.ref(path: imported, mode: .dictation))
        XCTAssertNil(runtime.launchRef(ModelRef(id: "beta", precision: "8b", path: imported, mode: .dictation, name: "Beta")))
        XCTAssertNotNil(bridge.recipeRefusal(path: imported, mode: .dictation))
        XCTAssertNil(controller.identify(path: imported, mode: .dictation))
    }
}
