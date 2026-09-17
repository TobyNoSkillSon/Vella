import XCTest
import AppKit
@testable import Vella
@testable import VellaCore

final class SparkMockShortcutRegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    var shouldFail = false
    var failMessage = "Already reserved by another application."
    var registerCalls = 0
    var unregisterCalls = 0
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        registerCalls += 1
        if shouldFail { throw VellaError.message(failMessage) }
        registered = config
        self.onPress = onPress
        self.onRelease = onRelease
    }
    func unregister() {
        unregisterCalls += 1
        registered = nil
    }
    func firePress() { onPress?() }
    func fireRelease() { onRelease?() }
}

@MainActor
final class ShortcutTests: XCTestCase {
    private func managerWithEngine(behavior: ShortcutBehavior = .toggle, recording: Bool = false, busy: Bool = false, now: @escaping () -> TimeInterval = { 1000 }) -> (ShortcutManager, SparkMockShortcutRegistrar, RecordingState) {
        let state = RecordingState(recording: recording, busy: busy)
        let store = ShortcutStore(initial: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: behavior), fileURL: nil)
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { state.starts += 1; state.recording = true },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }), now: now)
        let registrar = SparkMockShortcutRegistrar()
        let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
        return (manager, registrar, state)
    }
    final class RecordingState {
        var recording: Bool
        var busy: Bool
        var starts = 0
        var finishes = 0
        var cancels = 0
        init(recording: Bool, busy: Bool) { self.recording = recording; self.busy = busy }
    }
    func testDefaultLabelAndApplyKeyChord() {
        let (manager, registrar, _) = managerWithEngine()
        XCTAssertEqual(manager.currentLabel, "⌃⌘N · Toggle")
        XCTAssertFalse(manager.requiresEventTap)
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .toggle)))
        XCTAssertTrue(registrar.registered?.trigger == ShortcutTrigger.keyChord(keyCode: 8, modifiers: 4352))
        XCTAssertNil(manager.lastError)
    }
    func testApplyValidationFailureKeepsPrevious() {
        let (manager, registrar, _) = managerWithEngine()
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(manager.configuration, ShortcutConfiguration.default)
        XCTAssertNil(registrar.registered) // never attempted
    }
    func testTransactionalRollbackOnRegistrarConflict() {
        let (manager, registrar, _) = managerWithEngine()
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .toggle)))
        registrar.shouldFail = true
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 9, modifiers: 4352), behavior: .toggle)))
        XCTAssertNotNil(manager.lastError)
        // Rolled back to previous binding and re-registered it.
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.keyChord(keyCode: 8, modifiers: 4352))
        XCTAssertTrue(manager.currentLabel.contains("C"))
    }
    func testResetToDefault() {
        let (manager, _, _) = managerWithEngine(behavior: .holdToTalk)
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk)))
        manager.resetToDefault()
        XCTAssertEqual(manager.configuration, ShortcutConfiguration.default)
    }
    func testCanEditDisabledWhileBusy() {
        let (manager, _, state) = managerWithEngine()
        XCTAssertTrue(manager.canEdit)
        state.recording = true
        XCTAssertFalse(manager.canEdit)
        state.recording = false; state.busy = true
        XCTAssertFalse(manager.canEdit)
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .toggle)))
        XCTAssertEqual(manager.lastError, "Finish or stop recording before changing shortcuts.")
    }
    func testHoldPressReleaseThroughRegistrar() {
        var t = 1000.0
        let (manager, registrar, state) = managerWithEngine(behavior: .holdToTalk, now: { t })
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk)))
        registrar.firePress()
        XCTAssertEqual(state.starts, 1)
        t += 0.5
        registrar.fireRelease()
        XCTAssertEqual(state.finishes, 1)
    }
    func testHoldReleaseDuringPreparingCancels() {
        let (manager, registrar, state) = managerWithEngine(behavior: .holdToTalk)
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk)))
        registrar.firePress()
        XCTAssertEqual(state.starts, 1)
        state.recording = false; state.busy = true // async preparing
        registrar.fireRelease()
        XCTAssertEqual(state.cancels, 1)
        XCTAssertEqual(state.finishes, 0)
    }
    func testModifierMouseRequireEventTapNote() {
        let (manager, _, _) = managerWithEngine()
        XCTAssertTrue(manager.apply(.init(trigger: .modifierOnly(key: .control, side: .left), behavior: .holdToTalk)))
        XCTAssertTrue(manager.requiresEventTap)
        XCTAssertTrue(manager.eventTapPermissionNote.contains("Accessibility"))
        XCTAssertFalse(manager.eventTapPermissionNote.contains("Input Monitoring"))
        XCTAssertTrue(manager.apply(.init(trigger: .mouseButton(button: .middle), behavior: .toggle)))
        XCTAssertTrue(manager.requiresEventTap)
    }
    func testKeyCaptureAppliesAndCancelsOnEscape() {
        let (manager, _, _) = managerWithEngine()
        manager.beginKeyCapture()
        XCTAssertTrue(manager.isCapturingKeys)
        XCTAssertTrue(manager.handleCapturedKey(keyCode: 8, modifiers: 4352))
        XCTAssertFalse(manager.isCapturingKeys)
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.keyChord(keyCode: 8, modifiers: 4352))
        manager.beginKeyCapture()
        manager.cancelKeyCapture()
        XCTAssertFalse(manager.isCapturingKeys)
    }
    func testShortcutsSubmenuImmediatelyBelowMicrophone() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-shortcut-menu-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let store = ShortcutStore(initial: ShortcutConfiguration.default, fileURL: nil)
        let state = RecordingState(recording: false, busy: false)
        let engine = ShortcutEngine(configuration: ShortcutConfiguration.default, sinks: .init(
            start: {}, finish: {}, cancel: {},
            isRecording: { state.recording }, isBusy: { state.busy }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: SparkMockShortcutRegistrar())
        let delegate = AppDelegate(model: model, shortcutManager: manager)
        delegate.rebuildMenu()
        let titles = delegate.menu.items.map(\.title)
        guard let mic = titles.firstIndex(of: "Microphone"),
              let shortcuts = titles.firstIndex(of: "Shortcuts") else {
            return XCTFail("Microphone/Shortcuts missing: \(titles)")
        }
        XCTAssertEqual(shortcuts, mic + 1, "Shortcuts must sit immediately below Microphone")
        let submenu = try XCTUnwrap(delegate.menu.items[shortcuts].submenu)
        let sub = submenu.items.map(\.title)
        XCTAssertTrue(sub.first?.contains("Current:") == true, "First item shows current binding: \(sub)")
        XCTAssertTrue(sub.contains("Toggle"))
        XCTAssertTrue(sub.contains("Hold to Talk"))
        XCTAssertTrue(sub.contains("Tap or Hold"))
        XCTAssertTrue(sub.contains("Record Key Chord…"))
        XCTAssertTrue(sub.contains("Reset to Default"))
        XCTAssertTrue(sub.contains("Modifier-Only"))
        XCTAssertTrue(sub.contains("Mouse Button"))
        let modifierSub = try XCTUnwrap(submenu.items.first(where: { $0.title == "Modifier-Only" })?.submenu)
        XCTAssertTrue(modifierSub.items.map(\.title).contains("Left ⌃"))
        let mouseSub = try XCTUnwrap(submenu.items.first(where: { $0.title == "Mouse Button" })?.submenu)
        XCTAssertTrue(mouseSub.items.map(\.title).contains("Middle Click"))
        // Behavior radios use keep-open controls.
        // Behavior radios use keep-open controls.
        XCTAssertTrue(submenu.items.contains(where: { ($0 as? SettingsMenuItem) != nil && $0.title == "Toggle" }))
        // Disabled while recording.
        state.recording = true
        delegate.rebuildMenu()
        let rebuilt = try XCTUnwrap(delegate.menu.item(withTitle: "Shortcuts")?.submenu)
        for item in rebuilt.items where item.title == "Toggle" || item.title == "Record Key Chord…" || item.title.contains("Reset to Default") {
            XCTAssertFalse(item.isEnabled, "\(item.title) must disable while recording")
        }
        state.recording = false
    }
    func testFactoryRestartPersistsThroughDelegateFactory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-shortcut-restart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("shortcuts.json")
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 64, modifiers: 6912), behavior: .holdToTalk)
        XCTAssertNil(ShortcutValidation.validate(custom))
        let model1 = Model(configurationURL: root.appendingPathComponent("config1.json"))
        defer { model1.shutdown() }
        let delegate1 = AppDelegate(model: model1, shortcutStoreURL: storeURL)
        XCTAssertTrue(delegate1.shortcutManager.apply(custom))
        XCTAssertEqual(delegate1.shortcutManager.configuration, custom)
        let model2 = Model(configurationURL: root.appendingPathComponent("config2.json"))
        defer { model2.shutdown() }
        let delegate2 = AppDelegate(model: model2, shortcutStoreURL: storeURL)
        delegate2.shortcutManager.reloadFromStore()
        XCTAssertEqual(delegate2.shortcutManager.configuration, custom)
    }
    final class TimeBox {
        var now: TimeInterval
        init(now: TimeInterval) { self.now = now }
    }
    private func fullRouteTap(behavior: ShortcutBehavior, key: ModifierKey = .control, side: ModifierSide = .left, time: TimeBox, state: RecordingState) -> (ShortcutManager, EventTapShortcutRegistrar) {
        let config = ShortcutConfiguration(trigger: .modifierOnly(key: key, side: side), behavior: behavior)
        let engine = ShortcutEngine(configuration: config, sinks: .init(
            start: { state.starts += 1; state.recording = true },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }), now: { time.now })
        let store = ShortcutStore(initial: config, fileURL: nil)
        let tap = EventTapShortcutRegistrar()
        tap.now = { time.now }
        let manager = ShortcutManager(engine: engine, store: store, registrar: tap)
        tap.primeForTesting(config, onPress: { manager.handlePress() }, onRelease: { manager.handleRelease() })
        tap.confirmedPressHandler = { manager.handlePress(downTime: $0) }
        tap.interruptionHandler = { manager.handleInterruption() }
        manager.permissionCheck = { true }
        return (manager, tap)
    }
    func testRepeatedModifierTogglesFullRoute() {
        let time = TimeBox(now: 0)
        let state = RecordingState(recording: false, busy: false)
        let (_, tap) = fullRouteTap(behavior: .toggle, time: time, state: state)
        time.now = 0; XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .control, side: .left, time: 0, sole: true)), .pending)
        time.now = 0.1; XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .control, side: .left, time: 0.1)), .tapRelease)
        XCTAssertEqual(state.starts, 1); XCTAssertTrue(state.recording)
        time.now = 1.0; XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .control, side: .left, time: 1.0, sole: true)), .pending)
        time.now = 1.1; XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .control, side: .left, time: 1.1)), .tapRelease)
        XCTAssertEqual(state.finishes, 1); XCTAssertFalse(state.recording)
        time.now = 2.0; XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .control, side: .left, time: 2.0, sole: true)), .pending)
        time.now = 2.1; XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .control, side: .left, time: 2.1)), .tapRelease)
        XCTAssertEqual(state.starts, 2); XCTAssertTrue(state.recording)
    }
    func testHeldModifier350msTapOrHoldFinishesFullRoute() {
        let time = TimeBox(now: 0)
        let state = RecordingState(recording: false, busy: false)
        let (_, tap) = fullRouteTap(behavior: .tapOrHold, time: time, state: state)
        time.now = 0; XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .control, side: .left, time: 0, sole: true)), .pending)
        time.now = 0.3; XCTAssertEqual(tap.simulateSoloEvent(.holdTimeout(time: 0.3)), .press)
        XCTAssertEqual(state.starts, 1)
        time.now = 0.35; XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .control, side: .left, time: 0.35)), .holdRelease)
        XCTAssertEqual(state.finishes, 1, "Physical 350ms hold must finish, not keep as a tap")
        XCTAssertFalse(state.recording)
    }
    func testCmdCFullRouteNeverActivates() {
        let time = TimeBox(now: 0)
        let state = RecordingState(recording: false, busy: false)
        let (_, tap) = fullRouteTap(behavior: .toggle, key: .command, side: .left, time: time, state: state)
        time.now = 0; XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .command, side: .left, time: 0, sole: true)), .pending)
        time.now = 0.05; XCTAssertEqual(tap.simulateSoloEvent(.otherKeyDown(time: 0.05)), .cancelled)
        time.now = 0.1; XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .command, side: .left, time: 0.1)), .none)
        XCTAssertEqual(state.starts, 0)
        XCTAssertEqual(state.finishes, 0)
    }
    func testDeniedPermissionBlocksStartButNotStop() {
        // Start path is permission-gated.
        let (manager, _, state) = managerWithEngine(behavior: .toggle)
        manager.permissionCheck = { false }
        manager.handlePress()
        XCTAssertEqual(state.starts, 0)
        // Losing permission must not disable the stop shortcut (clipboard fallback).
        state.recording = true
        manager.handlePress()
        XCTAssertEqual(state.finishes, 1)
    }
    func testTrackedModifierMouseResetPreserveIdentity() throws {
        // All Shortcuts edit families update in place during native tracking
        // (Mode/Microphone pattern); tracked objects keep identity, no rebuild.
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-shortcut-tracked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let store = ShortcutStore(initial: ShortcutConfiguration.default, fileURL: nil)
        let state = RecordingState(recording: false, busy: false)
        let engine = ShortcutEngine(configuration: ShortcutConfiguration.default, sinks: .init(
            start: {}, finish: {}, cancel: {},
            isRecording: { state.recording }, isBusy: { state.busy }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: SparkMockShortcutRegistrar())
        let delegate = AppDelegate(model: model, shortcutManager: manager)
        delegate.rebuildMenu()
        let original = delegate.menu.items
        let submenu = try XCTUnwrap(delegate.menu.item(withTitle: "Shortcuts")?.submenu)
        delegate.menuWillOpen(delegate.menu)
        defer { delegate.menuDidClose(delegate.menu) }
        // Modifier via embedded keep-open control.
        let modifierMenu = try XCTUnwrap(submenu.item(withTitle: "Modifier-Only")?.submenu)
        let leftOption = try XCTUnwrap(modifierMenu.item(withTitle: "Left ⌥") as? SettingsMenuItem)
        leftOption.control.performClick(nil)
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.modifierOnly(key: .option, side: .left))
        XCTAssertEqual(leftOption.control.state, .on)
        // Mouse via embedded keep-open control.
        let mouseMenu = try XCTUnwrap(submenu.item(withTitle: "Mouse Button")?.submenu)
        let side4 = try XCTUnwrap(mouseMenu.item(withTitle: "Side Button 4") as? SettingsMenuItem)
        let confirmation = MouseConfirmationTests.MouseConfirmMonitor()
        manager.confirmationAccessCheck = { true }
        manager.makeConfirmationMonitor = { confirmation }
        manager.makeConfirmationTimer = { MouseConfirmationTests.MouseConfirmTimer() }
        side4.control.performClick(nil)
        XCTAssertEqual(manager.pendingMouseButton, .button3)
        XCTAssertEqual(manager.configuration.trigger, .modifierOnly(key: .option, side: .left))
        XCTAssertEqual(side4.control.title, "Press side button 4 to confirm…")
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = try XCTUnwrap(CGEvent(source: nil))
            event.type = type
            event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            XCTAssertEqual(confirmation.handler?(type, event), true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.mouseButton(button: .button3))
        XCTAssertEqual(side4.control.state, .on)
        XCTAssertEqual(leftOption.control.state, .off)
        // Reset via menu action dispatch (plain item).
        let reset = try XCTUnwrap(submenu.item(withTitle: "Reset to Default"))
        NSApplication.shared.sendAction(reset.action!, to: reset.target, from: reset)
        XCTAssertEqual(manager.configuration, ShortcutConfiguration.default)
        // Tracked identity preserved throughout: same root items, same submenu.
        XCTAssertTrue(delegate.menu.item(withTitle: "Shortcuts")?.submenu === submenu)
        XCTAssertEqual(original.count, delegate.menu.items.count)
        for (before, after) in zip(original, delegate.menu.items) { XCTAssertTrue(before === after) }
        XCTAssertTrue(submenu.items.first?.title.hasPrefix("Current:") == true)
    }
    func testFailedApplyKeepsRecorderOpenForRetry() {
        let (manager, _, _) = managerWithEngine()
        manager.beginKeyCapture()
        XCTAssertTrue(manager.isCapturingKeys)
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertTrue(manager.isCapturingKeys, "Panel stays open on invalid chord for retry")
        XCTAssertNotNil(manager.lastError)
        manager.cancelKeyCapture()
        XCTAssertFalse(manager.isCapturingKeys)
    }
    func testNativeDeliveryFiltering() throws {
        // Same production entry, synthetic events only: no posting, no TCC.
        let tap = EventTapShortcutRegistrar()
        // Modifier Toggle: solo pending, then delivery decisions.
        tap.primeForTesting(.init(trigger: .modifierOnly(key: .command, side: .left), behavior: .toggle), onPress: {}, onRelease: {})
        XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .command, side: .left, time: 0, sole: true)), .pending)
        // Own streaming keystrokes are ignored and preserve the pending stop gesture.
        let own = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        own.setIntegerValueField(.eventSourceUserData, value: LiveInsertion.eventMarker)
        XCTAssertFalse(tap.processTapEvent(type: .keyDown, event: own))
        XCTAssertFalse(tap.arbitrateKeyDown(userData: LiveInsertion.eventMarker))
        XCTAssertNotNil(tap.soloState.pendingSince)
        // Real user typing counts (and cancels the pending solo) but still passes through.
        XCTAssertTrue(tap.arbitrateKeyDown(userData: 0))
        XCTAssertNil(tap.soloState.pendingSince)
        let typed = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        XCTAssertFalse(tap.processTapEvent(type: .keyDown, event: typed))
        // Key chords never consume keyDown.
        tap.primeForTesting(.init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle), onPress: {}, onRelease: {})
        XCTAssertFalse(tap.arbitrateKeyDown(userData: 0))
        // Mouse: only the configured middle/side down/up is consumed.
        tap.primeForTesting(.init(trigger: .mouseButton(button: .middle), behavior: .holdToTalk), onPress: {}, onRelease: {})
        let middleDown = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        middleDown.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: middleDown))
        let middleUp = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
        middleUp.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseUp, event: middleUp))
        let left = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertFalse(tap.processTapEvent(type: .leftMouseDown, event: left))
        let right = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right))
        XCTAssertFalse(tap.processTapEvent(type: .rightMouseDown, event: right))
        let otherSide = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        otherSide.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        XCTAssertFalse(tap.processTapEvent(type: .otherMouseDown, event: otherSide))
        tap.unregister()
    }
    func testInterruptionDoesNotFinish() {
        let (manager, registrar, state) = managerWithEngine(behavior: .holdToTalk)
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk)))
        registrar.firePress()
        XCTAssertEqual(state.starts, 1)
        manager.handleInterruption()
        XCTAssertEqual(state.cancels, 1)
        XCTAssertEqual(state.finishes, 0)
    }
    func testMenuKeyEquivalentReflectsWorkingBinding() {
        XCTAssertEqual(ShortcutManager.menuKeyEquivalent(for: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle)).key, "n")
        let custom = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .toggle))
        XCTAssertEqual(custom.key, "c")
        XCTAssertTrue(custom.modifiers.contains(.control))
        let modifier = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .modifierOnly(key: .control, side: .left), behavior: .toggle))
        XCTAssertEqual(modifier.key, "")
        let mouse = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .mouseButton(button: .middle), behavior: .toggle))
        XCTAssertEqual(mouse.key, "")
    }
    func testKeyRecorderSuspendsActivation() {
        let (manager, registrar, state) = managerWithEngine(behavior: .toggle)
        manager.beginKeyCapture()
        XCTAssertTrue(manager.isCapturingKeys)
        registrar.firePress()
        XCTAssertEqual(state.starts, 0) // suspended while recording keys
        registrar.fireRelease()
        XCTAssertEqual(state.finishes, 0)
        manager.cancelKeyCapture()
        XCTAssertFalse(manager.isCapturingKeys)
    }
    func testCapsLockIsNotFn() {
        XCTAssertFalse(EventTapShortcutRegistrar.flagsContain(.maskAlphaShift, key: .function))
        XCTAssertFalse(EventTapShortcutRegistrar.flagsContain(.init(rawValue: 0), key: .function))
        // CapsLock held alongside the target must not block solo.
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContainOnly([.maskControl, .maskAlphaShift], key: .control))
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContain([.maskControl], key: .control))
    }
    func testSoloCmdCSequenceNeverPresses() {
        // Reducer-level: ordinary Cmd+C never yields a solo press (no host input).
        var state = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .toggle), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .otherKeyDown(time: 0.05), targetKey: .command, targetSide: .left, behavior: .toggle), .cancelled)
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .targetUp(key: .command, side: .left, time: 0.1), targetKey: .command, targetSide: .left, behavior: .toggle), .none)
        // Registrar helper stays crash-free without Accessibility (no press claimed).
        let tap = EventTapShortcutRegistrar()
        XCTAssertNil(tap.registered)
    }
}
