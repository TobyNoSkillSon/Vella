import XCTest
import AppKit
import IOKit.hidsystem
@testable import Vella
@testable import VellaCore

/// Independent pre-push audit: native event delivery, modifier sides, mouse
/// confirmation, lifecycle/menu UI, callback generations.
///
/// Synthetic fixtures only. No real Carbon registration, no CGEventPost, no live
/// tap, no TCC prompts, no host settings/recordings, no full app launch.
/// Production handlers + fake monitors/timers injected; every config URL
/// synthetic or nil.
final class ShortcutPublicationNativeTests: XCTestCase {

    // MARK: - Fakes (unique names; no host input)

    final class PubNativeRegistrar: ShortcutRegistrar {
        var registered: ShortcutConfiguration?
        var registerCalls = 0
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        var shouldFail = false
        func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
            registerCalls += 1
            if shouldFail { throw VellaError.message("Already reserved.") }
            registered = config
            self.onPress = onPress
            self.onRelease = onRelease
        }
        func unregister() { registered = nil }
    }

    final class PubNativeMonitor: MouseConfirmationMonitor {
        var handler: ((CGEventType, CGEvent) -> Bool)?
        var failure: (() -> Void)?
        var startedButton: MouseButton?
        func start(button: MouseButton, handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) throws {
            startedButton = button
            self.handler = handler
            self.failure = onFailure
        }
        func stop() { startedButton = nil }
    }

    final class PubNativeTimer: MouseConfirmationTimer {
        var handler: (() -> Void)?
        var delay: TimeInterval?
        func schedule(delay: TimeInterval, handler: @escaping () -> Void) {
            self.delay = delay
            self.handler = handler
        }
        func invalidate() { handler = nil }
        func fire() { handler?() }
    }

    final class PubState {
        var recording = false
        var busy = false
        var starts = 0
        var finishes = 0
        var cancels = 0
    }

    @MainActor private func makeManager(
        behavior: ShortcutBehavior = .toggle,
        recording: Bool = false,
        busy: Bool = false
    ) -> (ShortcutManager, PubNativeRegistrar, PubNativeMonitor, PubNativeTimer, PubState) {
        let state = PubState()
        state.recording = recording
        state.busy = busy
        let store = ShortcutStore(initial: .default, fileURL: nil)
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { state.starts += 1; state.recording = true },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }))
        let registrar = PubNativeRegistrar()
        let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
        let monitor = PubNativeMonitor()
        let timer = PubNativeTimer()
        manager.makeConfirmationMonitor = { monitor }
        manager.makeConfirmationTimer = { timer }
        manager.confirmationAccessCheck = { true }
        return (manager, registrar, monitor, timer, state)
    }

    @MainActor private func confirmEvent(type: CGEventType, buttonNumber: Int64) throws -> CGEvent {
        let cgMouse: CGEventType = (type == .otherMouseUp) ? .otherMouseUp : .otherMouseDown
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: cgMouse == .otherMouseDown ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        return event
    }

    // MARK: - Wrong-button diagnostics vs consumption

    @MainActor func testWrongButtonUpLeavesFeedbackAndNeverConsumes() throws {
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        // Wrong side down: SAME-row feedback, never consumed, prior persists.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try confirmEvent(type: .otherMouseDown, buttonNumber: 4)))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .middle), "Press middle button to confirm… (Button 5 detected)")
        XCTAssertEqual(manager.configuration, .default)
        // Wrong up for that same wrong button: passes through silently, feedback kept.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try confirmEvent(type: .otherMouseUp, buttonNumber: 4)))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .middle), "Press middle button to confirm… (Button 5 detected)")
        XCTAssertTrue(manager.isConfirmingMouseButton)
        XCTAssertEqual(registrar.registerCalls, 0)
        // Huge unknown up: still passes through, feedback collapses to bounded Other only via downs.
        let huge = try confirmEvent(type: .otherMouseUp, buttonNumber: Int64.max)
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: huge))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .middle), "Press middle button to confirm… (Button 5 detected)")
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    @MainActor func testNonMouseAndMouseUpTypesNeverConsumeConfirmation() throws {
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        // Ordinary left down informs but never consumes; left up preserves it.
        let leftDown = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .leftMouseDown, event: leftDown))
        XCTAssertEqual(manager.mouseConfirmationDetectedLabel, "Left click detected")
        let leftUp = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .leftMouseUp, event: leftUp))
        XCTAssertEqual(manager.mouseConfirmationDetectedLabel, "Left click detected", "Mouse-up types must not clear SAME-row feedback")
        // Non-mouse event kinds pass through untouched.
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .keyDown, event: key))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .flagsChanged, event: key))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try confirmEvent(type: .otherMouseUp, buttonNumber: 2)), "Unmatched up without down passes through")
        XCTAssertTrue(manager.isConfirmingMouseButton)
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertEqual(manager.configuration, .default)
    }

    // MARK: - Busy during confirmation (old binding / preparation)

    @MainActor func testBusyBetweenDownAndUpCancelsWithoutConsuming() throws {
        let (manager, registrar, _, _, state) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try confirmEvent(type: .otherMouseDown, buttonNumber: 2)))
        XCTAssertEqual(registrar.registerCalls, 0)
        // Capture turns busy before the release (menu Start, preparation).
        state.busy = true
        // Matching up while busy: must NOT consume, must NOT commit.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try confirmEvent(type: .otherMouseUp, buttonNumber: 2)))
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertEqual(manager.configuration, .default)
        // Async busy-cancel settles; prior binding stays working.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(manager.isConfirmingMouseButton)
        XCTAssertNil(manager.pendingMouseButton)
        XCTAssertEqual(manager.configuration, .default)
    }

    @MainActor func testQueuedMouseCommitLosesToSynchronousCancel() throws {
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try confirmEvent(type: .otherMouseDown, buttonNumber: 3)))
        // Matching up queues the async commit (consumed synchronously).
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try confirmEvent(type: .otherMouseUp, buttonNumber: 3)))
        // Synchronous cancel (menu close / reselection) wins the race.
        manager.cancelMouseButtonConfirmation()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(manager.configuration, .default, "Stale queued commit must not apply after cancel")
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertFalse(manager.isConfirmingMouseButton)
    }

    // MARK: - Tap loss + timeout diagnostics

    @MainActor func testMonitorTapLossCancelsSilentlyWithoutApplying() throws {
        let (manager, registrar, monitor, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertTrue(manager.isConfirmingMouseButton)
        // Native tap loss (sleep/lock/timeout-disabled) surfaces via onFailure.
        let failure = try XCTUnwrap(monitor.failure)
        failure()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(manager.isConfirmingMouseButton)
        XCTAssertNil(manager.pendingMouseButton)
        XCTAssertNil(manager.mouseConfirmationError, "Tap loss cancels silently; timeout text is reserved for the 10s bound")
        XCTAssertEqual(manager.configuration, .default, "Prior binding stays working after tap loss")
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    @MainActor func testTimeoutErrorHasNoTooltipAndNewSelectionClearsIt() throws {
        let (manager, registrar, _, timer, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        timer.fire()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(manager.pendingMouseButton)
        XCTAssertEqual(manager.mouseConfirmationError, ShortcutManager.mouseConfirmationTimeoutMessage)
        XCTAssertEqual(manager.mouseConfirmationErrorButton, .middle)
        XCTAssertNil(manager.mouseConfirmationRowToolTip(for: .middle), "Timeout carries no hardware diagnostic")
        // New selection after the timeout clears the old row error.
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertEqual(manager.pendingMouseButton, .button3)
        XCTAssertNil(manager.mouseConfirmationError)
        XCTAssertNil(manager.mouseConfirmationErrorButton)
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm…")
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    // MARK: - Stale queued native callbacks after rebind

    @MainActor func testStaleModifierSoloAsyncLosesToRebind() throws {
        // Production flagsChanged path queues press+release async; rebind wins.
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        var starts = 0
        var finishes = 0
        let toggle = ShortcutConfiguration(trigger: .modifierOnly(key: .command, side: .left), behavior: .toggle)
        tap.now = { 1000 }
        tap.primeForTesting(toggle, onPress: { starts += 1 }, onRelease: { finishes += 1 })
        func flagsEvent(keyCode: UInt32, rawFlags: UInt64) throws -> CGEvent {
            let event = try XCTUnwrap(CGEvent(source: nil))
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            event.flags = CGEventFlags(rawValue: rawFlags)
            return event
        }
        let downCode = EventTapShortcutRegistrar.modifierCode(key: .command, side: .left)
        let downFlags = CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK)
        XCTAssertFalse(tap.processTapEvent(type: .flagsChanged, event: try flagsEvent(keyCode: downCode, rawFlags: downFlags)))
        XCTAssertFalse(tap.processTapEvent(type: .flagsChanged, event: try flagsEvent(keyCode: downCode, rawFlags: 0)))
        // Rebind before the queued async toggle fires.
        tap.primeForTesting(toggle, onPress: { starts += 100 }, onRelease: {})
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(starts, 0, "Stale queued solo press must not fire after rebind")
        XCTAssertEqual(finishes, 0)
    }

    @MainActor func testStaleMouseAsyncLosesToRebind() throws {
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        var presses = 0
        let middle = ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk)
        tap.primeForTesting(middle, onPress: { presses += 1 }, onRelease: {})
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        down.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: down))
        // Rebind to side button before the queued async press fires.
        let side = ShortcutConfiguration(trigger: .mouseButton(button: .button3), behavior: .holdToTalk)
        tap.primeForTesting(side, onPress: { presses += 100 }, onRelease: {})
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(presses, 0, "Stale queued mouse press must not leak into the new binding")
    }

    // MARK: - Lifecycle / menu UI

    @MainActor func testOldPressDuringConfirmationKeepsPendingThenMenuCloseCancels() throws {
        let (manager, _, _, _, state) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        // Old binding press during confirmation: suspended, pending survives.
        manager.handlePress()
        manager.handleRelease()
        XCTAssertEqual(state.starts, 0)
        XCTAssertEqual(manager.pendingMouseButton, .middle, "Old press must not disturb pending confirmation")
        // Root menu close/Escape path cancels; prior binding stays.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let delegate = AppDelegate(model: model, shortcutManager: manager)
        delegate.menuDidClose(delegate.menu)
        XCTAssertFalse(manager.isConfirmingMouseButton)
        XCTAssertNil(manager.mouseConfirmationError)
        XCTAssertEqual(manager.configuration, .default)
    }

    @MainActor func testRefreshCancelsConfirmationWhenCaptureTurnsBusy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let state = PubState()
        let store = ShortcutStore(initial: .default, fileURL: nil)
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { state.starts += 1 }, finish: {}, cancel: {},
            isRecording: { state.recording }, isBusy: { state.busy }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: PubNativeRegistrar())
        manager.makeConfirmationMonitor = { PubNativeMonitor() }
        manager.makeConfirmationTimer = { PubNativeTimer() }
        manager.confirmationAccessCheck = { true }
        let delegate = AppDelegate(model: model, shortcutManager: manager)
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertTrue(manager.isConfirmingMouseButton)
        // Capture turns busy via the menu Start path (no panel/status needed).
        model.update(.preparing, "Synthetic preparing")
        delegate.refresh()
        XCTAssertFalse(manager.isConfirmingMouseButton, "Busy capture must cancel bounded confirmation")
        XCTAssertEqual(manager.configuration, .default)
        model.cancel()
    }

    // MARK: - Modifier sides + row rendering

    func testFnSideIsDownIgnoresCapsLock() {
        XCTAssertTrue(EventTapShortcutRegistrar.sideIsDown(CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK)), key: .control, side: .left))
        XCTAssertFalse(EventTapShortcutRegistrar.sideIsDown(CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK)), key: .control, side: .right))
        XCTAssertTrue(EventTapShortcutRegistrar.sideIsDown(.maskSecondaryFn, key: .function, side: .left))
        XCTAssertFalse(EventTapShortcutRegistrar.sideIsDown(.maskAlphaShift, key: .function, side: .left), "Caps Lock must never satisfy Fn")
        XCTAssertFalse(EventTapShortcutRegistrar.sideIsDown(CGEventFlags(rawValue: 0), key: .function, side: .left))
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContainOnly([.maskSecondaryFn, .maskAlphaShift], key: .function), "Caps Lock alongside Fn must not block solo")
    }

    @MainActor func testRestoreBaseTitleClearsRedPrompt() {
        _ = NSApplication.shared
        let probe = NSObject()
        let item = SettingsMenuItem(title: "Side Button 4", target: probe, action: NSSelectorFromString("noop"), reservedWidth: ShortcutManager.mouseConfirmationReservedWidth())
        let widthBefore = item.view?.frame.width ?? 0
        item.showConfirmationPrompt(ShortcutManager.mouseConfirmationPrompt(for: .button3))
        item.synchronize()
        XCTAssertTrue(item.control.attributedTitle.string.hasPrefix("Press side button 4"))
        item.restoreBaseTitle()
        item.synchronize()
        XCTAssertEqual(item.control.title, "Side Button 4")
        XCTAssertEqual(item.control.attributedTitle.string, "Side Button 4", "Restore must clear the red prompt text, not leave stale attributedTitle")
        XCTAssertNotEqual(item.control.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed, "Restored row must not stay red")
        XCTAssertEqual(item.view?.frame.width ?? -1, widthBefore, "Restore keeps pre-reserved tracking width")
    }

    // MARK: - Coordinator fixes: interruption reset, permission gate, transactional tap

    final class PubTime {
        var now: TimeInterval
        init(_ now: TimeInterval) { self.now = now }
    }

    @MainActor private func flagsChanged(keyCode: UInt32, rawFlags: UInt64) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = CGEventFlags(rawValue: rawFlags)
        return event
    }

    @MainActor private func mouseOther(buttonNumber: Int64, up: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: up ? .otherMouseUp : .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        return event
    }

    @MainActor func testInterruptionResetsMissedUpMouseSoNextDownWorks() throws {
        // Missed UP (sleep) + interruption must clear mouseDown so the next DOWN works.
        let state = PubState()
        let config = ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk)
        let store = ShortcutStore(initial: config, fileURL: nil)
        let engine = ShortcutEngine(configuration: config, sinks: .init(
            start: { state.starts += 1; state.recording = true },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }))
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        let manager = ShortcutManager(engine: engine, store: store, registrar: tap)
        manager.permissionCheck = { true }
        tap.primeForTesting(config, onPress: { manager.handlePress() }, onRelease: { manager.handleRelease() })
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: try mouseOther(buttonNumber: 2, up: false)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(state.starts, 1)
        // UP missed during sleep; interruption cancels owned capture and resets input.
        manager.handleInterruption()
        XCTAssertEqual(state.cancels, 1)
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: try mouseOther(buttonNumber: 2, up: false)), "Next DOWN after missed UP + interruption must work")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(state.starts, 2)
    }

    @MainActor func testQueuedNativeMousePressCannotFireAfterInterruption() throws {
        let config = ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk)
        let store = ShortcutStore(initial: config, fileURL: nil)
        let engine = ShortcutEngine(configuration: config, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        let manager = ShortcutManager(engine: engine, store: store, registrar: tap)
        var presses = 0
        tap.primeForTesting(config, onPress: { presses += 1 }, onRelease: {})
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: try mouseOther(buttonNumber: 2, up: false)))
        manager.handleInterruption()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(presses, 0, "Queued mouse DOWN must not activate after interruption")
    }

    @MainActor func testQueuedModifierSoloPressCannotFireAfterInterruption() throws {
        let config = ShortcutConfiguration(trigger: .modifierOnly(key: .command, side: .left), behavior: .toggle)
        let store = ShortcutStore(initial: config, fileURL: nil)
        let engine = ShortcutEngine(configuration: config, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        let manager = ShortcutManager(engine: engine, store: store, registrar: tap)
        var starts = 0
        var finishes = 0
        tap.primeForTesting(config, onPress: { starts += 1 }, onRelease: { finishes += 1 })
        let code = EventTapShortcutRegistrar.modifierCode(key: .command, side: .left)
        let downFlags = CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK)
        XCTAssertFalse(tap.processTapEvent(type: .flagsChanged, event: try flagsChanged(keyCode: code, rawFlags: downFlags)))
        XCTAssertFalse(tap.processTapEvent(type: .flagsChanged, event: try flagsChanged(keyCode: code, rawFlags: 0)))
        manager.handleInterruption()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(starts, 0, "Queued solo press must not fire after interruption")
        XCTAssertEqual(finishes, 0)
    }

    @MainActor func testTapOrHoldTapOffSurvivesPermissionLossWhileRecording() {
        let time = PubTime(1000)
        let state = PubState()
        let config = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .tapOrHold)
        let store = ShortcutStore(initial: config, fileURL: nil)
        let engine = ShortcutEngine(configuration: config, sinks: .init(
            start: { state.starts += 1; state.recording = true },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }), now: { time.now })
        let manager = ShortcutManager(engine: engine, store: store, registrar: PubNativeRegistrar())
        manager.permissionCheck = { true }
        manager.handlePress()
        XCTAssertEqual(state.starts, 1)
        time.now = 1000.1
        manager.handleRelease()
        XCTAssertEqual(state.finishes, 0, "Short tap keeps recording")
        XCTAssertNotNil(engine.activeCaptureID)
        // Permission lost mid-recording: tap-off arming + finish must still work.
        manager.permissionCheck = { false }
        manager.handlePress()
        XCTAssertNotNil(engine.activePressID, "Tap-off arming must not be permission-gated while recording")
        XCTAssertEqual(state.starts, 1, "Arming must not double-start")
        time.now += 0.05
        manager.handleRelease()
        XCTAssertEqual(state.finishes, 1)
    }

    @MainActor func testTapOrHoldTapOffSurvivesPermissionLossWhilePreparing() {
        let time = PubTime(2000)
        let state = PubState()
        let config = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .tapOrHold)
        let store = ShortcutStore(initial: config, fileURL: nil)
        let engine = ShortcutEngine(configuration: config, sinks: .init(
            start: { state.starts += 1 },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }), now: { time.now })
        let manager = ShortcutManager(engine: engine, store: store, registrar: PubNativeRegistrar())
        manager.permissionCheck = { true }
        manager.handlePress()
        XCTAssertEqual(state.starts, 1)
        state.busy = true // preparing after start
        time.now = 2000.1
        manager.handleRelease()
        XCTAssertEqual(state.cancels, 0, "Tap while preparing retains")
        XCTAssertNotNil(engine.activeCaptureID)
        manager.permissionCheck = { false }
        manager.handlePress()
        XCTAssertNotNil(engine.activePressID, "Tap-off arming must not be permission-gated while busy")
        time.now += 0.35
        manager.handleRelease()
        XCTAssertEqual(state.cancels, 1, "Long release during preparing cancels safely")
        XCTAssertEqual(state.finishes, 0)
    }

    @MainActor func testTapAllocationFailurePreservesPrimedBinding() throws {
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        tap.accessCheck = { true }
        let old = ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk)
        var oldPresses = 0
        var newPresses = 0
        tap.primeForTesting(old, onPress: { oldPresses += 1 }, onRelease: {})
        tap.interruptionHandler = {}
        tap.confirmedPressHandler = { _ in }
        tap.tapCreateOverride = { _ in nil } // allocation fails, no real tap
        let new = ShortcutConfiguration(trigger: .mouseButton(button: .button3), behavior: .holdToTalk)
        do {
            try tap.register(new, onPress: { newPresses += 1 }, onRelease: {})
            XCTFail("Nil tap allocation must throw")
        } catch {}
        XCTAssertEqual(tap.registered, old, "Failed replacement must keep old registration")
        XCTAssertNotNil(tap.interruptionHandler, "Interruption handler retained")
        XCTAssertNotNil(tap.confirmedPressHandler, "Confirmed-press handler retained")
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: try mouseOther(buttonNumber: 2, up: false)), "Old binding still dispatches")
        tap.simulatePress()
        XCTAssertEqual(oldPresses, 1)
        XCTAssertEqual(newPresses, 0)
    }
}
