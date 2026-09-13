import XCTest
import AppKit
@testable import Vella

final class SponsorshipTests: XCTestCase {
    @MainActor func testSupportImmediatelyPrecedesQuitAndOpensOnlySponsorsURL() async throws {
        let model = Model(configurationURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-vella-config-\(UUID()).json"))
        let delegate = AppDelegate(model: model)
        delegate.rebuildMenu()
        let items = delegate.menu.items
        let quit = try XCTUnwrap(items.firstIndex { $0.title == "Quit Vella" })
        XCTAssertGreaterThan(quit, 0)
        let support = items[quit - 1]
        XCTAssertEqual(support.title, "Support the developer…")
        XCTAssertEqual(support.keyEquivalent, "")
        XCTAssertNotNil(support.image)
        let opened = expectation(description: "Sponsors opened after menu tracking")
        var calls = 0
        delegate.openExternalURL = { url in
            calls += 1
            XCTAssertEqual(url.absoluteString, "https://github.com/sponsors/TobyNoSkillSon")
            opened.fulfill()
            return true
        }
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(support.action), to: delegate, from: support))
        XCTAssertEqual(calls, 0)
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.phase, .idle)
    }
}
