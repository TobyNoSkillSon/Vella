import XCTest
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
