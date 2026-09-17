import XCTest
import AppKit
import VellaCore
@testable import Vella

private final class CleanupRegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    var rejectEventTap = false
    var press: (() -> Void)?
    var release: (() -> Void)?
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        if rejectEventTap && config.trigger.requiresEventTap { throw VellaError.message("Synthetic registration failure") }
        registered = config; press = onPress; release = onRelease
    }
    func unregister() { registered = nil; press = nil; release = nil }
}

@MainActor final class FinalCleanupUITests: XCTestCase {
    func testTrackedShortcutStatusAndEquivalentKeepTheirIdentities() throws {
        _ = NSApplication.shared
        let model = Model(configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"))
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let registrar = CleanupRegistrar()
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: registrar)
        let suite = "VellaCleanupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = ReleaseUpdateChecker(currentVersion: "", defaults: defaults, fetch: { Data() })
        let delegate = AppDelegate(model: model, releaseUpdates: updates, shortcutManager: manager)
        // Assemble only the affected menu surface: no model catalog, microphone
        // enumeration, live settings, native registration or menu tracking loop.
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
        let items = menu.items
        let note = try XCTUnwrap(items.first { $0.identifier == ShortcutMenuFactory.permissionNoteID })
        let settings = try XCTUnwrap(items.first { $0.identifier == ShortcutMenuFactory.settingsID })
        let error = try XCTUnwrap(items.first { $0.identifier == ShortcutMenuFactory.errorID })
        let modifier = try XCTUnwrap(menu.item(withTitle: "Modifier-Only")?.submenu?.item(withTitle: "Left ⌥") as? SettingsMenuItem)
        let reset = try XCTUnwrap(menu.item(withTitle: "Reset to Default"))
        delegate.menuWillOpen(delegate.menu)
        defer { delegate.menuDidClose(delegate.menu) }
        XCTAssertTrue(note.isHidden && settings.isHidden && error.isHidden)
        modifier.control.performClick(nil)
        XCTAssertEqual(manager.configuration.trigger, .modifierOnly(key: .option, side: .left))
        XCTAssertEqual(modifier.state, .on)
        XCTAssertEqual(start.keyEquivalent, "")
        XCTAssertEqual(start.keyEquivalentModifierMask, [])
        XCTAssertFalse(note.isHidden || settings.isHidden)
        XCTAssertTrue(error.isHidden)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(reset.action), to: delegate, from: reset))
        XCTAssertEqual(manager.configuration, .default)
        XCTAssertEqual(start.keyEquivalent, "n")
        XCTAssertEqual(start.keyEquivalentModifierMask, [.control, .command])
        XCTAssertTrue(note.isHidden && settings.isHidden && error.isHidden)
        registrar.rejectEventTap = true
        modifier.control.performClick(nil)
        XCTAssertEqual(manager.configuration, .default)
        XCTAssertEqual(modifier.state, .off)
        XCTAssertEqual(start.keyEquivalent, "n")
        XCTAssertFalse(error.isHidden)
        XCTAssertEqual(error.title, "Synthetic registration failure")
        XCTAssertEqual(error.toolTip, manager.lastError)
        XCTAssertTrue(note.isHidden && settings.isHidden)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(reset.action), to: delegate, from: reset))
        XCTAssertTrue(error.isHidden)
        XCTAssertNil(error.toolTip)
        XCTAssertTrue(root.submenu === menu)
        XCTAssertTrue(delegate.menu.items.first === start)
        XCTAssertEqual(items.count, menu.items.count)
        for (before, after) in zip(items, menu.items) { XCTAssertTrue(before === after) }
        XCTAssertTrue(menu.item(withTitle: "Modifier-Only")?.submenu?.item(withTitle: "Left ⌥") === modifier)
    }

    func testFallbackPreservesHoldAndTapOrHoldBehavior() {
        for behavior in [ShortcutBehavior.holdToTalk, .tapOrHold] {
            var time = 0.0, starts = 0, finishes = 0
            var recording = false
            let desired = ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .left), behavior: behavior)
            let engine = ShortcutEngine(configuration: desired, sinks: .init(
                start: { starts += 1; recording = true }, finish: { finishes += 1; recording = false }, cancel: {},
                isRecording: { recording }, isBusy: { false }), now: { time })
            let registrar = CleanupRegistrar(); registrar.rejectEventTap = true
            let store = ShortcutStore(initial: desired)
            let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
            XCTAssertFalse(manager.registerStoredOrDefault())
            XCTAssertTrue(manager.isUsingFallback)
            XCTAssertEqual(manager.configuration, desired)
            XCTAssertEqual(store.configuration, desired)
            XCTAssertEqual(manager.activeConfiguration, .init(trigger: ShortcutConfiguration.default.trigger, behavior: behavior))
            XCTAssertEqual(registrar.registered, manager.activeConfiguration)
            XCTAssertEqual(engine.configuration.behavior, behavior)
            registrar.press?(); time = 0.1; registrar.release?()
            XCTAssertEqual(starts, 1)
            if behavior == .tapOrHold {
                XCTAssertTrue(recording); XCTAssertEqual(finishes, 0)
                time = 0.2; registrar.press?(); time = 0.25; registrar.release?()
            }
            XCTAssertFalse(recording); XCTAssertEqual(finishes, 1)
            time = 1; registrar.press?(); time = 1.5; registrar.release?()
            XCTAssertEqual(starts, 2); XCTAssertEqual(finishes, 2)
        }
    }

    func testPermissionRecoveryAndRecordingAccessibilityCopy() {
        var prompts = 0
        let permission = InsertionPermission(isTrusted: { false }, prompt: { prompts += 1 },
            history: PermissionPromptHistory(read: { true }, write: {}))
        let model = Model(insertionPermission: permission,
            configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"))
        XCTAssertFalse(model.ensureAutomaticInsertion())
        XCTAssertEqual(prompts, 0)
        XCTAssertTrue(model.message.contains("Click “Accessibility required” in Vella’s menu."))
        XCTAssertFalse(model.message.contains("Enable Automatic Insertion"))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.recorder.url)
        model.phase = .recording
        model.shortcutHint = "Left ⌥"
        XCTAssertEqual(HUDView(model: model).recordingAccessibilityLabel, "Vella is recording.")
        model.phase = .idle
        XCTAssertEqual(HUDView(model: model).recordingAccessibilityLabel, model.title)
    }
}
