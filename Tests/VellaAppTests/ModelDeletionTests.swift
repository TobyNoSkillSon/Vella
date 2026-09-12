import XCTest
import AppKit
@testable import Vella
@testable import VellaCore

final class ModelDeletionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }
    @MainActor private func fixture() throws -> (ModelLibrary, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-delete-\(UUID())")
        roots.append(root)
        let id = "Qwen3-ASR-1.7B-8bit"
        let folder = root.appendingPathComponent("Models/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture weights".utf8).write(to: folder.appendingPathComponent("weights.safetensors"))
        let registry = root.appendingPathComponent("models-installed.json")
        try JSONEncoder().encode([id: InstalledModel(path: folder.path)]).write(to: registry)
        let library = ModelLibrary(registryURL: registry)
        library.currentModelPath = { "/unrelated/active-model" }; library.activeModelPath = "/unrelated/active-model"
        library.trashModel = { source in
            let target = root.appendingPathComponent("fixture-trash")
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
        return (library, id, folder)
    }
    @MainActor func testDeleteKeepsReferencesAndOtherEntriesAndRevertsToInstall() throws {
        let (library, id, folder) = try fixture()
        XCTAssertTrue(library.displayedModels.contains { $0.id == id }, "Installed nonrecommended models must remain manageable")
        var registry = library.installed
        registry["other"] = InstalledModel(path: "/external/untouched")
        try JSONEncoder().encode(registry).write(to: library.registryURL)
        let references = library.references.count
        XCTAssertTrue(library.deleteModel(id, expectedPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(library.installed[id]); XCTAssertNotNil(library.installed["other"])
        XCTAssertEqual(library.references.count, references)
        XCTAssertNotNil(library.models.first { $0.id == id })
        let disk = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: library.registryURL))
        XCTAssertNil(disk[id]); XCTAssertNotNil(disk["other"])
    }
    @MainActor func testActiveBusyAndChangedConfirmationAreProtected() throws {
        let (library, id, folder) = try fixture()
        library.currentModelPath = { folder.path }
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        library.currentModelPath = { "/other" }; library.busy = true
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        library.busy = false; library.mayChangeModel = { false }
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        library.mayChangeModel = { true }
        XCTAssertFalse(library.deleteModel(id, expectedPath: "/changed/path"))
        library.currentModelPath = { throw CocoaError(.fileReadNoPermission) }
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    @MainActor func testExternalSharedAndSymlinkFoldersCannotBeTrashed() throws {
        let (library, id, folder) = try fixture()
        library.installed["alias"] = InstalledModel(path: folder.path)
        XCTAssertNotNil(library.deletionBlockReason(id))
        library.installed.removeValue(forKey: "alias")
        library.installed[id] = InstalledModel(path: folder.deletingLastPathComponent().path)
        XCTAssertNotNil(library.deletionBlockReason(id))
        library.installed[id] = InstalledModel(path: folder.path)
        let outside = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.moveItem(at: folder, to: outside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("weights.safetensors").path))
    }
    @MainActor func testTrashFailureAndRegistryFailurePreserveInstallation() throws {
        let (library, id, folder) = try fixture()
        let old = try Data(contentsOf: library.registryURL)
        let trash = library.trashModel
        library.trashModel = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        library.trashModel = trash
        library.writeRegistryData = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(library.deleteModel(id, expectedPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("weights.safetensors").path))
        XCTAssertNotNil(library.installed[id])
        XCTAssertEqual(try Data(contentsOf: library.registryURL), old)
    }
    @MainActor func testMissingFilesCanBeUnregisteredWithoutTouchingOtherFiles() throws {
        let (library, id, folder) = try fixture()
        try FileManager.default.removeItem(at: folder)
        library.trashModel = { _ in XCTFail("Missing files should not be trashed"); return folder }
        XCTAssertTrue(library.deleteModel(id, expectedPath: folder.path))
        XCTAssertNil(library.installed[id])
    }
    @MainActor func testTableActionRequiresConfirmationAndCancellationKeepsFiles() async throws {
        _ = NSApplication.shared
        let (library, id, folder) = try fixture()
        let menus = ModelsMenu(library: library)
        let root = menus.modelItem()
        let host = try XCTUnwrap(root.submenu?.items.first?.view as? MenuTableHostingView)
        var confirmations = 0
        menus.presentDeletionConfirmation = { alert in
            confirmations += 1
            XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Move to Trash"])
            return .alertFirstButtonReturn
        }
        host.rootView.requestDelete(id)
        for _ in 0..<100 { if confirmations > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        menus.presentDeletionConfirmation = { _ in confirmations += 1; return .alertSecondButtonReturn }
        host.rootView.requestDelete(id)
        for _ in 0..<100 { if confirmations > 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(confirmations, 2)
        XCTAssertNil(library.installed[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    @MainActor func testNativeTrashWithDisposableFixtureOnly() throws {
        let (library, id, folder) = try fixture()
        let native = ModelLibrary(registryURL: library.registryURL).trashModel
        var trashed: URL?
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        library.trashModel = { source in let target = try native(source); trashed = target; return target }
        XCTAssertTrue(library.deleteModel(id, expectedPath: folder.path))
        let destination = try XCTUnwrap(trashed)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("weights.safetensors")), Data("fixture weights".utf8))
    }
}
