import XCTest
import AppKit
@testable import Vella
@testable import VellaCore

/// The menu header names the model the next dictation uses, including a precision made on this Mac.
final class MenuHeaderModelTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-header-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor func testModelsTableLoadClearsFirstDictationOfferEvenOnStockMLX() async throws {
        _ = NSApplication.shared
        let f = try TwoFamilyFixture(root); defer { f.close() }
        let delegate = AppDelegate(model: f.model)
        delegate.modelsMenu = delegate.makeModelsMenu(controller: f.controller)
        f.bridge.attach(delegate)
        let session = try RecordingSession(root: root.appendingPathComponent("recordings"), config: Configuration(model: ""))
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 16000).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        f.model.recover(session.directory)
        for _ in 0..<250 where f.model.pendingModelRequest == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(f.model.pendingModelRequest)
        try await f.load(f.alpha, "BF16")
        XCTAssertEqual(f.runtime.status.models["alpha"]?.engine, "mlx")
        XCTAssertNil(f.model.pendingModelRequest, "a ready stock worker satisfies the offer just as an optimized worker does")
        XCTAssertFalse(f.model.message.contains("Choose Get"), f.model.message)
        delegate.rebuildMenu()
        XCTAssertNil(delegate.pendingModelRow())
        XCTAssertFalse(delegate.menu.items.contains { $0.title.hasPrefix("Get ") })
        XCTAssertTrue(delegate.menu.items.contains { $0.title.hasPrefix("1 model loaded") })
        XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.config.model, try f.path(f.alpha, "BF16"))
        f.model.retry()
        for _ in 0..<250 where f.model.phase != .success { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(f.model.phase, .success, f.model.message)
        XCTAssertNil(f.model.pendingModelRequest)
    }

    @MainActor func testRecoveringOldNoModelRecordingAfterRelaunchUsesReadySelectedModel() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        let session = try RecordingSession(root: root.appendingPathComponent("old"), config: Configuration(model: ""))
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        try await f.load(f.alpha, "BF16")
        f.model.recover(session.directory)
        for _ in 0..<250 where f.model.savedSession == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(f.model.pendingModelRequest, "an already-ready worker also satisfies an offer created after load")
        XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.config.model, try f.path(f.alpha, "BF16"))
        XCTAssertEqual(f.model.phase, .failed, "recovery is still an explicit clipboard-only Retry")
    }

    @MainActor func testHeaderNamesTheSelectedDerivedModelNotAnotherLoadedFamily() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "4b")
        try await f.load(f.zeta, "4b")
        XCTAssertTrue(f.runtime.isLoaded("alpha"), "Alpha stays loaded beside the current model")
        XCTAssertEqual(f.controller.activeLabel(.dictation), "Zeta int4")

        // Unloaded but still selected: the header keeps naming it, not the other loaded family.
        await f.runtime.unload("zeta")
        XCTAssertFalse(f.runtime.isLoaded("zeta"))
        XCTAssertEqual(try f.config().model, f.controller.dictation.activeModelPath)
        XCTAssertEqual(f.controller.activeLabel(.dictation), "Zeta int4")
    }
}
