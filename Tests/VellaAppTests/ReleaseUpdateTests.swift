import XCTest
import AppKit
@testable import Vella

final class ReleaseUpdateTests: XCTestCase {
    @MainActor private func store() -> (UserDefaults, String) {
        let name = "VellaReleaseTests.\(UUID())"
        return (UserDefaults(suiteName: name)!, name)
    }
    private func release(_ tag: String = "v0.8.6", draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
    }
    @MainActor func testDailyAttemptsSurviveRestartAndCacheClearsAfterUpgrade() async {
        let (defaults, name) = store(); defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let payload = release()
        let fetch: () async throws -> Data = { calls += 1; return payload }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = ReleaseUpdateChecker(currentVersion: "0.8.5", defaults: defaults, fetch: fetch)
        XCTAssertEqual(calls, 0); XCTAssertNil(checker.available)
        await checker.checkAfterUse(now: now)
        await checker.checkAfterUse(now: now.addingTimeInterval(1))
        XCTAssertEqual(calls, 1)
        let restarted = ReleaseUpdateChecker(currentVersion: "0.8.5", defaults: defaults, fetch: fetch)
        XCTAssertEqual(restarted.available?.tag, "v0.8.6")
        await restarted.checkAfterUse(now: now.addingTimeInterval(2))
        XCTAssertEqual(calls, 1)
        await restarted.checkAfterUse(now: now.addingTimeInterval(86400))
        XCTAssertEqual(calls, 2)
        let upgraded = ReleaseUpdateChecker(currentVersion: "0.8.6", defaults: defaults, fetch: fetch)
        XCTAssertNil(upgraded.available); XCTAssertEqual(calls, 2)
    }
    @MainActor func testFailuresDoNotRetryTodayOrClearKnownUpdate() async {
        let (defaults, name) = store(); defer { defaults.removePersistentDomain(forName: name) }
        let checker = ReleaseUpdateChecker(currentVersion: "0.8.5", defaults: defaults, fetch: { self.release() })
        let now = Date()
        await checker.checkAfterUse(now: now)
        var calls = 0
        let offline = ReleaseUpdateChecker(currentVersion: "0.8.5", defaults: defaults, fetch: {
            calls += 1; throw URLError(.notConnectedToInternet)
        })
        await offline.checkAfterUse(now: now.addingTimeInterval(86400))
        await offline.checkAfterUse(now: now.addingTimeInterval(86401))
        XCTAssertEqual(calls, 1); XCTAssertEqual(offline.available?.tag, "v0.8.6")
    }
    @MainActor func testStableNumericComparisonAndUntrustedTags() async {
        let samples: [(Data, String?)] = [
            (release("v0.8.5"), nil), (release("v0.8.4"), nil),
            (release("v0.8.10"), "v0.8.10"), (release("v0.9.0"), "v0.9.0"),
            (release("v1.0.0", draft: true), nil), (release("v1.0.0", prerelease: true), nil),
            (release("v1.0.0-beta"), nil), (release("../other"), nil),
            (release("v01.0.0"), nil), (Data("{}".utf8), nil)
        ]
        for (data, expected) in samples {
            let (defaults, name) = store(); defer { defaults.removePersistentDomain(forName: name) }
            let checker = ReleaseUpdateChecker(currentVersion: "0.8.5", defaults: defaults, fetch: { data })
            await checker.checkAfterUse()
            XCTAssertEqual(checker.available?.tag, expected)
        }
    }
    @MainActor func testNoRequestsForInvalidInstalledVersion() async {
        let (defaults, name) = store(); defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let checker = ReleaseUpdateChecker(currentVersion: "", defaults: defaults, fetch: { calls += 1; return self.release() })
        await checker.checkAfterUse()
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testYellowMenuPlacementAndBrowserOnlyAction() async throws {
        let (defaults, name) = store(); defer { defaults.removePersistentDomain(forName: name) }
        let checker = ReleaseUpdateChecker(currentVersion: "0.8.5", defaults: defaults, fetch: { self.release() })
        let model = Model(configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"))
        let delegate = AppDelegate(model: model, releaseUpdates: checker)
        delegate.rebuildMenu()
        XCTAssertFalse(delegate.menu.items.contains { $0.title.hasPrefix("Update available") })
        await checker.checkAfterUse()
        delegate.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(delegate.status) }
        delegate.refreshUpdateIndicator()
        XCTAssertEqual(delegate.status.button?.contentTintColor, NSColor.systemYellow)
        let index = try XCTUnwrap(delegate.menu.items.firstIndex { $0.title == "Support the developer…" })
        let item = delegate.menu.items[index-1]
        XCTAssertEqual(item.title, "Update available — v0.8.6…")
        XCTAssertEqual(item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemYellow)
        let opened = expectation(description: "Only release page opens")
        delegate.openExternalURL = { url in
            XCTAssertEqual(url.absoluteString, "https://github.com/TobyNoSkillSon/Vella/releases/tag/v0.8.6")
            opened.fulfill(); return true
        }
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: delegate, from: item))
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(checker.available?.tag, "v0.8.6") // Clicking does not dismiss it.
        XCTAssertEqual(model.phase, .idle)
    }
}
