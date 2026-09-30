import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

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
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        // Transactional allocation: build the replacement BEFORE touching live
        // state, so failure keeps the old registration/handlers.
        let newTap: CFMachPort?
        if let override = tapCreateOverride {
            newTap = override(mask)
        } else {
            let context = Unmanaged.passUnretained(self).toOpaque()
            newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, data in
                    guard let data else { return Unmanaged.passUnretained(event) }
                    let registrar = Unmanaged<EventTapShortcutRegistrar>.fromOpaque(data).takeUnretainedValue()
                    // Consume ONLY the configured middle/side click (nil) so it never also
                    // navigates; every other event passes through untouched.
                    if registrar.processTapEvent(type: type, event: event) { return nil }
                    return Unmanaged.passUnretained(event)
                }, userInfo: context)
        }
        guard let newTap else {
            throw VellaError.message(
                "Could not observe input. If macOS asks for Input Monitoring, approve Vella there; otherwise enable Accessibility. Key chords work without this.")
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            throw VellaError.message(
                "Could not observe input. If macOS asks for Input Monitoring, approve Vella there; otherwise enable Accessibility. Key chords work without this.")
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
                case .modifierOnly(let key, let side) = self.registered?.trigger
            else { return }
            let behavior = self.registered?.behavior ?? .toggle
            let down = self.soloState.pendingSince
            let out = ModifierSoloReducer.step(state: &self.soloState, event: .holdTimeout(time: self.now()), targetKey: key, targetSide: side, behavior: behavior)
            guard gen == self.generation else { return } // rebind/unregister wins
            if out == .press {
                if let confirmed = self.confirmedPressHandler, let down { confirmed(down) } else { self.onPress?() }
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
                    let out = ModifierSoloReducer.step(
                        state: &s, event: .targetDown(key: key, side: side, time: t, sole: sole), targetKey: key, targetSide: side, behavior: config.behavior)
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
        return others.isDisjoint(with: extra)
    }
}
