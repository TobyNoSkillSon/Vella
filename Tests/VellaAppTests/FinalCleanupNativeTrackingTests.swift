import XCTest
import AppKit
import VellaCore
@testable import Vella

private final class CleanupTrackingRegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    var rejectModifiers = false
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        if rejectModifiers && config.trigger.requiresEventTap {
            throw VellaError.message("Synthetic registration failure")
        }
        registered = config
    }
    func unregister() { registered = nil }
}

final class FinalCleanupNativeTrackingTests: XCTestCase {
    /// A fixture popup only: no app launch, event posting, Carbon/tap registration,
    /// model catalog reload, microphone enumeration or permission requests.
    @MainActor func testShortcutStatusReflowsDuringNativeTracking() throws {
        guard ProcessInfo.processInfo.environment["VELLA_MENU_TRACKING_QA"] == "1" else {
            throw XCTSkip("Opt-in native menu tracking")
        }
        _ = NSApplication.shared
        let model = Model(configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"))
        let engine = ShortcutEngine(configuration: .default, sinks: .init(
            start: { XCTFail("Fixture must not start recording") }, finish: { XCTFail("Fixture must not finish recording") },
            cancel: {}, isRecording: { false }, isBusy: { false }))
        let registrar = CleanupTrackingRegistrar()
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: registrar)
        let suite = "VellaCleanupTracking.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = ReleaseUpdateChecker(currentVersion: "", defaults: defaults, fetch: { Data() })
        let delegate = AppDelegate(model: model, releaseUpdates: updates, shortcutManager: manager)
        let start = NSMenuItem(title: "Start Dictation", action: NSSelectorFromString("toggle"), keyEquivalent: "n")
        start.keyEquivalentModifierMask = [.control, .command]
        delegate.menu.addItem(start)
        let root = ShortcutMenuFactory.shortcutsItem(manager: manager, model: model, target: delegate,
            selectBehavior: NSSelectorFromString("selectShortcutBehavior:"), recordKeys: NSSelectorFromString("recordShortcutKeys"),
            cancelCapture: NSSelectorFromString("cancelShortcutCapture"), selectModifier: NSSelectorFromString("selectShortcutModifier:"),
            selectMouse: NSSelectorFromString("selectShortcutMouse:"), resetDefault: NSSelectorFromString("resetShortcutDefault"),
            openSettings: NSSelectorFromString("accessibility"))
        delegate.menu.addItem(root)
        let menu = try XCTUnwrap(root.submenu)
        let original = menu.items
        let anchor = try XCTUnwrap(menu.item(withTitle: "Toggle") as? SettingsMenuItem)
        let modifier = try XCTUnwrap(menu.item(withTitle: "Modifier-Only")?.submenu?.item(withTitle: "Left ⌥") as? SettingsMenuItem)
        let reset = try XCTUnwrap(menu.item(withTitle: "Reset to Default"))
        let resetAction = try XCTUnwrap(reset.action)
        let note = try XCTUnwrap(menu.items.first { $0.identifier == ShortcutMenuFactory.permissionNoteID })
        let settings = try XCTUnwrap(menu.items.first { $0.identifier == ShortcutMenuFactory.settingsID })
        let error = try XCTUnwrap(menu.items.first { $0.identifier == ShortcutMenuFactory.errorID })
        var baselineHeight: CGFloat?
        var resetDispatched = false, completed = false, timedOut = false
        var stage = "created"
        var timers: [Timer] = []
        func inspectWindow(_ label: String) -> CGFloat? {
            stage = label
            guard let window = anchor.view?.window else {
                print("[cleanup-tracking] \(label): no hosting window")
                XCTFail("Native popup must host the original control"); return nil
            }
            print("[cleanup-tracking] \(label): visible=\(window.isVisible) height=\(window.frame.height) hidden(note/settings/error)=\(note.isHidden)/\(settings.isHidden)/\(error.isHidden)")
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(root.submenu === menu)
            XCTAssertTrue(delegate.menu.items.first === start)
            XCTAssertEqual(original.count, menu.items.count)
            for (before, after) in zip(original, menu.items) { XCTAssertTrue(before === after) }
            return window.frame.height
        }
        // The MainActor closure owns menu references; Timer's Sendable callback
        // captures only that isolated closure, including for the watchdog.
        func schedule(delay: TimeInterval = 0.25, _ action: @escaping @MainActor () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
            timers.append(timer)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        func popup() {
            schedule(delay: 5) {
                timedOut = true
                print("[cleanup-tracking] watchdog at \(stage)")
                menu.cancelTracking()
            }
            delegate.menuWillOpen(delegate.menu)
            menu.popUp(positioning: nil, at: NSPoint(x: 300, y: 300), in: nil)
            print("[cleanup-tracking] popup returned at \(stage), resetDispatched=\(resetDispatched), completed=\(completed)")
            for timer in timers { timer.invalidate() }
            timers.removeAll()
            delegate.menuDidClose(delegate.menu)
        }
        schedule {
            baselineHeight = inspectWindow("initial")
            XCTAssertTrue(note.isHidden && settings.isHidden && error.isHidden)
            stage = "selecting modifier"
            modifier.control.performClick(nil)
            print("[cleanup-tracking] modifier action returned")
            schedule {
                let expanded = inspectWindow("modifier visible after layout turn")
                XCTAssertFalse(note.isHidden || settings.isHidden)
                XCTAssertTrue(error.isHidden)
                XCTAssertEqual(manager.configuration.trigger, .modifierOnly(key: .option, side: .left))
                XCTAssertEqual(start.keyEquivalent, "")
                if let baselineHeight, let expanded {
                    XCTAssertGreaterThan(expanded, baselineHeight, "Permission rows must reflow the visible popup")
                }
                stage = "dispatching conventional Reset command"
                resetDispatched = true
                XCTAssertTrue(NSApplication.shared.sendAction(resetAction, to: delegate, from: reset))
                print("[cleanup-tracking] reset returned; window visible=\(anchor.view?.window?.isVisible == true)")
                // A conventional menu command may dismiss tracking. If synthetic
                // sendAction leaves it open, end only this fixture before reopening.
                schedule {
                    stage = "fixture dismissal after Reset"
                    menu.cancelTracking()
                }
            }
        }
        popup()
        XCTAssertTrue(resetDispatched, "Embedded modifier selection must keep tracking through its layout assertion; last stage: \(stage)")
        XCTAssertFalse(timedOut)
        guard resetDispatched, !timedOut else { return }

        // Reopen the SAME menu/items. Reset need not keep a native command menu
        // open, but its next presentation must show the updated default state.
        schedule {
            let collapsed = inspectWindow("Reset state in second popup")
            XCTAssertTrue(note.isHidden && settings.isHidden && error.isHidden)
            XCTAssertEqual(manager.configuration, .default)
            XCTAssertEqual(start.keyEquivalent, "n")
            XCTAssertEqual(start.keyEquivalentModifierMask, [.control, .command])
            if let baselineHeight, let collapsed {
                XCTAssertEqual(collapsed, baselineHeight, accuracy: 2, "Hidden status restores original height")
            }
            registrar.rejectModifiers = true
            stage = "selecting rejected modifier"
            modifier.control.performClick(nil)
            print("[cleanup-tracking] rejected modifier action returned")
            schedule {
                let withError = inspectWindow("error visible after layout turn")
                XCTAssertTrue(note.isHidden && settings.isHidden)
                XCTAssertFalse(error.isHidden)
                XCTAssertEqual(error.title, "Synthetic registration failure")
                XCTAssertEqual(error.toolTip, manager.lastError)
                XCTAssertEqual(manager.configuration, .default)
                XCTAssertEqual(start.keyEquivalent, "n")
                XCTAssertEqual(modifier.state, .off)
                if let baselineHeight, let withError {
                    XCTAssertGreaterThan(withError, baselineHeight, "Error row must reflow the visible popup")
                }
                completed = true
                stage = "fixture dismissal after error assertion"
                menu.cancelTracking()
            }
        }
        popup()
        XCTAssertTrue(completed, "Rejected embedded selection must keep tracking through error layout; last stage: \(stage)")
        XCTAssertFalse(timedOut, "Fixture watchdog must not be the dismissal path")
    }
}
