import XCTest
import AppKit
@testable import Vella
@testable import VellaCore

/// Bounded mouse-button confirmation (spark).
/// Public source + synthetic fixtures only. No global event posting (no CGEventPost),
/// no live store (memory-only ShortcutStore), no full-app launch, no TCC prompts.
final class MouseConfirmationTests: XCTestCase {

    // MARK: - Fakes (injectable seams, no host input)

    final class MouseConfirmRegistrar: ShortcutRegistrar {
        var registered: ShortcutConfiguration?
        var registerCalls = 0
        var unregisterCalls = 0
        var shouldFail = false
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        var pressFires = 0
        func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
            registerCalls += 1
            if shouldFail { throw VellaError.message("Already reserved.") }
            registered = config
            self.onPress = { [weak self] in self?.pressFires += 1; onPress() }
            self.onRelease = onRelease
        }
        func unregister() { unregisterCalls += 1; registered = nil }
    }

    final class MouseConfirmMonitor: MouseConfirmationMonitor {
        var startCalls = 0
        var stopCalls = 0
        var startedButton: MouseButton?
        var handler: ((CGEventType, CGEvent) -> Bool)?
        var failure: (() -> Void)?
        var shouldThrow: Error?
        func start(button: MouseButton, handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) throws {
            startCalls += 1
            if let err = shouldThrow { throw err }
            startedButton = button
            self.handler = handler
            self.failure = onFailure
        }
        func stop() { stopCalls += 1; startedButton = nil }
    }

    final class MouseConfirmTimer: MouseConfirmationTimer {
        var scheduleCalls = 0
        var invalidateCalls = 0
        var delay: TimeInterval?
        var handler: (() -> Void)?
        func schedule(delay: TimeInterval, handler: @escaping () -> Void) {
            scheduleCalls += 1
            self.delay = delay
            self.handler = handler
        }
        func invalidate() { invalidateCalls += 1; handler = nil }
        func fire() { handler?() }
    }

    final class MouseConfirmState {
        var recording = false
        var busy = false
        var starts = 0
        var finishes = 0
        var cancels = 0
        init(recording: Bool = false, busy: Bool = false) {
            self.recording = recording; self.busy = busy
        }
    }

    @MainActor private func makeManager(
        behavior: ShortcutBehavior = .toggle,
        recording: Bool = false,
        busy: Bool = false
    ) -> (ShortcutManager, MouseConfirmRegistrar, MouseConfirmMonitor, MouseConfirmTimer, MouseConfirmState) {
        let state = MouseConfirmState(recording: recording, busy: busy)
        let store = ShortcutStore(initial: .default, fileURL: nil)
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { state.starts += 1; state.recording = true },
            finish: { state.finishes += 1; state.recording = false; state.busy = false },
            cancel: { state.cancels += 1; state.recording = false; state.busy = false },
            isRecording: { state.recording }, isBusy: { state.busy }))
        let registrar = MouseConfirmRegistrar()
        let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
        let monitor = MouseConfirmMonitor()
        let timer = MouseConfirmTimer()
        manager.makeConfirmationMonitor = { monitor }
        manager.makeConfirmationTimer = { timer }
        manager.confirmationAccessCheck = { true }
        manager.confirmationTimeoutInterval = 10
        return (manager, registrar, monitor, timer, state)
    }

    @MainActor private func mouseEvent(type: CGEventType, button: MouseButton) throws -> CGEvent {
        let cgType: CGEventType = type
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: cgType == .otherMouseDown ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        return event
    }

    // MARK: - Prompts

    func testPromptsExact() {
        XCTAssertEqual(ShortcutManager.mouseConfirmationPrompt(for: .button3), "Press side button 4 to confirm…")
        XCTAssertEqual(ShortcutManager.mouseConfirmationPrompt(for: .middle), "Press middle button to confirm…")
        XCTAssertEqual(ShortcutManager.mouseConfirmationPrompt(for: .button4), "Press side button 5 to confirm…")
        XCTAssertEqual(ShortcutManager.mouseConfirmationTimeoutMessage, "Button not detected")
        // Distinct failures: AX-denied claims access; generic never claims AX denial.
        XCTAssertEqual(ShortcutManager.mouseConfirmationAccessDeniedMessage, "Need Accessibility access")
        XCTAssertEqual(ShortcutManager.mouseConfirmationUnavailableMessage, "Could not observe input")
        XCTAssertTrue(ShortcutManager.mouseConfirmationAccessDeniedMessage.contains("Accessibility"))
        XCTAssertFalse(ShortcutManager.mouseConfirmationUnavailableMessage.contains("Accessibility"))
        XCTAssertFalse(ShortcutManager.mouseConfirmationUnavailableMessage.lowercased().contains("remap"))
    }

    // MARK: - Selecting never applies immediately

    @MainActor func testSelectingAnyMouseRowDoesNotApply() {
        for button in [MouseButton.middle, .button3, .button4] {
            let (manager, registrar, monitor, timer, state) = makeManager()
            let before = manager.configuration
            XCTAssertTrue(manager.beginMouseButtonConfirmation(button))
            XCTAssertEqual(manager.pendingMouseButton, button, "pending \(button)")
            XCTAssertEqual(manager.configuration, before, "prior persists")
            XCTAssertEqual(registrar.registerCalls, 0, "no re-registration until up")
            XCTAssertEqual(state.starts, 0)
            XCTAssertEqual(monitor.startedButton, button)
            XCTAssertEqual(timer.delay, 10)
            XCTAssertTrue(manager.isConfirmingMouseButton)
            // Activation suspended during confirmation.
            manager.handlePress()
            manager.handleRelease()
            XCTAssertEqual(state.starts, 0)
            XCTAssertEqual(registrar.pressFires, 0)
        }
    }

    // MARK: - Real handler: down consumed, unmatched up passes, up commits

    @MainActor func testDownConsumedUnmatchedUpPassesMatchingUpCommits() throws {
        let (manager, registrar, _, _, state) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        // Matching down consumed, no commit.
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .middle)))
        XCTAssertEqual(manager.configuration, .default)
        XCTAssertEqual(registrar.registerCalls, 0)
        // Autorepeat down consumed, still no commit.
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .middle)))
        XCTAssertEqual(registrar.registerCalls, 0)
        // Wrong button passes through, no commit.
        let other = try mouseEvent(type: .otherMouseDown, button: .button3)
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: other))
        // Unmatched-button up passes through.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .button3)))
        XCTAssertEqual(registrar.registerCalls, 0)
        // Matching up consumed + commits async (release cannot hit new Hold).
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .middle)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.mouseButton(button: .middle))
        XCTAssertEqual(registrar.registerCalls, 1)
        XCTAssertFalse(manager.isConfirmingMouseButton)
        XCTAssertEqual(state.starts, 0, "confirmation never activated")
    }

    @MainActor func testUnmatchedUpWithoutDownPassesThrough() throws {
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .button3)))
        XCTAssertEqual(manager.configuration, .default)
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertTrue(manager.isConfirmingMouseButton)
    }

    @MainActor func testNativeDownUpCommitsWithoutDirectSeams() throws {
        // Native handler only (no direct down/up seams): down then up commits.
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button4))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button4)))
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .button4)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.mouseButton(button: .button4))
        XCTAssertEqual(registrar.registerCalls, 1)
        XCTAssertFalse(manager.isConfirmingMouseButton)
    }

    // MARK: - Timeout + monitor/permission failures explicit in same row

    @MainActor func testTimeoutReportsButtonNotDetected() {
        let (manager, registrar, _, timer, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        timer.fire()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(manager.pendingMouseButton)
        XCTAssertEqual(manager.mouseConfirmationError, "Button not detected")
        XCTAssertEqual(manager.mouseConfirmationErrorButton, .button3)
        XCTAssertEqual(manager.configuration, .default, "no apply on timeout")
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    @MainActor func testMonitorCreationFailureExplicit() {
        let (manager, registrar, monitor, _, _) = makeManager()
        monitor.shouldThrow = VellaError.message(ShortcutManager.mouseConfirmationUnavailableMessage)
        XCTAssertFalse(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertNil(manager.pendingMouseButton)
        XCTAssertEqual(manager.mouseConfirmationErrorButton, .middle)
        XCTAssertEqual(manager.mouseConfirmationError, ShortcutManager.mouseConfirmationUnavailableMessage)
        XCTAssertFalse(manager.mouseConfirmationError?.contains("Accessibility") == true, "generic failure must not claim AX denial")
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    @MainActor func testSilentAccessDeniedExplicit() {
        let (manager, registrar, _, _, _) = makeManager()
        manager.confirmationAccessCheck = { false }
        XCTAssertFalse(manager.beginMouseButtonConfirmation(.button4))
        XCTAssertEqual(manager.mouseConfirmationError, ShortcutManager.mouseConfirmationAccessDeniedMessage)
        XCTAssertEqual(manager.mouseConfirmationErrorButton, .button4)
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    // MARK: - Cancel paths, late callbacks, same-button, no leak

    @MainActor func testCancelOnMenuCloseAndChangingSelection() {
        let (manager, _, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        manager.cancelMouseButtonConfirmation()
        XCTAssertFalse(manager.isConfirmingMouseButton)
        XCTAssertNil(manager.mouseConfirmationError)
        // Changing setting cancels previous and starts new.
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertEqual(manager.pendingMouseButton, .button3)
        // Behavior change via apply cancels.
        XCTAssertTrue(manager.applyBehavior(.holdToTalk))
        XCTAssertFalse(manager.isConfirmingMouseButton)
    }

    @MainActor func testInterruptionAndBusyCancel() {
        let (manager, _, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        manager.handleInterruption()
        XCTAssertFalse(manager.isConfirmingMouseButton)
        // Busy at begin refuses to start.
        let (busyManager, _, _, _, _) = makeManager(busy: true)
        XCTAssertFalse(busyManager.beginMouseButtonConfirmation(.middle))
        XCTAssertFalse(busyManager.isConfirmingMouseButton)
    }

    @MainActor func testLateCallbacksIgnoredAfterCancel() throws {
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .middle)))
        manager.cancelMouseButtonConfirmation()
        // Late up after cancel must not commit.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .middle)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(manager.configuration, .default)
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    @MainActor func testSameCurrentMouseButtonAlsoConfirms() throws {
        let (manager, registrar, _, _, _) = makeManager()
        XCTAssertTrue(manager.apply(ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .toggle)))
        XCTAssertEqual(registrar.registerCalls, 1)
        // Re-selecting the same current button still requires confirmation (native only).
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.middle))
        XCTAssertTrue(manager.isConfirmingMouseButton)
        XCTAssertEqual(registrar.registerCalls, 1, "no apply until press")
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .middle)))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .middle)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(registrar.registerCalls, 2)
    }

    @MainActor func testConfirmationNeverLeaksIntoActivation() throws {
        let (manager, registrar, monitor, _, state) = makeManager(behavior: .holdToTalk)
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        // Drive via stored fake-monitor handler (real manager reducer, no posting).
        guard let handler = monitor.handler else { return XCTFail("no handler") }
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        down.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertTrue(handler(.otherMouseDown, down))
        XCTAssertEqual(state.starts, 0)
        XCTAssertEqual(registrar.pressFires, 0)
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
        up.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertTrue(handler(.otherMouseUp, up))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.mouseButton(button: .button3))
        // Confirming gesture never started recording; new Hold has no dangling press.
        XCTAssertEqual(state.starts, 0)
        XCTAssertNil(manager.engine.activePressID)
    }

    // MARK: - Wrong-button feedback keeps waiting in SAME row

    @MainActor func testWrongSideAndMiddleFeedbackThenCorrectSucceeds() throws {
        let (manager, registrar, _, _, state) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm…")
        // Wrong side Button 5 down: SAME-row feedback, never consumed, still pending.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button4)))
        XCTAssertTrue(manager.isConfirmingMouseButton)
        XCTAssertEqual(manager.configuration, .default, "old config persists")
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm… (Button 5 detected)")
        // Wrong middle down updates feedback, still pending, still no apply.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .middle)))
        XCTAssertTrue(manager.isConfirmingMouseButton)
        XCTAssertEqual(manager.configuration, .default)
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm… (Middle button detected)")
        // Ordinary left/right downs also inform but are never consumed.
        let left = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .leftMouseDown, event: left))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm… (Left click detected)")
        let right = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .rightMouseDown, event: right))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm… (Right click detected)")
        // Unknown huge button number: bounded generic, no overflow, no consume.
        let huge = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        huge.setIntegerValueField(.mouseEventButtonNumber, value: Int64.max)
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: huge))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm… (Other button detected)")
        XCTAssertTrue(manager.isConfirmingMouseButton)
        // Correct down clears feedback; correct up commits with zero activation.
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button3)))
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button3), "Press side button 4 to confirm…")
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .button3)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(manager.configuration.trigger == ShortcutTrigger.mouseButton(button: .button3))
        XCTAssertEqual(registrar.registerCalls, 1)
        XCTAssertFalse(manager.isConfirmingMouseButton)
        XCTAssertEqual(state.starts, 0)
        XCTAssertEqual(state.finishes, 0)
    }

    @MainActor func testFeedbackResetsOnNewSelectionCancelAndSuccess() throws {
        let (manager, _, _, _, _) = makeManager()
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button4)))
        XCTAssertNotNil(manager.mouseConfirmationDetectedLabel)
        // New selection resets feedback to base prompt.
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button4))
        XCTAssertNil(manager.mouseConfirmationDetectedLabel)
        XCTAssertEqual(manager.mouseConfirmationRowText(for: .button4), "Press side button 5 to confirm…")
        // Wrong press then cancel resets.
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button3)))
        XCTAssertNotNil(manager.mouseConfirmationDetectedLabel)
        manager.cancelMouseButtonConfirmation()
        XCTAssertNil(manager.mouseConfirmationDetectedLabel)
        // Wrong press then success resets.
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertFalse(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button4)))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button3)))
        XCTAssertNil(manager.mouseConfirmationDetectedLabel, "correct down clears feedback")
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .button3)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(manager.mouseConfirmationDetectedLabel)
        XCTAssertFalse(manager.isConfirmingMouseButton)
    }

    @MainActor func testCommitFailureCompactRowWithFullTooltip() throws {
        let (manager, registrar, _, _, _) = makeManager()
        registrar.shouldFail = true
        XCTAssertTrue(manager.beginMouseButtonConfirmation(.button3))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseDown, event: try mouseEvent(type: .otherMouseDown, button: .button3)))
        XCTAssertTrue(manager.processConfirmationTapEvent(type: .otherMouseUp, event: try mouseEvent(type: .otherMouseUp, button: .button3)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(manager.configuration, .default, "prior persists on failure")
        XCTAssertEqual(manager.mouseConfirmationError, ShortcutManager.mouseConfirmationUnchangedMessage)
        XCTAssertEqual(manager.mouseConfirmationErrorButton, .button3)
        XCTAssertNotNil(manager.mouseConfirmationRowToolTip(for: .button3), "full diagnostic in tooltip")
        XCTAssertNil(manager.mouseConfirmationRowToolTip(for: .button4))
        // Compact row text fits reserved width (no clipping).
        let reserved = ShortcutManager.mouseConfirmationReservedWidth()
        let font = NSFont.menuFont(ofSize: 0)
        XCTAssertGreaterThanOrEqual(reserved, ((manager.mouseConfirmationError ?? "") as NSString).size(withAttributes: [.font: font]).width + 52)
    }

    // MARK: - Row rendering: pre-reserved width, red survives synchronize, no tracking resize

    @MainActor func testRowRedSurvivesSynchronizeAndWidens() {
        _ = NSApplication.shared
        let probe = NSObject()
        let reserved = ShortcutManager.mouseConfirmationReservedWidth()
        let item = SettingsMenuItem(title: "Side Button 4", target: probe, action: NSSelectorFromString("noop"), reservedWidth: reserved)
        let widthBefore = item.view?.frame.width ?? 0
        XCTAssertGreaterThanOrEqual(widthBefore, reserved)
        XCTAssertGreaterThanOrEqual(widthBefore, 180)
        // Showing prompt/error while tracking must not resize the row.
        let prompt = ShortcutManager.mouseConfirmationPrompt(for: .button3)
        item.showConfirmationPrompt(prompt)
        item.synchronize()
        XCTAssertEqual(item.control.attributedTitle.string, prompt)
        XCTAssertNotNil(item.control.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(item.view?.frame.width ?? -1, widthBefore, "no resize during tracking")
        item.showConfirmationError(ShortcutManager.mouseConfirmationTimeoutMessage)
        item.synchronize()
        XCTAssertEqual(item.control.attributedTitle.string, ShortcutManager.mouseConfirmationTimeoutMessage, "red survives synchronize")
        XCTAssertEqual(item.view?.frame.width ?? -1, widthBefore, "no resize during tracking")
        item.restoreBaseTitle()
        XCTAssertEqual(item.control.title, "Side Button 4")
        XCTAssertEqual(item.view?.frame.width ?? -1, widthBefore, "restore keeps reserved width")
    }

    @MainActor func testFactoryReservesMouseWidth() {
        _ = NSApplication.shared
        let reserved = ShortcutManager.mouseConfirmationReservedWidth()
        let font = NSFont.menuFont(ofSize: 0)
        let strings = [ShortcutManager.mouseConfirmationPrompt(for: .button3), ShortcutManager.mouseConfirmationTimeoutMessage, ShortcutManager.mouseConfirmationAccessDeniedMessage, ShortcutManager.mouseConfirmationUnavailableMessage, ShortcutManager.mouseConfirmationUnchangedMessage]
        for s in strings {
            XCTAssertGreaterThanOrEqual(reserved, (s as NSString).size(withAttributes: [.font: font]).width + 52)
        }
        for button in [MouseButton.middle, .button3, .button4] {
            for fb in ["Middle button detected", "Button 4 detected", "Button 5 detected", "Left click detected", "Right click detected", "Other button detected"] {
                let combo = "\(ShortcutManager.mouseConfirmationPrompt(for: button)) (\(fb))"
                XCTAssertGreaterThanOrEqual(reserved, (combo as NSString).size(withAttributes: [.font: font]).width + 52, "reserved must fit \(combo)")
            }
        }
    }
}
