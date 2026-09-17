import XCTest
import AppKit
import VellaCore
@testable import Vella

final class SettingsMenuTests: XCTestCase {
    @MainActor private func trackingTimer(_ delay: TimeInterval, action: @escaping @MainActor () -> Void) -> Timer {
        Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    @MainActor func testModeControlUpdatesWithoutReplacingTrackedMenus() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-menu-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let delegate = AppDelegate(model: model)
        delegate.rebuildMenu()
        let originalItems = delegate.menu.items
        let modes = try XCTUnwrap(delegate.menu.item(withTitle: "Mode")?.submenu)
        let streaming = try XCTUnwrap(modes.item(withTitle: "Streaming") as? SettingsMenuItem)
        let dictation = try XCTUnwrap(modes.item(withTitle: "Dictation") as? SettingsMenuItem)
        delegate.menuWillOpen(delegate.menu)
        streaming.control.performClick(nil)
        XCTAssertEqual(model.mode, .streaming)
        XCTAssertEqual(streaming.control.state, .on)
        XCTAssertEqual(dictation.control.state, .off)
        delegate.menuNeedsUpdate(delegate.menu)
        XCTAssertTrue(delegate.menu.item(withTitle: "Mode")?.submenu === modes)
        XCTAssertEqual(delegate.menu.items.count, originalItems.count)
        for (before, after) in zip(originalItems, delegate.menu.items) { XCTAssertTrue(before === after) }
        XCTAssertNotNil(delegate.menu.item(withTitle: "Start Streaming"))
        let table = try XCTUnwrap(delegate.menu.item(withTitle: "Models…")?.submenu?.items.first?.view as? MenuTableHostingView)
        XCTAssertEqual(table.rootView.library.mode, .streaming)
        dictation.control.performClick(nil)
        XCTAssertEqual(model.mode, .dictation)
        XCTAssertEqual(dictation.control.state, .on)
        // Repeated selection remains selected, not an invalid no-mode state.
        dictation.control.performClick(nil)
        XCTAssertEqual(dictation.control.state, .on)
        model.phase = .recording
        streaming.control.performClick(nil)
        XCTAssertEqual(model.mode, .dictation)
        delegate.menuDidClose(delegate.menu)
        model.phase = .idle
    }
    @MainActor func testNativeTrackingKeepsControlClickOpenAndEscapeDismisses() throws {
        guard ProcessInfo.processInfo.environment["VELLA_MENU_TRACKING_QA"] == "1" else { throw XCTSkip("Opt-in native menu interaction") }
        _ = NSApplication.shared
        let target = MenuSelectionProbe()
        let item = SettingsMenuItem(title: "Local menu QA", target: target, action: #selector(MenuSelectionProbe.selected(_:)))
        item.synchronize()
        let menu = NSMenu(); menu.autoenablesItems = false; menu.addItem(item)
        var stayedOpen = false, escapeSent = false, timedOut = false
        let click = trackingTimer(0.15) {
            item.control.performClick(nil)
        }
        let escape = trackingTimer(0.5) {
            stayedOpen = item.view?.window?.isVisible == true && target.calls == 1
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: item.view?.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                escapeSent = true; NSApplication.shared.postEvent(event, atStart: true)
            }
        }
        let watchdog = trackingTimer(2) {
            timedOut = true; menu.cancelTracking()
        }
        for timer in [click, escape, watchdog] { RunLoop.main.add(timer, forMode: .eventTracking) }
        defer { for timer in [click, escape, watchdog] { timer.invalidate() } }
        menu.popUp(positioning: nil, at: NSPoint(x: 300, y: 300), in: nil)
        XCTAssertTrue(stayedOpen, "Control click must not end native menu tracking")
        XCTAssertTrue(escapeSent)
        XCTAssertFalse(timedOut, "Native Escape must dismiss without our cancellation fallback")
    }
    @MainActor func testDisabledSettingsControlCannotDispatch() {
        _ = NSApplication.shared
        let item = SettingsMenuItem(title: "Disabled", target: NSObject(), action: NSSelectorFromString("unused"))
        item.isEnabled = false; item.state = .on; item.synchronize()
        XCTAssertFalse(item.control.isEnabled)
        XCTAssertEqual(item.control.state, .on)
    }
}

@MainActor private final class MenuSelectionProbe: NSObject {
    var calls = 0
    @objc func selected(_ sender: NSMenuItem) { calls += 1; sender.state = .on }
}
