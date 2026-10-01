import Foundation
import XCTest
@testable import Vella
import VellaCore
import VellaTestSupport

final class ModelDeletionControlTests: XCTestCase {
    @MainActor private func fixture() throws -> TwoFamilyFixture {
        try Integration.require()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-delete-controls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try TwoFamilyFixture(root)
    }
    @MainActor func testDeleteWithoutConsentPrintsWhatAndSizeAndPreservesFiles() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let path = try f.path(f.alpha, "BF16")
        let size = try XCTUnwrap(Runtime.folderBytes(path))
        let registry = try Data(contentsOf: f.controller.dictation.registryURL)
        f.controller.dictation.trashModel = { _ in XCTFail("unconfirmed Delete reached Trash"); throw CocoaError(.fileWriteNoPermission) }
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": false])
            XCTFail("Delete without yes must refuse")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "deletion_consent_required")
            XCTAssertTrue(error.message.contains("Alpha") && error.message.contains(formatExactBytes(size)))
            XCTAssertTrue(error.message.contains("Trash") && error.message.contains("Recordings and transcripts are kept"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: f.controller.dictation.registryURL), registry)
    }
    @MainActor func testDeleteUsesTheGateForRecordingPinnedAndSelectedModels() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        try await f.load(f.alpha, "BF16")
        let selectedReason = try XCTUnwrap(f.controller.dictation.deletionBlockReason("alpha-bf16"))
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": true])
            XCTFail("selected model must be protected")
        } catch let error as APIError { XCTAssertEqual(error.message, selectedReason) }
        try await f.load(f.zeta, "BF16")
        f.runtime.pin("alpha")
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": true])
            XCTFail("in-use model must be protected")
        } catch let error as APIError { XCTAssertEqual(error.message, modelDeletionBusyHelp) }
        f.runtime.unpin("alpha")
        f.controller.dictation.mayChangeModel = { false }
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": true])
            XCTFail("recording gate must refuse")
        } catch let error as APIError { XCTAssertEqual(error.message, modelDeletionBusyHelp) }
        XCTAssertTrue(f.controller.available(f.alpha, "BF16"))
        XCTAssertTrue(f.runtime.isLoaded("alpha"))
    }
    @MainActor func testConfirmedDeleteUsesFixtureTrashAndRemovesDependentRecipesOnly() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let source = try f.path(f.zeta, "BF16")
        let derived = try f.path(f.zeta, "4b")
        let trash = f.root.appendingPathComponent("fixture-trash")
        let recording = f.runtime.support.appendingPathComponent("recording-to-keep.txt")
        try Data("keep recording".utf8).write(to: recording)
        f.controller.dictation.trashModel = { item in
            try FileManager.default.moveItem(at: item, to: trash)
            return trash
        }
        _ = try await controls.perform("delete", id: "zeta", fields: ["precision": "bf16", "yes": true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived))
        XCTAssertTrue(f.controller.available(f.alpha, "BF16"), "another family was not deleted")
        XCTAssertEqual(try Data(contentsOf: recording), Data("keep recording".utf8))
    }
    @MainActor func testFailedTrashRestoresAnIdleManualModelAndItsRegistry() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        try await f.load(f.alpha, "BF16")
        try await f.load(f.zeta, "BF16")
        let registry = try Data(contentsOf: f.controller.dictation.registryURL)
        f.controller.dictation.trashModel = { _ in throw CocoaError(.fileWriteNoPermission) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": true])
            XCTFail("failed Trash must refuse")
        } catch let error as APIError { XCTAssertEqual(error.status, 409) }
        XCTAssertTrue(f.runtime.isLoaded("alpha"))
        XCTAssertTrue(f.controller.available(f.alpha, "BF16"))
        XCTAssertEqual(try Data(contentsOf: f.controller.dictation.registryURL), registry)
    }
    @MainActor func testDeleteRejectsPathInjectionAndLinkedWeightsWithoutMovingThem() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": true, "path": f.root.path])
            XCTFail("caller paths must be rejected")
        } catch let error as APIError { XCTAssertEqual(error.status, 400) }
        let own = URL(fileURLWithPath: try f.path(f.alpha, "BF16"))
        let outside = f.root.appendingPathComponent("outside-models")
        try FileManager.default.moveItem(at: own, to: outside)
        try FileManager.default.createSymbolicLink(at: own, withDestinationURL: outside)
        let reason = try XCTUnwrap(f.controller.dictation.deletionBlockReason("alpha-bf16"))
        do {
            _ = try await controls.perform("delete", id: "alpha", fields: ["precision": "bf16", "yes": true])
            XCTFail("linked weights must be preserved")
        } catch let error as APIError { XCTAssertEqual(error.message, reason) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

}
