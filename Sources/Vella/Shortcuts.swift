import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

// MARK: - Registrar abstraction (testable; no host audio/input in tests)

public protocol ShortcutRegistrar: AnyObject {
    var registered: ShortcutConfiguration? { get }
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws
    func unregister()
    /// Clear pending input and invalidate queued native callbacks without
    /// losing registration or notifying. Default no-op for mocks.
    func resetPendingInput()
}

extension ShortcutRegistrar {
    func resetPendingInput() {}
}

/// Carbon press+release for regular key chords. No new permissions.
/// Transactional: the prior hotkey stays registered until the new chord succeeds.
public final class CarbonShortcutRegistrar: ShortcutRegistrar {
    public private(set) var registered: ShortcutConfiguration?
    private var active: GlobalShortcut?
    public init() {}
    public func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        guard case .keyChord(let code, let mods) = config.trigger else {
            throw VellaError.message("That binding needs an event tap, not Carbon.")
        }
        // Behavior-only change on the same chord needs no OS re-registration.
        if let active, registered?.trigger == config.trigger {
            active.updateHandlers(onPress: onPress, onRelease: onRelease)
            registered = config
            return
        }
        let trial = GlobalShortcut()
        do {
            try trial.registerChord(keyCode: code, modifiers: mods, onPress: onPress, onRelease: onRelease)
        } catch let err as VellaError {
            throw err
        } catch {
            throw VellaError.message("That shortcut is already reserved or could not be registered. Choose another chord.")
        }
        active?.unregister()
        active = trial
        registered = config
    }
    public func unregister() {
        active?.unregister()
        active = nil
        registered = nil
    }
    public func resetPendingInput() {
        // Invalidate queued Carbon deliveries without losing registration:
        // bump the callback generation, keep hotkey ID/ref/handlers.
        if let active {
            let press = active.onPress ?? active.action ?? {}
            let release = active.onRelease ?? {}
            active.updateHandlers(onPress: press, onRelease: release)
        }
    }
}

/// Event-tap registrar for explicitly selected modifier-only / mouse bindings.
/// Created only when such a binding is chosen; never at startup for key chords.
/// Modifier-only uses delayed solo arbitration: the tap observes flagsChanged AND
/// nonmodifier keyDown, so ordinary composed chords (e.g. Cmd+C) never fire.
/// Fn never treats Caps Lock as Fn. Existing events are returned unretained.
public final class EventTapShortcutRegistrar: ShortcutRegistrar {
    public private(set) var registered: ShortcutConfiguration?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onInterruption: (() -> Void)?
    private var mouseDown = false
    var soloState = SoloModifierState()
    private var holdTimer: Timer?
    private var holdTimerGeneration: UInt64 = 0
    private var generation: UInt64 = 0
    /// Confirmed solo press carrying the ORIGINAL physical down time, so TapOrHold
    /// classifies the total hold (down@0, guard@0.3, up@0.35 => HOLD finishes).
    /// Wired by ShortcutManager to engine.press(downTime:); falls back to onPress.
    var confirmedPressHandler: ((TimeInterval) -> Void)?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Silent access seam (production AXIsProcessTrusted, no prompt).
    var accessCheck: () -> Bool = { AXIsProcessTrusted() }
    /// Tap-allocation seam (nil = production CGEvent.tapCreate, no real tap in tests).
    var tapCreateOverride: ((CGEventMask) -> CFMachPort?)?
    public init() {}
    public var interruptionHandler: (() -> Void)? {
        get { onInterruption }
        set { onInterruption = newValue }
    }
    public func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        guard config.trigger.requiresEventTap else {
            throw VellaError.message("Key chords use Carbon without an event tap.")
        }
        // Silent check only; never prompts here. Failures surface as menu errors.
        guard accessCheck() else {
            throw VellaError.message("Modifier and mouse shortcuts need Accessibility access. Enable Vella under Accessibility, then try again. Key chords need no access.")
        }
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        // Transactional allocation: build the replacement BEFORE touching live
        // state, so failure keeps the old registration/handlers.
        let newTap: CFMachPort?
        if let override = tapCreateOverride {
            newTap = override(mask)
        } else {
            let context = Unmanaged.passUnretained(self).toOpaque()
            newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, data in
                guard let data else { return Unmanaged.passUnretained(event) }
                let registrar = Unmanaged<EventTapShortcutRegistrar>.fromOpaque(data).takeUnretainedValue()
                // Consume ONLY the configured middle/side click (nil) so it never also
                // navigates; every other event passes through untouched.
                if registrar.processTapEvent(type: type, event: event) { return nil }
                return Unmanaged.passUnretained(event)
            }, userInfo: context)
        }
        guard let newTap else {
            throw VellaError.message("Could not observe input. If macOS asks for Input Monitoring, approve Vella there; otherwise enable Accessibility. Key chords work without this.")
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            throw VellaError.message("Could not observe input. If macOS asks for Input Monitoring, approve Vella there; otherwise enable Accessibility. Key chords work without this.")
        }
        // Only now replace live state; invalidates queued callbacks.
        // unregisterTapOnly preserves interruption/confirmedPress handlers.
        generation &+= 1
        unregisterTapOnly()
        self.onPress = onPress
        self.onRelease = onRelease
        self.tap = newTap
        self.source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        registered = config
    }
    public func unregister() {
        generation &+= 1
        cancelHoldTimer()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil; self.tap = nil
        onPress = nil; onRelease = nil
        registered = nil; mouseDown = false
        soloState = SoloModifierState()
    }
    public func resetPendingInput() {
        // Invalidate queued async deliveries and clear pending input without
        // losing registration/handlers and without notifying (no recursion).
        generation &+= 1
        cancelHoldTimer()
        mouseDown = false
        soloState = SoloModifierState()
    }
    /// Release the tap without invalidating queued-callback generations (internal).
    private func unregisterTapOnly() {
        cancelHoldTimer()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil; self.tap = nil
        onPress = nil; onRelease = nil
        registered = nil; mouseDown = false
        soloState = SoloModifierState()
    }
    /// Synthetic seam for tests: configure dispatch without TCC or a real tap.
    /// Exercises the actual native-event reducer/dispatch (no global input).
    public func primeForTesting(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        generation &+= 1
        cancelHoldTimer()
        self.onPress = onPress
        self.onRelease = onRelease
        soloState = SoloModifierState()
        mouseDown = false
        registered = config
    }
    deinit { unregister() }
    // Test seams: drive without host input.
    public func simulatePress() { onPress?() }
    public func simulateRelease() { onRelease?() }
    public func simulateTapDisabled() {
        resetPendingInput()
        onInterruption?()
    }
    /// Deterministic reducer entry for realistic sequences (no host input).
    /// Returns the reducer output; fires onPress/onRelease to mirror production.
    @discardableResult
    public func simulateSoloEvent(_ event: SoloInputEvent) -> SoloOutput {
        guard case .modifierOnly(let key, let side) = registered?.trigger else { return .none }
        let behavior = registered?.behavior ?? .toggle
        let down = soloState.pendingSince
        let gen = generation
        let confirmed = confirmedPressHandler
        let press = onPress
        let release = onRelease
        let out = ModifierSoloReducer.step(state: &soloState, event: event, targetKey: key, targetSide: side, behavior: behavior)
        // Stale sequences after rebind/unregister never fire.
        guard gen == generation else { return .none }
        switch out {
        case .press:
            if let confirmed, let down { confirmed(down) } else { press?() }
        case .tapRelease:
            if behavior == .toggle {
                if let confirmed, let down { confirmed(down) } else { press?() }
                release?()
            } else if behavior == .tapOrHold {
                // Tap start carries the physical down time; the immediate release
                // lets the engine apply the <0.3s tap-keep rule on true duration.
                if let confirmed, let down { confirmed(down) } else { press?() }
                release?()
            }
            // Hold short tap: ignore (too short to be a hold).
        case .holdRelease:
            release?()
        case .pending:
            if behavior != .toggle { scheduleHoldTimer() }
        case .cancelled:
            cancelHoldTimer()
        case .none:
            break
        }
        return out
    }
    private func scheduleHoldTimer() {
        cancelHoldTimer()
        holdTimerGeneration = generation
        let gen = generation
        let timer = Timer(timeInterval: ModifierSoloReducer.holdDelay, repeats: false) { [weak self] _ in
            guard let self, gen == self.generation, gen == self.holdTimerGeneration,
                  case .modifierOnly(let key, let side) = self.registered?.trigger else { return }
            let behavior = self.registered?.behavior ?? .toggle
            let down = self.soloState.pendingSince
            let out = ModifierSoloReducer.step(state: &self.soloState, event: .holdTimeout(time: self.now()), targetKey: key, targetSide: side, behavior: behavior)
            guard gen == self.generation else { return } // rebind/unregister wins
            if out == .press {
                if let confirmed = self.confirmedPressHandler, let down { confirmed(down) }
                else { self.onPress?() }
            }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
    /// Production tap entry, callable with synthetic events in tests (no posting/TCC).
    /// Returns true only for the configured middle/side mouse down/up, which the
    /// caller consumes (returns nil) so the click never also navigates/opens links.
    /// Everything else (typing, modifiers, primary/secondary, unmatched) passes through.
    @discardableResult
    func processTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Capture identity synchronously: queued async delivery must ignore stale
        // events after rebind/unregister.
        let gen = generation
        guard let config = registered else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Invalidate earlier queued presses immediately, before dispatching
            // the interruption itself. Otherwise a queued press can run first.
            resetPendingInput()
            let interruptionGeneration = generation
            let interruption = onInterruption
            DispatchQueue.main.async { [weak self] in
                guard let self, interruptionGeneration == self.generation else { return }
                interruption?()
            }
            return false
        }
        switch config.trigger {
        case .keyChord:
            break
        case .modifierOnly(let key, let side):
            if type == .keyDown {
                // Vella's own streaming keystrokes carry the insertion marker: they are
                // not user typing and must never cancel a pending stop gesture.
                _ = arbitrateKeyDown(userData: event.getIntegerValueField(.eventSourceUserData))
                return false
            }
            guard type == .flagsChanged else { return false }
            let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            if code == Self.modifierCode(key: key, side: side) {
                let contains = Self.sideIsDown(event.flags, key: key, side: side)
                let otherSide: ModifierSide = side == .left ? .right : .left
                let oppositeIsDown = key != .function && Self.sideIsDown(event.flags, key: key, side: otherSide)
                let sole = Self.flagsContainOnly(event.flags, key: key) && !oppositeIsDown
                let t = now()
                if contains {
                    var s = soloState
                    let out = ModifierSoloReducer.step(state: &s, event: .targetDown(key: key, side: side, time: t, sole: sole), targetKey: key, targetSide: side, behavior: config.behavior)
                    soloState = s
                    if out == .pending, config.behavior != .toggle { scheduleHoldTimer() }
                } else {
                    let down = soloState.pendingSince
                    var s = soloState
                    let out = ModifierSoloReducer.step(state: &s, event: .targetUp(key: key, side: side, time: t), targetKey: key, targetSide: side, behavior: config.behavior)
                    soloState = s
                    let confirmed = confirmedPressHandler
                    let press = onPress
                    let release = onRelease
                    switch out {
                    case .tapRelease:
                        cancelHoldTimer()
                        if config.behavior == .toggle {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, gen == self.generation else { return }
                                if let confirmed, let down { confirmed(down) } else { press?() }
                                release?()
                            }
                        } else if config.behavior == .tapOrHold {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, gen == self.generation else { return }
                                if let confirmed, let down { confirmed(down) } else { press?() }
                                release?()
                            }
                        }
                    case .holdRelease:
                        cancelHoldTimer()
                        DispatchQueue.main.async { [weak self] in
                            guard let self, gen == self.generation else { return }
                            release?()
                        }
                    default:
                        break
                    }
                }
            } else if Self.modifierKeySide(forKeyCode: code) != nil {
                // A different modifier side/key changed (e.g. Right while target Left).
                var s = soloState
                let out = ModifierSoloReducer.step(state: &s, event: .otherModifierDown(time: now()), targetKey: key, targetSide: side, behavior: config.behavior)
                soloState = s
                if out == .cancelled { cancelHoldTimer() }
            } else {
                // Nonmodifier flagsChanged noise: ignore.
                return false
            }
        case .mouseButton(let button):
            if type == .keyDown {
                // Typing does not cancel an owned mouse hold; ignore.
                return false
            }
            guard type == .otherMouseDown || type == .otherMouseUp else { return false }
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            guard number == Int64(button.rawValue) else { return false }
            if type == .otherMouseDown, !mouseDown {
                mouseDown = true
                let press = onPress
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.generation else { return }
                    press?()
                }
                return true // consumed: clicking to dictate must not also navigate
            } else if type == .otherMouseUp, mouseDown {
                mouseDown = false
                let release = onRelease
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.generation else { return }
                    release?()
                }
                return true
            }
            return false
        }
        return false
    }
    /// KeyDown arbitration seam (same production path as the tap callback).
    /// Returns true when counted as user typing (cancels a pending solo chord),
    /// false when ignored: Vella's own marker keystrokes, non-modifier triggers,
    /// or no pending solo. Never consumes the event; typing always passes through.
    @discardableResult
    func arbitrateKeyDown(userData: Int64) -> Bool {
        guard case .modifierOnly(let key, let side) = registered?.trigger else { return false }
        if userData == LiveInsertion.eventMarker { return false }
        var s = soloState
        let out = ModifierSoloReducer.step(state: &s, event: .otherKeyDown(time: now()), targetKey: key, targetSide: side, behavior: registered?.behavior ?? .toggle)
        soloState = s
        if out == .cancelled { cancelHoldTimer() }
        return true
    }
    /// Aggregate flags remain set when the opposite key is held. Device flags
    /// distinguish, for example, Left Command up from Right Command still down.
    static func sideIsDown(_ flags: CGEventFlags, key: ModifierKey, side: ModifierSide) -> Bool {
        let mask: Int32
        switch (key, side) {
        case (.control, .left): mask = NX_DEVICELCTLKEYMASK
        case (.control, .right): mask = NX_DEVICERCTLKEYMASK
        case (.option, .left): mask = NX_DEVICELALTKEYMASK
        case (.option, .right): mask = NX_DEVICERALTKEYMASK
        case (.command, .left): mask = NX_DEVICELCMDKEYMASK
        case (.command, .right): mask = NX_DEVICERCMDKEYMASK
        case (.shift, .left): mask = NX_DEVICELSHIFTKEYMASK
        case (.shift, .right): mask = NX_DEVICERSHIFTKEYMASK
        case (.function, _): return flags.contains(.maskSecondaryFn)
        }
        return flags.rawValue & UInt64(mask) != 0
    }

    static func modifierCode(key: ModifierKey, side: ModifierSide) -> UInt32 {
        switch (key, side) {
        case (.control, .left): return 59
        case (.control, .right): return 62
        case (.option, .left): return 58
        case (.option, .right): return 61
        case (.command, .left): return 55
        case (.command, .right): return 54
        case (.shift, .left): return 56
        case (.shift, .right): return 60
        case (.function, _): return 63
        }
    }
    static func modifierKeySide(forKeyCode code: UInt32) -> (ModifierKey, ModifierSide)? {
        switch code {
        case 59: return (.control, .left)
        case 62: return (.control, .right)
        case 58: return (.option, .left)
        case 61: return (.option, .right)
        case 55: return (.command, .left)
        case 54: return (.command, .right)
        case 56: return (.shift, .left)
        case 60: return (.shift, .right)
        case 63: return (.function, .left)
        default: return nil
        }
    }
    static func flagsContain(_ flags: CGEventFlags, key: ModifierKey) -> Bool {
        switch key {
        case .control: return flags.contains(.maskControl)
        case .option: return flags.contains(.maskAlternate)
        case .command: return flags.contains(.maskCommand)
        case .shift: return flags.contains(.maskShift)
        case .function: return flags.contains(.maskSecondaryFn)
        }
    }
    static func flagsContainOnly(_ flags: CGEventFlags, key: ModifierKey) -> Bool {
        var others = flags
        switch key {
        case .control: others.remove(.maskControl)
        case .option: others.remove(.maskAlternate)
        case .command: others.remove(.maskCommand)
        case .shift: others.remove(.maskShift)
        case .function: others.remove(.maskSecondaryFn)
        }
        // Caps Lock, numeric pad, help and coalescing flags never block solo.
        others.remove([.maskAlphaShift, .maskHelp, .maskNumericPad, .maskNonCoalesced])
        let extra: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        return others.intersection(extra).isEmpty
    }
}

// MARK: - Bounded mouse-button confirmation seams (injectable, no global posting in tests)

/// Thin native observer for mouse-button confirmation. Production consumes the
/// matching down/up via a CGEvent tap so the gesture never navigates; tests
/// inject a fake and drive the manager handler directly with synthetic events.
public protocol MouseConfirmationMonitor: AnyObject {
    func start(button: MouseButton, handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) throws
    func stop()
}

/// Bounded 10s timer. Production fires in `.common` modes so it fires while
/// the native menu is tracking; tests inject a manual fake.
public protocol MouseConfirmationTimer: AnyObject {
    func schedule(delay: TimeInterval, handler: @escaping () -> Void)
    func invalidate()
}

/// Native confirmation tap: observes ONLY otherMouseDown/Up, consumes the
/// expected button so it never navigates. Silent AX check only; never prompts.
/// No raw HID, no new permission scope — reuses existing Accessibility access.
final class CGEventMouseConfirmationMonitor: MouseConfirmationMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapBox: ConfirmationTapBox?
    func start(button: MouseButton, handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) throws {
        // Silent check only; never prompts here. AX-denied surfaces distinctly.
        guard AXIsProcessTrusted() else {
            throw VellaError.message(ShortcutManager.mouseConfirmationAccessDeniedMessage)
        }
        stop()
        // Mask matches observed types: expected other-button down/up for commit,
        // plus wrong other-button and ordinary left/right downs for SAME-row feedback.
        // Left/right are never consumed. No key observation.
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
        // tapBox owns the box for the monitor lifetime; context is unretained
        // (no manual retain/release). stop()/deinit clears it, so the pointer
        // never dangles and failures never pretend monitoring.
        let box = ConfirmationTapBox(handler: handler, onFailure: onFailure)
        tapBox = box
        let context = Unmanaged<ConfirmationTapBox>.passUnretained(box).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, data in
            guard let data else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<ConfirmationTapBox>.fromOpaque(data).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let rawTap = box.liveTap { CGEvent.tapEnable(tap: rawTap, enable: true) }
                let failure = box.onFailure
                DispatchQueue.main.async { failure() }
                return Unmanaged.passUnretained(event)
            }
            if box.handler(type, event) { return nil } // consumed: never navigates
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            tapBox = nil
            throw VellaError.message(ShortcutManager.mouseConfirmationUnavailableMessage)
        }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            tapBox = nil
            // tapCreate succeeded but no runloop source: fail cleanly, never pretend.
            throw VellaError.message(ShortcutManager.mouseConfirmationUnavailableMessage)
        }
        box.liveTap = tap
        self.tap = tap
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        _ = button // button filtering lives in the manager handler (testable reducer)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil; self.tap = nil; self.tapBox = nil
    }
    deinit { stop() }
}

private final class ConfirmationTapBox {
    let handler: (CGEventType, CGEvent) -> Bool
    let onFailure: () -> Void
    var liveTap: CFMachPort?
    init(handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) { self.handler = handler; self.onFailure = onFailure }
}

/// Production timer scheduled in event-tracking + common modes so the 10s
/// bound fires while the native menu is tracking.
final class CommonRunLoopMouseConfirmationTimer: MouseConfirmationTimer {
    private var timer: Timer?
    func schedule(delay: TimeInterval, handler: @escaping () -> Void) {
        invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in handler() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    func invalidate() { timer?.invalidate(); timer = nil }
    deinit { invalidate() }
}

final class ShortcutActionBox {
    var handler: ((String) -> Void)?
}

// MARK: - Compact native transient key recorder

/// A small floating panel that actually receives keys. Menu actions close the
/// menu, so a local monitor alone cannot capture the next chord when another
/// app is frontmost. The panel becomes key, captures one chord (or Esc), then
/// closes. Activation is suspended while it is open.
final class ShortcutKeyRecorderPanel: NSPanel {
    var onChord: ((UInt32, UInt32) -> Bool)?
    var onCancel: (() -> Void)?
    private let promptField = NSTextField(labelWithString: "Press shortcut…  (Esc cancels)")
    private let errorField = NSTextField(labelWithString: "")
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        level = .floating
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        title = "Record Shortcut"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        promptField.frame = NSRect(x: 20, y: 76, width: 260, height: 20)
        promptField.alignment = .center
        promptField.font = .systemFont(ofSize: 13, weight: .medium)
        // Multiline wrapping at a readable height: full validation/conflict errors
        // stay visible inside the compact panel instead of clipping to one line.
        errorField.frame = NSRect(x: 20, y: 12, width: 260, height: 56)
        errorField.alignment = .center
        errorField.font = .systemFont(ofSize: 11)
        errorField.textColor = .systemOrange
        errorField.usesSingleLineMode = false
        errorField.lineBreakMode = .byWordWrapping
        errorField.maximumNumberOfLines = 3
        content.addSubview(promptField)
        content.addSubview(errorField)
        contentView = content
    }
    func showError(_ text: String) {
        errorField.stringValue = text
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        let mods = ShortcutManager.carbonModifiers(from: event.modifierFlags)
        if let onChord = onChord {
            // Keep the panel open on validation failure so the user can retry.
            if !onChord(UInt32(event.keyCode), mods) {
                NSSound.beep()
            }
        }
    }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Manager (MainActor, injected sinks for tests)

@MainActor
public final class ShortcutManager: ObservableObject {
    public let store: ShortcutStore
    public private(set) var engine: ShortcutEngine
    public private(set) var configuration: ShortcutConfiguration
    /// Actually registered binding (fallback default when desired cannot start).
    public private(set) var activeConfiguration: ShortcutConfiguration?
    public private(set) var isUsingFallback = false
    public private(set) var lastError: String?
    public private(set) var isCapturingKeys = false
    public var onAction: ((String) -> Void)? {
        didSet { actionBox.handler = onAction }
    }
    public var permissionCheck: (() -> Bool)?
    public var menuCancel: (() -> Void)?
    var carbon: CarbonShortcutRegistrar
    var eventTap: EventTapShortcutRegistrar
    private var activeRegistrar: (any ShortcutRegistrar)?
    private var injectedRegistrar: (any ShortcutRegistrar)?
    private weak var modelRef: Model?
    private let actionBox: ShortcutActionBox
    private var recorderPanel: ShortcutKeyRecorderPanel?
    private var interruptionObservers: [NSObjectProtocol] = []
    // MARK: Bounded mouse-button confirmation (prior config persists until commit on up)
    public private(set) var pendingMouseButton: MouseButton?
    public private(set) var mouseConfirmationError: String?
    public private(set) var mouseConfirmationErrorButton: MouseButton?
    /// Full diagnostic for the error tooltip (commit failures); nil when row text is complete.
    public private(set) var mouseConfirmationErrorDetail: String?
    /// Bounded wrong-button feedback label (e.g. "Button 5 detected"); nil when none.
    /// Never contains raw huge ints; unknown buttons map to "Other button detected".
    public private(set) var mouseConfirmationDetectedLabel: String?
    private var confirmationDownSeen = false
    private var confirmationGeneration: UInt64 = 0
    private var confirmationMonitor: (any MouseConfirmationMonitor)?
    private var confirmationTimer: (any MouseConfirmationTimer)?
    private var isCommittingConfirmation = false
    public var confirmationTimeoutInterval: TimeInterval = 10
    public var makeConfirmationMonitor: () -> any MouseConfirmationMonitor = { CGEventMouseConfirmationMonitor() }
    public var makeConfirmationTimer: () -> any MouseConfirmationTimer = { CommonRunLoopMouseConfirmationTimer() }
    /// Silent Accessibility check seam (production `AXIsProcessTrusted()`, no prompt).
    /// Tests inject true/false; no TCC prompts, no new scope.
    public var confirmationAccessCheck: () -> Bool = { AXIsProcessTrusted() }
    public var onMouseConfirmationChange: (() -> Void)?
    public var isConfirmingMouseButton: Bool { pendingMouseButton != nil }
    nonisolated public static var mouseConfirmationTimeoutMessage: String { "Button not detected" }
    /// Concise AX-denied claim, shown only when the silent check actually failed.
    nonisolated public static var mouseConfirmationAccessDeniedMessage: String { "Need Accessibility access" }
    /// Concise generic observation failure (tapCreate/source nil with AX true).
    /// Never claims AX denial; no remapping/hardware diagnosis.
    nonisolated public static var mouseConfirmationUnavailableMessage: String { "Could not observe input" }
    nonisolated public static func mouseConfirmationPrompt(for button: MouseButton) -> String {
        switch button {
        case .middle: return "Press middle button to confirm…"
        case .button3: return "Press side button 4 to confirm…"
        case .button4: return "Press side button 5 to confirm…"
        }
    }
    /// Compact commit-failure row text; full diagnostic stays in the tooltip.
    nonisolated public static var mouseConfirmationUnchangedMessage: String { "Shortcut unchanged" }
    /// Pre-reserved mouse row width at factory creation (longest prompt +
    /// feedback suffix + concise failures/compact unchanged). Inline updates
    /// never resize a tracking menu.
    public static func mouseConfirmationReservedWidth() -> CGFloat {
        // AppKit metrics; called from factory (MainActor) and tests.
        let font = NSFont.menuFont(ofSize: 0)
        var strings = [
            "Middle Click", "Side Button 4", "Side Button 5",
            mouseConfirmationPrompt(for: .middle),
            mouseConfirmationPrompt(for: .button3),
            mouseConfirmationPrompt(for: .button4),
            mouseConfirmationTimeoutMessage,
            mouseConfirmationAccessDeniedMessage,
            mouseConfirmationUnavailableMessage,
            mouseConfirmationUnchangedMessage,
        ]
        // Worst-case pending feedback suffixes (bounded labels only, no raw ints).
        let feedbacks = [
            "Middle button detected", "Button 4 detected", "Button 5 detected",
            "Left click detected", "Right click detected", "Other button detected",
        ] + (6...32).map { "Button \($0) detected" }
        for button in [MouseButton.middle, .button3, .button4] {
            let base = mouseConfirmationPrompt(for: button)
            strings.append(base)
            for fb in feedbacks { strings.append("\(base) (\(fb))") }
        }
        let widest = strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(180, widest + 52)
    }
    /// Instance row text used by BOTH factory creation and in-place tracking refresh.
    /// Pending row shows base prompt plus bounded "(X detected)" suffix when a
    /// wrong button was observed; otherwise the base prompt. No apply/cancel here.
    public func mouseConfirmationRowText(for button: MouseButton) -> String {
        let base = Self.mouseConfirmationPrompt(for: button)
        if pendingMouseButton == button, let feedback = mouseConfirmationDetectedLabel {
            return "\(base) (\(feedback))"
        }
        return base
    }
    /// Tooltip for mouse rows: full commit-failure diagnostic when the compact
    /// "Shortcut unchanged" row is shown; otherwise nil.
    public func mouseConfirmationRowToolTip(for button: MouseButton) -> String? {
        if mouseConfirmationErrorButton == button, mouseConfirmationError != nil {
            return mouseConfirmationErrorDetail
        }
        return nil
    }
    /// Bounded detected-button label for feedback; no raw huge ints, no key observation.
    nonisolated public static func mouseConfirmationDetectedLabel(forButtonNumber number: Int64, eventType: CGEventType) -> String {
        if eventType == .leftMouseDown { return "Left click detected" }
        if eventType == .rightMouseDown { return "Right click detected" }
        if number == 2 { return "Middle button detected" }
        if number == 3 { return "Button 4 detected" }
        if number == 4 { return "Button 5 detected" }
        if (5...31).contains(number) { return "Button \(number + 1) detected" }
        if number == 0 { return "Left click detected" }
        if number == 1 { return "Right click detected" }
        return "Other button detected"
    }

    public static var shortcutsFileURL: URL {
        Backend.support.appendingPathComponent("shortcuts.json")
    }
    public var currentLabel: String { ShortcutLabels.display(configuration) }
    public var activeLabel: String { ShortcutLabels.display(activeConfiguration ?? configuration) }
    public var requiresEventTap: Bool { configuration.trigger.requiresEventTap }
    public var eventTapPermissionNote: String {
        "Modifier and mouse bindings need Accessibility access. Key chords need none. No prompt appears until you choose such a binding."
    }
    public var canEdit: Bool { engine.canChangeSettings && !isCapturingKeys }

    /// Load the supplied store; the default is memory-only. Production launch
    /// supplies its file-backed store and explicitly reloads before registering.
    init(model: Model? = nil, store: ShortcutStore? = nil) {
        let resolved = store ?? ShortcutStore(fileURL: nil)
        resolved.load()
        let box = ShortcutActionBox()
        self.actionBox = box
        self.store = resolved
        self.configuration = resolved.configuration
        self.carbon = CarbonShortcutRegistrar()
        self.eventTap = EventTapShortcutRegistrar()
        self.modelRef = model
        self.injectedRegistrar = nil
        self.activeRegistrar = nil
        self.engine = ShortcutEngine(configuration: resolved.configuration, sinks: .init(
            start: { [weak model, weak box] in
                box?.handler?("start")
                guard let m = model else { return }
                _ = m.ensureAutomaticInsertion()
                m.toggle()
            },
            finish: { [weak model, weak box] in box?.handler?("finish"); model?.finish() },
            cancel: { [weak model, weak box] in box?.handler?("cancel"); model?.cancel() },
            isRecording: { [weak model] in model?.phase == .recording },
            isBusy: { [weak model] in model?.busy == true },
            currentOperation: { [weak model] in model?.captureGeneration ?? 0 }
        ))
        // Delayed solo confirmation carries the physical down time into the engine.
        eventTap.confirmedPressHandler = { [weak self] down in self?.handlePress(downTime: down) }
        updateModelHints()
    }

    /// Test init with full control (no host audio/input).
    public init(engine: ShortcutEngine, store: ShortcutStore, registrar: (any ShortcutRegistrar)? = nil) {
        self.actionBox = ShortcutActionBox()
        self.engine = engine
        self.store = store
        self.configuration = store.configuration
        self.carbon = CarbonShortcutRegistrar()
        self.eventTap = EventTapShortcutRegistrar()
        self.injectedRegistrar = registrar
        self.activeRegistrar = registrar
        self.activeConfiguration = registrar?.registered
        self.modelRef = nil
        engine.updateConfiguration(store.configuration)
    }

    // MARK: Registration

    private func registrarFor(_ config: ShortcutConfiguration) -> any ShortcutRegistrar {
        if let injectedRegistrar { return injectedRegistrar }
        return config.trigger.requiresEventTap ? eventTap : carbon
    }

    private func updateModelHints() {
        // Hints and Start equivalents always reflect the WORKING binding, never stale.
        let working = isUsingFallback ? (activeConfiguration ?? .default) : configuration
        modelRef?.shortcutHint = ShortcutLabels.triggerDisplay(working.trigger)
        if case .keyChord(let code, let mods) = working.trigger {
            modelRef?.shortcutChordKeyCode = code
            modelRef?.shortcutChordModifiers = mods
        }
    }

    /// Load the owned file-backed store (production launch path) and adopt it.
    /// Test delegates inject synthetic stores and never call this with the home URL.
    public func reloadFromStore() {
        store.load()
        configuration = store.configuration
        engine.updateConfiguration(configuration)
        updateModelHints()
    }
    /// Register the stored (or default) binding. Call once at launch; never prompts.
    /// On event-tap failure the stored choice is preserved in the file while the
    /// default Carbon chord stays working as a fallback.
    @discardableResult
    public func registerStoredOrDefault() -> Bool {
        let config = store.configuration
        do {
            let registrar = registrarFor(config)
            try registrar.register(config, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
            if let tap = registrar as? EventTapShortcutRegistrar {
                tap.interruptionHandler = { [weak self] in self?.handleInterruption() }
                tap.confirmedPressHandler = { [weak self] down in self?.handlePress(downTime: down) }
            }
            activeRegistrar = registrar
            activeConfiguration = config
            isUsingFallback = false
            configuration = config
            engine.updateConfiguration(config)
            lastError = nil
            updateModelHints()
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Preserve the stored choice; fall back to a working default chord.
            if config.trigger.requiresEventTap {
                do {
                    let fallback = ShortcutConfiguration(trigger: ShortcutConfiguration.default.trigger, behavior: config.behavior)
                    let fallbackRegistrar = registrarFor(fallback)
                    try fallbackRegistrar.register(fallback, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                    activeRegistrar = fallbackRegistrar
                    activeConfiguration = fallback
                    isUsingFallback = true
                    configuration = config
                    engine.updateConfiguration(config)
                    lastError = "\(message) Using ⌃⌘N until permitted."
                    updateModelHints()
                } catch {
                    lastError = message
                    configuration = config
                    engine.updateConfiguration(config)
                    updateModelHints()
                }
            } else {
                lastError = message
            }
            return false
        }
    }

    @discardableResult
    public func apply(_ config: ShortcutConfiguration) -> Bool {
        // Changing any setting cancels a pending mouse confirmation (new selection
        // starts its own confirmation via beginMouseButtonConfirmation). The commit
        // path sets isCommittingConfirmation to skip this self-cancel.
        if !isCommittingConfirmation, isConfirmingMouseButton {
            stopConfirmationSilently(notify: false)
        }
        guard engine.canChangeSettings else {
            lastError = "Finish or stop recording before changing shortcuts."
            return false
        }
        // Never dismiss the transient recorder here: a failed validation or
        // conflicting registration must leave the panel open for retry. The panel
        // closes itself on success; handleCapturedKey closes the direct path.
        if let err = ShortcutValidation.validate(config) {
            lastError = err
            return false
        }
        let previous = configuration
        let previousActive = activeConfiguration
        let previousRegistrar = activeRegistrar
        let previousFallback = isUsingFallback
        engine.updateConfiguration(config)
        do {
            let registrar = registrarFor(config)
            // Preserve the prior working registration until the new one succeeds.
            // (Carbon registrar itself is transactional via trial hotkey.)
            try registrar.register(config, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
            if let tap = registrar as? EventTapShortcutRegistrar {
                tap.interruptionHandler = { [weak self] in self?.handleInterruption() }
                tap.confirmedPressHandler = { [weak self] down in self?.handlePress(downTime: down) }
            }
            guard store.save(config) else {
                // Save failed: restore prior registration before reporting.
                registrar.unregister()
                if let previousRegistrar, let prev = previousActive ?? Optional(previous) {
                    try? previousRegistrar.register(prev, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                }
                throw VellaError.message(store.lastError ?? "Could not save shortcut.")
            }
            if registrar !== previousRegistrar { previousRegistrar?.unregister() }
            activeRegistrar = registrar
            activeConfiguration = config
            isUsingFallback = false
            configuration = config
            lastError = nil
            updateModelHints()
            objectWillChange.send()
            return true
        } catch {
            // Transactional rollback: restore engine + prior working registration.
            engine.updateConfiguration(previous)
            if let previousRegistrar, let prev = previousActive ?? Optional(previous) {
                if registrarFor(prev) === previousRegistrar {
                    try? previousRegistrar.register(prev, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                    activeRegistrar = previousRegistrar
                    activeConfiguration = prev
                }
            } else if let injectedRegistrar {
                try? injectedRegistrar.register(previous, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                activeRegistrar = injectedRegistrar
                activeConfiguration = previous
            }
            isUsingFallback = previousFallback
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updateModelHints()
            objectWillChange.send()
            return false
        }
    }

    public func resetToDefault() {
        _ = apply(.default)
    }

    // MARK: Bounded mouse-button confirmation (inline row, no popup)

    /// UI entry: selecting ANY Mouse Button row starts confirmation, never applies.
    /// Same-button re-selection also confirms. Prior config persists until matching up.
    @discardableResult
    public func beginMouseButtonConfirmation(_ button: MouseButton) -> Bool {
        guard engine.canChangeSettings else {
            lastError = "Finish or stop recording before changing shortcuts."
            return false
        }
        if let err = ShortcutValidation.validate(ShortcutConfiguration(trigger: .mouseButton(button: button), behavior: configuration.behavior)) {
            lastError = err
            return false
        }
        // Changing selection cancels any previous pending confirmation.
        stopConfirmationSilently(notify: false)
        // Silent check only; never prompts. AX-denied surfaces distinctly.
        guard confirmationAccessCheck() else {
            pendingMouseButton = nil
            confirmationDownSeen = false
            mouseConfirmationError = Self.mouseConfirmationAccessDeniedMessage
            mouseConfirmationErrorButton = button
            mouseConfirmationErrorDetail = nil
            mouseConfirmationDetectedLabel = nil
            objectWillChange.send()
            onMouseConfirmationChange?()
            return false
        }
        confirmationGeneration &+= 1
        let gen = confirmationGeneration
        pendingMouseButton = button
        mouseConfirmationError = nil
        mouseConfirmationErrorButton = nil
        mouseConfirmationErrorDetail = nil
        mouseConfirmationDetectedLabel = nil
        confirmationDownSeen = false
        let monitor = makeConfirmationMonitor()
        confirmationMonitor = monitor
        do {
            try monitor.start(button: button, handler: { [weak self] type, event in
                guard let self else { return false }
                // Hop to MainActor for state; capture synchronously in handler below.
                // The tap callback runs on the main runloop; MainActor-isolated
                // processing is dispatched via the manager queue below in commit path.
                // For immediate consume decision we call the isolated reducer via assume.
                return MainActor.assumeIsolated { self.processConfirmationTapEvent(type: type, event: event, expectedGeneration: gen) }
            }, onFailure: { [weak self] in
                Task { @MainActor in self?.handleConfirmationMonitorFailure(generation: gen) }
            })
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stopConfirmationSilently(notify: false)
            pendingMouseButton = nil
            mouseConfirmationError = message
            mouseConfirmationErrorButton = button
            mouseConfirmationErrorDetail = nil
            mouseConfirmationDetectedLabel = nil
            objectWillChange.send()
            onMouseConfirmationChange?()
            return false
        }
        let timer = makeConfirmationTimer()
        confirmationTimer = timer
        timer.schedule(delay: confirmationTimeoutInterval) { [weak self] in
            Task { @MainActor in self?.handleConfirmationTimeout(generation: gen) }
        }
        objectWillChange.send()
        onMouseConfirmationChange?()
        return true
    }

    /// Explicit cancel: root menu close/Escape, changing setting/selection, busy.
    public func cancelMouseButtonConfirmation() {
        guard isConfirmingMouseButton || mouseConfirmationError != nil else { return }
        stopConfirmationSilently(notify: true)
    }

    private func stopConfirmationSilently(notify: Bool) {
        confirmationGeneration &+= 1
        confirmationMonitor?.stop()
        confirmationMonitor = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDownSeen = false
        pendingMouseButton = nil
        mouseConfirmationError = nil
        mouseConfirmationErrorButton = nil
        mouseConfirmationErrorDetail = nil
        mouseConfirmationDetectedLabel = nil
        if notify {
            objectWillChange.send()
            onMouseConfirmationChange?()
        }
    }

    private func stopConfirmationKeepingError() {
        confirmationGeneration &+= 1
        confirmationMonitor?.stop()
        confirmationMonitor = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDownSeen = false
        pendingMouseButton = nil
        mouseConfirmationDetectedLabel = nil
        mouseConfirmationErrorDetail = nil
    }

    /// Production tap entry, callable with synthetic events in tests (no posting/TCC).
    /// Consumes ONLY the expected other-button down/up (true). Wrong other-button
    /// downs and left/right downs update SAME-row feedback, keep waiting, and are
    /// NEVER consumed. Unmatched ups, other ups, and all other types pass through.
    /// No typed-key observation.
    @discardableResult
    public func processConfirmationTapEvent(type: CGEventType, event: CGEvent, expectedGeneration: UInt64? = nil) -> Bool {
        let gen = expectedGeneration ?? confirmationGeneration
        guard gen == confirmationGeneration, let expected = pendingMouseButton else { return false }
        guard engine.canChangeSettings else {
            // Busy during confirmation cancels; do not consume the click.
            Task { @MainActor in self.cancelMouseButtonConfirmation() }
            return false
        }
        // Ordinary clicks inform accurate feedback but are never consumed.
        if type == .leftMouseDown || type == .rightMouseDown {
            let label = Self.mouseConfirmationDetectedLabel(forButtonNumber: type == .leftMouseDown ? 0 : 1, eventType: type)
            if mouseConfirmationDetectedLabel != label {
                mouseConfirmationDetectedLabel = label
                objectWillChange.send()
                onMouseConfirmationChange?()
            }
            return false
        }
        guard type == .otherMouseDown || type == .otherMouseUp else { return false }
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        let expectedNumber = Int64(expected.rawValue)
        if number != expectedNumber {
            // Wrong other-button: feedback in SAME row, keep waiting, never consume.
            // Only downs inform feedback; wrong ups pass through silently.
            if type == .otherMouseDown {
                let label = Self.mouseConfirmationDetectedLabel(forButtonNumber: number, eventType: type)
                if mouseConfirmationDetectedLabel != label {
                    mouseConfirmationDetectedLabel = label
                    objectWillChange.send()
                    onMouseConfirmationChange?()
                }
            }
            return false
        }
        if type == .otherMouseDown {
            if confirmationDownSeen { return true } // autorepeat: consume silently
            confirmationDownSeen = true
            // Correct button found: clear wrong-button feedback, keep waiting for up.
            if mouseConfirmationDetectedLabel != nil {
                mouseConfirmationDetectedLabel = nil
                objectWillChange.send()
                onMouseConfirmationChange?()
            }
            return true
        } else {
            guard confirmationDownSeen else { return false } // unmatched up passes through
            // Prefer commit on matching up: consume first, commit async so the
            // release can never reach the new Hold binding.
            let commitGen = confirmationGeneration
            let commitButton = expected
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in self?.commitConfirmedMouseButton(button: commitButton, generation: commitGen) }
            }
            return true
        }
    }

    private func commitConfirmedMouseButton(button: MouseButton, generation: UInt64) {
        guard generation == confirmationGeneration, pendingMouseButton == button else { return }
        guard engine.canChangeSettings else { cancelMouseButtonConfirmation(); return }
        // Tear down confirmation FIRST so late callbacks cannot leak into activation.
        let errorButton = button
        confirmationMonitor?.stop()
        confirmationMonitor = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDownSeen = false
        pendingMouseButton = nil
        mouseConfirmationError = nil
        mouseConfirmationErrorButton = nil
        mouseConfirmationErrorDetail = nil
        mouseConfirmationDetectedLabel = nil
        confirmationGeneration &+= 1
        isCommittingConfirmation = true
        defer { isCommittingConfirmation = false }
        let ok = apply(ShortcutConfiguration(trigger: .mouseButton(button: button), behavior: configuration.behavior))
        if !ok {
            // Compact row text so long persistence/registration errors cannot clip;
            // full diagnostic stays in the tooltip.
            let full = lastError ?? Self.mouseConfirmationUnavailableMessage
            mouseConfirmationError = Self.mouseConfirmationUnchangedMessage
            mouseConfirmationErrorButton = errorButton
            mouseConfirmationErrorDetail = full
        }
        objectWillChange.send()
        onMouseConfirmationChange?()
    }

    func handleConfirmationTimeout(generation: UInt64) {
        guard generation == confirmationGeneration, let target = pendingMouseButton else { return }
        stopConfirmationKeepingError()
        // Bounded 10s timeout reports in the same row; no hardware diagnosis.
        mouseConfirmationError = Self.mouseConfirmationTimeoutMessage
        mouseConfirmationErrorButton = target
        mouseConfirmationErrorDetail = nil
        objectWillChange.send()
        onMouseConfirmationChange?()
    }

    private func handleConfirmationMonitorFailure(generation: UInt64) {
        guard generation == confirmationGeneration, pendingMouseButton != nil else { return }
        // Tap failure (sleep/lock/tap loss): cancel silently, restore row.
        stopConfirmationSilently(notify: true)
    }

    // MARK: Activation events (called by registrars; testable directly)

    public func handlePress(isRepeat: Bool = false, downTime: TimeInterval? = nil) {
        // Suspend activation while the transient key recorder owns the keyboard
        // or a mouse-button confirmation is pending (its gesture never activates).
        guard !isCapturingKeys, !isConfirmingMouseButton else { return }
        menuCancel?()
        // Permission gates only potential new starts (idle). Stopping, finishing,
        // or arming a tap-off while recording/busy never requires insertion
        // permission: Finish falls back to clipboard-only.
        if engine.canChangeSettings, let check = permissionCheck, !check() { return }
        _ = engine.press(isRepeat: isRepeat, downTime: downTime)
    }
    public func handleRelease() {
        guard !isCapturingKeys, !isConfirmingMouseButton else { return }
        _ = engine.release()
    }
    public func handleReleaseForPressID(_ id: UInt64) {
        guard !isCapturingKeys, !isConfirmingMouseButton else { return }
        _ = engine.releaseForPressID(id)
    }
    public func handleInterruption() {
        let wasConfirming = isConfirmingMouseButton
        if wasConfirming {
            // Sleep/lock/tap failure cancels confirmation; prior binding stays working.
            stopConfirmationSilently(notify: false)
        }
        engine.handleInterruption()
        // Reset pending native input and invalidate queued callbacks without
        // losing registration or notifying recursively.
        activeRegistrar?.resetPendingInput()
        if (activeRegistrar as AnyObject?) !== (eventTap as AnyObject) {
            eventTap.resetPendingInput()
        }
        if wasConfirming {
            objectWillChange.send()
            onMouseConfirmationChange?()
        }
        onAction?("interrupt")
    }

    func beginObservingSystemInterruptions() {
        guard interruptionObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] as [NSNotification.Name] {
            interruptionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleInterruption() }
            })
        }
        interruptionObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleInterruption() }
        })
    }

    // MARK: Native key recorder (transient panel owns the keyboard)

    public func beginKeyCapture() {
        // Starting key capture cancels bounded mouse confirmation (changing selection).
        if isConfirmingMouseButton { stopConfirmationSilently(notify: false) }
        guard engine.canChangeSettings else {
            lastError = "Finish or stop recording before changing shortcuts."
            return
        }
        cancelKeyCapture()
        isCapturingKeys = true
        objectWillChange.send()
        // Unit tests (no runloop) drive handleCapturedKey directly; only show UI live.
        guard NSApplication.shared.isRunning else { return }
        let panel = ShortcutKeyRecorderPanel()
        recorderPanel = panel
        panel.onCancel = { [weak self] in self?.cancelKeyCapture() }
        panel.onChord = { [weak self, weak panel] code, mods in
            guard let self else { return false }
            let ok = self.apply(ShortcutConfiguration(trigger: .keyChord(keyCode: code, modifiers: mods), behavior: self.configuration.behavior))
            if ok {
                self.cancelKeyCapture()
            } else {
                panel?.showError(self.lastError ?? "That chord cannot be used.")
            }
            return ok
        }
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    public func cancelKeyCapture() {
        isCapturingKeys = false
        recorderPanel?.orderOut(nil)
        recorderPanel = nil
        objectWillChange.send()
    }
    @discardableResult
    public func handleCapturedKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let config = ShortcutConfiguration(trigger: .keyChord(keyCode: keyCode, modifiers: modifiers), behavior: configuration.behavior)
        let ok = apply(config)
        // Direct (non-panel) path always ends capture; the transient panel instead
        // stays open on failure for retry and closes itself on success.
        if isCapturingKeys { cancelKeyCapture() }
        return ok
    }
    public func applyBehavior(_ behavior: ShortcutBehavior) -> Bool {
        apply(ShortcutConfiguration(trigger: configuration.trigger, behavior: behavior))
    }
    public func applyModifierOnly(key: ModifierKey, side: ModifierSide) -> Bool {
        apply(ShortcutConfiguration(trigger: .modifierOnly(key: key, side: side), behavior: configuration.behavior))
    }
    public func applyMouseButton(_ button: MouseButton) -> Bool {
        apply(ShortcutConfiguration(trigger: .mouseButton(button: button), behavior: configuration.behavior))
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= ShortcutConfiguration.controlFlag }
        if flags.contains(.option) { mods |= ShortcutConfiguration.optionFlag }
        if flags.contains(.shift) { mods |= ShortcutConfiguration.shiftFlag }
        if flags.contains(.command) { mods |= ShortcutConfiguration.cmdFlag }
        if flags.contains(.function) { mods |= 0x800000 }
        return mods
    }

    /// Start/Finish menu key equivalent reflecting the WORKING binding.
    nonisolated static func menuKeyEquivalent(for config: ShortcutConfiguration) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard case .keyChord(let code, let mods) = config.trigger else { return ("", []) }
        let key = ShortcutLabels.keyName(keyCode: code).lowercased()
        guard key.count == 1 else { return ("", []) }
        var flags: NSEvent.ModifierFlags = []
        if mods & ShortcutConfiguration.controlFlag != 0 { flags.insert(.control) }
        if mods & ShortcutConfiguration.cmdFlag != 0 { flags.insert(.command) }
        if mods & ShortcutConfiguration.optionFlag != 0 { flags.insert(.option) }
        if mods & ShortcutConfiguration.shiftFlag != 0 { flags.insert(.shift) }
        if flags.isEmpty { return ("", []) }
        return (key, flags)
    }
}

// MARK: - Shortcuts submenu factory (compact native menu, keep-open controls)

@MainActor
enum ShortcutMenuFactory {
    static let permissionNoteID = NSUserInterfaceItemIdentifier("shortcut.permissionNote")
    static let settingsID = NSUserInterfaceItemIdentifier("shortcut.settings")
    static let errorID = NSUserInterfaceItemIdentifier("shortcut.error")

    static func refreshStatus(in menu: NSMenu, manager: ShortcutManager) {
        for item in menu.items {
            if item.identifier == permissionNoteID || item.identifier == settingsID {
                item.isHidden = !manager.requiresEventTap
            } else if item.identifier == errorID {
                item.title = String((manager.lastError ?? "").prefix(96))
                item.toolTip = manager.lastError
                item.isHidden = manager.lastError == nil
            }
        }
    }

    static func shortcutsItem(manager: ShortcutManager, model: Model, target: AnyObject,
                              selectBehavior: Selector, recordKeys: Selector, cancelCapture: Selector,
                              selectModifier: Selector, selectMouse: Selector, resetDefault: Selector,
                              openSettings: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canEdit = manager.canEdit && !model.busy && model.phase != .recording
        let working = manager.isUsingFallback ? (manager.activeConfiguration ?? .default) : manager.configuration
        var currentTitle = "Current: \(ShortcutLabels.display(manager.configuration))"
        if manager.isUsingFallback {
            currentTitle += " (using \(ShortcutLabels.triggerDisplay(working.trigger)))"
        } else if case .modifierOnly(let key, _) = manager.configuration.trigger, key == .function {
            currentTitle = "Current: Fn · \(manager.configuration.behavior.title)"
        }
        let current = NSMenuItem(title: currentTitle, action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        for behavior in ShortcutBehavior.allCases {
            let title: String
            switch behavior {
            case .toggle: title = "Toggle"
            case .holdToTalk: title = "Hold to Talk"
            case .tapOrHold: title = "Tap or Hold"
            }
            let entry = SettingsMenuItem(title: title, target: target, action: selectBehavior)
            entry.target = target as? NSObject
            entry.representedObject = behavior.rawValue
            entry.state = manager.configuration.behavior == behavior ? .on : .off
            entry.isEnabled = canEdit
            entry.synchronize()
            entry.toolTip = behavior == .tapOrHold ? "Tap (<0.3s) keeps recording; hold finishes on release." : nil
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        if manager.isCapturingKeys {
            let capturing = NSMenuItem(title: "Press keys… (Esc cancels)", action: cancelCapture, keyEquivalent: "")
            capturing.target = target as? NSObject
            capturing.isEnabled = canEdit
            menu.addItem(capturing)
        } else {
            let record = NSMenuItem(title: "Record Key Chord…", action: recordKeys, keyEquivalent: "")
            record.target = target as? NSObject
            record.isEnabled = canEdit
            record.toolTip = "Carbon press/release; no new permissions."
            menu.addItem(record)
        }
        // Modifier-only picker (nested to keep the top submenu compact).
        let modifierRoot = NSMenuItem(title: "Modifier-Only", action: nil, keyEquivalent: "")
        let modifierMenu = NSMenu()
        modifierMenu.autoenablesItems = false
        let modifiers = [("Left ⌃", ModifierKey.control, ModifierSide.left),
                         ("Right ⌃", ModifierKey.control, ModifierSide.right),
                         ("Left ⌥", ModifierKey.option, ModifierSide.left),
                         ("Right ⌥", ModifierKey.option, ModifierSide.right),
                         ("Left ⌘", ModifierKey.command, ModifierSide.left),
                         ("Right ⌘", ModifierKey.command, ModifierSide.right),
                         ("Left ⇧", ModifierKey.shift, ModifierSide.left),
                         ("Right ⇧", ModifierKey.shift, ModifierSide.right),
                         ("Fn", ModifierKey.function, ModifierSide.left)]
        for (title, key, side) in modifiers {
            let entry = SettingsMenuItem(title: title, target: target, action: selectModifier)
            entry.target = target as? NSObject
            entry.representedObject = "\(key.rawValue):\(side.rawValue)"
            if case .modifierOnly(let k, let s) = manager.configuration.trigger, k == key, (key == .function || s == side) {
                entry.state = .on
            } else { entry.state = .off }
            entry.isEnabled = canEdit
            entry.synchronize()
            modifierMenu.addItem(entry)
        }
        modifierRoot.submenu = modifierMenu
        menu.addItem(modifierRoot)
        // Pre-reserve mouse row width at creation for the longest pending prompt
        // + concise failures, so inline confirmation never resizes a tracking menu.
        let mouseReservedWidth = ShortcutManager.mouseConfirmationReservedWidth()
        let mouseRoot = NSMenuItem(title: "Mouse Button", action: nil, keyEquivalent: "")
        let mouseMenu = NSMenu()
        mouseMenu.autoenablesItems = false
        for (title, button) in [("Middle Click", MouseButton.middle), ("Side Button 4", MouseButton.button3), ("Side Button 5", MouseButton.button4)] {
            let entry = SettingsMenuItem(title: title, target: target, action: selectMouse, reservedWidth: mouseReservedWidth)
            entry.target = target as? NSObject
            entry.representedObject = String(button.rawValue)
            if case .mouseButton(let b) = manager.configuration.trigger, b == button {
                entry.state = .on
            } else { entry.state = .off }
            entry.isEnabled = canEdit
            entry.synchronize()
            // Inline bounded confirmation renders in the same row (no popup).
            // Instance helper keeps factory and tracking refresh identical.
            if manager.pendingMouseButton == button {
                entry.showConfirmationPrompt(manager.mouseConfirmationRowText(for: button))
            } else if manager.mouseConfirmationErrorButton == button, let err = manager.mouseConfirmationError {
                entry.showConfirmationError(err, toolTip: manager.mouseConfirmationRowToolTip(for: button))
            }
            mouseMenu.addItem(entry)
        }
        mouseRoot.submenu = mouseMenu
        menu.addItem(mouseRoot)
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset to Default", action: resetDefault, keyEquivalent: "")
        reset.target = target as? NSObject
        reset.isEnabled = canEdit
        menu.addItem(reset)
        // Keep bounded status slots alive while native menu tracking updates them.
        let note = NSMenuItem(title: "Needs Accessibility access.", action: nil, keyEquivalent: "")
        note.identifier = permissionNoteID
        note.isEnabled = false
        menu.addItem(note)
        let open = NSMenuItem(title: "Open System Settings…", action: openSettings, keyEquivalent: "")
        open.identifier = settingsID
        open.target = target as? NSObject
        open.isEnabled = true
        menu.addItem(open)
        let error = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        error.identifier = errorID
        error.isEnabled = false
        menu.addItem(error)
        refreshStatus(in: menu, manager: manager)
        root.submenu = menu
        return root
    }
}
