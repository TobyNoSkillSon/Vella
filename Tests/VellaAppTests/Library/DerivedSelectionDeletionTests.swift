import XCTest
import AppKit
@testable import Vella
@testable import VellaCore

/// Deleting the weights a selected precision made on this Mac reads is refused, as deleting the selected model itself
/// is: the selection must never be left pointing at a model that can no longer load.
final class DerivedSelectionDeletionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-derived-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(5)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }

    /// Through the table: the Delete button shows why, and nothing is unloaded, moved or deselected.
    @MainActor func testTableRefusesToDeleteTheSourceOfTheSelectedDerivedModel() async throws {
        _ = NSApplication.shared
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.zeta, "4b")
        let library = f.controller.dictation
        let selected = try f.config().model
        let source = try f.path(f.zeta, "BF16")
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: selected))?.source, source)
        let pid = try XCTUnwrap(f.runtime.status.models["zeta"]?.pid)
        var trashed: [URL] = []
        library.trashModel = {
            trashed.append($0); throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertNotNil(library.deletionBlockReason("zeta-bf16"))
        let menus = ModelsMenu(controller: f.controller)
        let host = try XCTUnwrap(menus.modelItem().submenu?.items.first?.view as? MenuTableHostingView)
        var alerts: [String] = []
        menus.presentDeletionConfirmation = { alert in
            alerts.append(alert.messageText); return .alertSecondButtonReturn
        }
        f.controller.preview(f.zeta, "BF16")
        host.rootView.requestDelete(f.zeta)
        try await waitUntil { !alerts.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(alerts, ["Model cannot be deleted here"])
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(try f.config().model, selected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        XCTAssertEqual(f.runtime.status.models["zeta"]?.pid, pid, "the selected model was not unloaded")
    }

    /// Through the runtime's ordered delete (unload, delete, clean-up): the refused deletion restores the loaded model,
    /// and the selection, the source and the derived directory are untouched; the next recording's model still exists.
    @MainActor func testRefusedSourceDeletionRestoresTheSelectedDerivedModel() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.zeta, "4b")
        let library = f.controller.dictation
        let source = try f.path(f.zeta, "BF16")
        let selected = try f.config().model
        let trash = root.appendingPathComponent("trash")
        library.trashModel = { item in
            try FileManager.default.moveItem(at: item, to: trash); return trash
        }
        let removed = await f.bridge.delete(family: f.zeta, path: source) {
            guard library.deleteModel("zeta-bf16", expectedPath: source, expectedInstalled: true) else { return false }
            removeDerivedModels(sourcePath: source, modelsDirectory: library.modelsDirectory)
            return true
        }
        XCTAssertFalse(removed)
        let after = try f.config()
        XCTAssertEqual(after.model, selected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: after.model), "the selection points at an existing model")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        XCTAssertEqual(f.source.models().filter(\.current).count, 1, "the API still has its current model")
        XCTAssertEqual(f.runtime.loadedRef("zeta")?.path, selected, "the unloaded model came back")
        XCTAssertEqual(try after.forRecording().model, selected)
    }

    /// Streaming selections are protected the same way.
    @MainActor func testStreamingSelectionOfADerivedModelProtectsItsSource() throws {
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let nemo = ModelFamily(
            id: "nemo", name: "Nemo", mode: .streaming, languages: ["en"], params: "0.6B", license: "test", native: "BF16",
            variants: [
                "BF16": CatalogVariant(id: "nemo-bf16", repository: "org/n", revision: String(repeating: "e", count: 40), downloadBytes: 1000, architecture: "nemotron_asr"),
                "4b": CatalogVariant(id: "nemo-derived", architecture: "nemotron_asr", derivedFrom: "BF16", bits: 4, groupSize: 64)
            ])
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [nemo])).write(to: resources.appendingPathComponent("models.json"))
        let registry = root.appendingPathComponent("support/models-installed.json")
        let library = ModelLibrary(mode: .streaming, resources: resources, registryURL: registry)
        let folder = library.modelsDirectory.appendingPathComponent("nemo-bf16")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"model_type":"nemotron_asr"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        library.installed["nemo-bf16"] = InstalledModel(path: folder.path)
        let derived = try prepareDerivedModel(family: nemo, precision: "4b", sourcePath: folder.path, modelsDirectory: library.modelsDirectory)
        library.currentModelPath = { "" }
        library.protectedModelPaths = { ["", derived] }
        XCTAssertNotNil(library.deletionBlockReason("nemo-bf16"))
        library.protectedModelPaths = { ["", ""] }
        XCTAssertNil(library.deletionBlockReason("nemo-bf16"), "unselected, the source can go")
    }
}
