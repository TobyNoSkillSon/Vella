import Foundation

// MARK: - Activation customization core (pure Foundation, no AppKit/Carbon/taps)
// Public contract for spark implementation + vella-qa-spark adversarial tests.

public enum ShortcutBehavior: String, Codable, CaseIterable, Equatable {
    case toggle
    case holdToTalk
    case tapOrHold
    public var title: String {
        switch self {
        case .toggle: return "Toggle"
        case .holdToTalk: return "Hold to Talk"
        case .tapOrHold: return "Tap or Hold"
        }
    }
    /// Tap (< threshold) keeps recording; hold (>= threshold) finishes on release.
    public static var tapHoldThreshold: TimeInterval { 0.3 }
}

public enum ModifierSide: String, Codable, Equatable {
    case left, right
    public var title: String { self == .left ? "Left" : "Right" }
}

public enum ModifierKey: String, Codable, Equatable {
    case control, option, command, shift, function
    public var title: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .shift: return "⇧"
        case .function: return "Fn"
        }
    }
    public var name: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .shift: return "Shift"
        case .function: return "Fn"
        }
    }
}

public enum MouseButton: Int, Codable, Equatable {
    case middle = 2
    case button3 = 3
    case button4 = 4
    public var title: String {
        switch self {
        case .middle: return "Middle Click"
        case .button3: return "Side Button 4"
        case .button4: return "Side Button 5"
        }
    }
}

public enum ShortcutTrigger: Equatable {
    case keyChord(keyCode: UInt32, modifiers: UInt32)
    case modifierOnly(key: ModifierKey, side: ModifierSide)
    case mouseButton(button: MouseButton)

    public var requiresEventTap: Bool {
        switch self {
        case .keyChord: return false
        case .modifierOnly, .mouseButton: return true
        }
    }
    public var isKeyChord: Bool {
        if case .keyChord = self { return true }
        return false
    }
}

extension ShortcutTrigger: Codable {
    private enum Kind: String, Codable { case keyChord, modifierOnly, mouseButton }
    private enum Keys: String, CodingKey { case kind, keyCode, modifiers, key, side, button }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .keyChord
        switch kind {
        case .keyChord:
            let code = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 45
            let mods = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? ShortcutConfiguration.defaultModifiers
            self = .keyChord(keyCode: code, modifiers: mods)
        case .modifierOnly:
            // Explicit modifierOnly must name both key and side; missing fields throw
            // (no silent Left Control) so corrupt partial objects retain previous config.
            let key = try c.decode(ModifierKey.self, forKey: .key)
            let side = try c.decode(ModifierSide.self, forKey: .side)
            self = .modifierOnly(key: key, side: side)
        case .mouseButton:
            // Explicit mouse must name a supported button; missing/unsupported values
            // throw (no silent middle remap) so corrupt prefs retain previous config.
            let raw = try c.decode(Int.self, forKey: .button)
            guard let button = MouseButton(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .button, in: c, debugDescription: "Unsupported mouse button \(raw).")
            }
            self = .mouseButton(button: button)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .keyChord(let code, let mods):
            try c.encode(Kind.keyChord, forKey: .kind)
            try c.encode(code, forKey: .keyCode)
            try c.encode(mods, forKey: .modifiers)
        case .modifierOnly(let key, let side):
            try c.encode(Kind.modifierOnly, forKey: .kind)
            try c.encode(key, forKey: .key)
            try c.encode(side, forKey: .side)
        case .mouseButton(let button):
            try c.encode(Kind.mouseButton, forKey: .kind)
            try c.encode(button.rawValue, forKey: .button)
        }
    }
}

public struct ShortcutConfiguration: Equatable, Codable {
    public var trigger: ShortcutTrigger
    public var behavior: ShortcutBehavior
    public init(trigger: ShortcutTrigger, behavior: ShortcutBehavior) {
        self.trigger = trigger
        self.behavior = behavior
    }
    // Carbon modifier bits (no Carbon import in Core).
    public static var cmdFlag: UInt32 { 256 }
    public static var shiftFlag: UInt32 { 512 }
    public static var optionFlag: UInt32 { 2048 }
    public static var controlFlag: UInt32 { 4096 }
    public static var defaultModifiers: UInt32 { 4096 | 256 } // controlKey | cmdKey = 4352
    public static var defaultKeyCode: UInt32 { 45 } // kVK_ANSI_N
    public static var `default`: ShortcutConfiguration {
        ShortcutConfiguration(trigger: .keyChord(keyCode: defaultKeyCode, modifiers: defaultModifiers), behavior: .toggle)
    }
    private enum Keys: String, CodingKey { case trigger, behavior }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        trigger = try c.decodeIfPresent(ShortcutTrigger.self, forKey: .trigger) ?? ShortcutConfiguration.default.trigger
        behavior = try c.decodeIfPresent(ShortcutBehavior.self, forKey: .behavior) ?? .toggle
    }
}

// MARK: Validation

public enum ShortcutValidation {
    /// Modifier keyCodes that must use modifier-only, not key chords.
    static var modifierKeyCodes: Set<UInt32> { [54, 55, 56, 58, 59, 60, 61, 62, 63] }
    /// Function keys safe with Shift alone (Shift+F-keys never produce typing).
    /// Covers F1-F20 using Apple key codes (F13-F20: 105,107,113,106,64,79,80,90).
    static var shiftAloneFunctionKeys: Set<UInt32> { [64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122] }
    public static var functionKeyReliabilityNote: String {
        "Fn reliability varies by keyboard; prefer another binding if Fn does not fire."
    }
    public static func validate(_ config: ShortcutConfiguration) -> String? {
        switch config.trigger {
        case .keyChord(let code, let mods):
            return validateKeyChord(keyCode: code, modifiers: mods)
        case .modifierOnly(let key, _):
            if key == .function { return nil } // valid, caller shows reliability note
            return nil
        case .mouseButton:
            return nil // type prevents primary/secondary
        }
    }
    public static func validateKeyChord(keyCode: UInt32, modifiers: UInt32) -> String? {
        // Carbon silently ignores unknown/Fn-only bits, which would degrade a chord
        // into a bare printable hotkey hijacking typing. Accept Carbon bits only.
        let allowed: UInt32 = ShortcutConfiguration.cmdFlag | ShortcutConfiguration.shiftFlag
            | ShortcutConfiguration.optionFlag | ShortcutConfiguration.controlFlag
        if modifiers == 0 {
            return "Add at least one modifier (⌃, ⌥, ⌘, or ⇧) to avoid accidental activation."
        }
        if modifiers & ~allowed != 0 {
            return "That modifier combination is not supported for global shortcuts. Use ⌃, ⌥, ⇧, or ⌘."
        }
        // Shift alone with a typing key would fire on ordinary typing (e.g. capital
        // letters). Require ⌃, ⌥, or ⌘ alongside Shift for printable keys.
        if modifiers == ShortcutConfiguration.shiftFlag, !shiftAloneFunctionKeys.contains(keyCode) {
            return "Shift alone cannot activate on a typing key. Add ⌃, ⌥, or ⌘."
        }
        if keyCode > 127 {
            return "That key code is not supported. Choose a letter, number, or function key with modifiers."
        }
        if modifierKeyCodes.contains(keyCode) {
            return "That is a modifier key. Use a Modifier-only binding instead."
        }
        if keyCode == 53 { return "Escape is reserved." }
        if keyCode == 57 { return "Caps Lock cannot be a shortcut." }
        let hasCmd = (modifiers & ShortcutConfiguration.cmdFlag) != 0
        let hasCtrl = (modifiers & ShortcutConfiguration.controlFlag) != 0
        // Reserved system/app chords.
        if keyCode == 49, hasCmd { return "⌘Space is reserved for Spotlight." }
        if keyCode == 48, hasCmd || hasCtrl { return "That Tab combination is reserved by macOS." }
        if hasCmd {
            switch keyCode {
            case 12: // Q
                if hasCtrl { return "⌃⌘Q is reserved for Lock Screen." }
                return "⌘Q is reserved for Quit."
            case 9: // V: plain Cmd+V is Vella's own Dictation paste; never intercept it.
                if !hasCtrl { return "⌘V is reserved for paste." }
            case 13: return "⌘W is reserved for closing windows." // W
            case 46: return "⌘M is reserved for minimizing." // M
            case 4: return "⌘H is reserved for hiding." // H
            case 43: return "That comma combination is reserved for Settings." // ,
            default: break
            }
        }
        // Allow everything else with modifiers (safe chord).
        return nil
    }
}

// MARK: Labels

public enum ShortcutLabels {
    public static func display(_ config: ShortcutConfiguration) -> String {
        "\(triggerDisplay(config.trigger)) · \(config.behavior.title)"
    }
    public static func triggerDisplay(_ trigger: ShortcutTrigger) -> String {
        switch trigger {
        case .keyChord(let code, let mods):
            return keyChordDisplay(keyCode: code, modifiers: mods)
        case .modifierOnly(let key, let side):
            if key == .function { return "Fn" }
            return "\(side.title) \(key.title)"
        case .mouseButton(let button):
            return button.title
        }
    }
    public static func keyChordDisplay(keyCode: UInt32, modifiers: UInt32) -> String {
        var mods = ""
        if (modifiers & ShortcutConfiguration.controlFlag) != 0 { mods += "⌃" }
        if (modifiers & ShortcutConfiguration.optionFlag) != 0 { mods += "⌥" }
        if (modifiers & ShortcutConfiguration.shiftFlag) != 0 { mods += "⇧" }
        if (modifiers & ShortcutConfiguration.cmdFlag) != 0 { mods += "⌘" }
        // Fn flag used by NSEvent (0x800000) when captured; show if present.
        if (modifiers & 0x800000) != 0 { mods += "Fn" }
        return mods + keyName(keyCode: keyCode)
    }
    public static func keyName(keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 53: return "Esc"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: Store (transactional persist/rollback)

public final class ShortcutStore {
    public private(set) var configuration: ShortcutConfiguration
    public private(set) var lastError: String?
    private let fileURL: URL?
    public init(initial: ShortcutConfiguration = .default, fileURL: URL? = nil) {
        self.configuration = initial
        self.fileURL = fileURL
    }
    public func load() {
        guard let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(ShortcutConfiguration.self, from: data)
            if let err = ShortcutValidation.validate(decoded) {
                lastError = err
                return
            }
            configuration = decoded
            lastError = nil
        } catch {
            lastError = "Saved shortcut could not be read; keeping \(ShortcutLabels.display(configuration))."
        }
    }
    @discardableResult
    public func save(_ config: ShortcutConfiguration) -> Bool {
        if let err = ShortcutValidation.validate(config) {
            lastError = err
            return false
        }
        let previous = configuration
        do {
            let data = try JSONEncoder().encode(config)
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                // Verify round-trip before committing in-memory state.
                let check = try JSONDecoder().decode(ShortcutConfiguration.self, from: Data(contentsOf: fileURL))
                guard check == config else { throw NSError(domain: "VellaShortcut", code: -1) }
            }
            configuration = config
            lastError = nil
            return true
        } catch {
            configuration = previous // rollback in-memory; disk keeps previous atomic file
            lastError = "Could not save shortcut; kept \(ShortcutLabels.display(previous)). \(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    public func resetToDefault() -> ShortcutConfiguration {
        _ = save(.default)
        return configuration
    }
}

// MARK: - Activation state machine

/// Testable solo-modifier arbitration.
/// The tap observes flagsChanged AND nonmodifier keyDown: a target-modifier down
/// becomes pending only; any other keyDown or non-target modifier cancels it.
/// A hold timeout while still sole-held yields press (Hold); a quick solo
/// release yields tap (Toggle/TapOrHold-short). Covers both left/right sides.
public enum SoloInputEvent: Equatable {
    case targetDown(key: ModifierKey, side: ModifierSide, time: TimeInterval, sole: Bool)
    case targetUp(key: ModifierKey, side: ModifierSide, time: TimeInterval)
    case otherKeyDown(time: TimeInterval)
    case otherModifierDown(time: TimeInterval)
    case holdTimeout(time: TimeInterval)
    case reset
}
public enum SoloOutput: Equatable {
    case none
    case pending
    case press
    case tapRelease // quick solo release before hold timeout
    case holdRelease // release after press fired
    case cancelled
}
public struct SoloModifierState: Equatable {
    public var pendingSince: TimeInterval?
    public var pressed: Bool
    public init(pendingSince: TimeInterval? = nil, pressed: Bool = false) {
        self.pendingSince = pendingSince; self.pressed = pressed
    }
}
public enum ModifierSoloReducer {
    public static var holdDelay: TimeInterval { 0.3 }
    public static func step(state: inout SoloModifierState, event: SoloInputEvent, targetKey: ModifierKey, targetSide: ModifierSide, behavior: ShortcutBehavior) -> SoloOutput {
        switch event {
        case .targetDown(let key, let side, let time, let sole):
            guard key == targetKey, side == targetSide, sole else { return .none }
            guard state.pendingSince == nil, !state.pressed else { return .none }
            state.pendingSince = time; state.pressed = false
            return .pending
        case .otherKeyDown, .otherModifierDown:
            if state.pressed { return .none }
            if state.pendingSince != nil {
                state.pendingSince = nil
                return .cancelled
            }
            return .none
        case .holdTimeout:
            guard state.pendingSince != nil, !state.pressed else { return .none }
            if behavior == .toggle { return .none }
            state.pressed = true
            return .press
        case .targetUp(let key, let side, _):
            guard key == targetKey, side == targetSide else { return .none }
            if state.pressed {
                state.pendingSince = nil; state.pressed = false
                return .holdRelease
            }
            if state.pendingSince != nil {
                state.pendingSince = nil
                return .tapRelease
            }
            return .none
        case .reset:
            let had = state.pendingSince != nil || state.pressed
            state.pendingSince = nil; state.pressed = false
            return had ? .cancelled : .none
        }
    }
}

public final class ShortcutEngine {
    public struct Sinks {
        public var start: () -> Void
        public var finish: () -> Void
        public var cancel: () -> Void
        public var isRecording: () -> Bool
        public var isBusy: () -> Bool
        public var currentOperation: () -> UInt64
        public init(start: @escaping () -> Void, finish: @escaping () -> Void, cancel: @escaping () -> Void,
                    isRecording: @escaping () -> Bool, isBusy: @escaping () -> Bool,
                    currentOperation: @escaping () -> UInt64 = { 0 }) {
            self.start = start; self.finish = finish; self.cancel = cancel
            self.isRecording = isRecording; self.isBusy = isBusy
            self.currentOperation = currentOperation
        }
    }
    public private(set) var configuration: ShortcutConfiguration
    public private(set) var activePressID: UInt64?
    public private(set) var activeCaptureID: UInt64?
    public private(set) var activeOperation: UInt64?
    public private(set) var pressStartTime: TimeInterval?
    public private(set) var nextPressID: UInt64 = 1
    public private(set) var captureEpoch: UInt64 = 0
    private var tapKept = false
    private let sinks: Sinks
    private let now: () -> TimeInterval
    public init(configuration: ShortcutConfiguration, sinks: Sinks, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration
        self.sinks = sinks
        self.now = now
    }
    public func updateConfiguration(_ c: ShortcutConfiguration) {
        configuration = c
        activePressID = nil
        activeCaptureID = nil
        activeOperation = nil
        pressStartTime = nil
        tapKept = false
    }
    public var canChangeSettings: Bool { !(sinks.isRecording() || sinks.isBusy()) }
    /// Read-only state for activation policy (e.g. stopping never needs permission).
    public var isRecordingActive: Bool { sinks.isRecording() }
    public var isBusyActive: Bool { sinks.isBusy() }

    @discardableResult
    public func press(isRepeat: Bool = false, downTime: TimeInterval? = nil) -> Bool {
        if isRepeat { return false }
        // Physical down time threads through delayed solo confirmation so TapOrHold
        // classifies the total hold (down@0, guard@0.3, up@0.35 => HOLD finishes).
        let down = downTime ?? now()
        let recording = sinks.isRecording()
        let busy = sinks.isBusy()
        switch configuration.behavior {
        case .toggle:
            if activePressID != nil { return false } // duplicate press while held
            if recording {
                let id = nextPressID; nextPressID += 1
                activePressID = id; pressStartTime = down
                // No capture ownership for toggle-off; release just clears.
                activeCaptureID = nil; activeOperation = nil; tapKept = false
                sinks.finish()
                return true
            }
            if busy { return false }
            let id = nextPressID; nextPressID += 1
            activePressID = id; pressStartTime = down
            captureEpoch += 1; activeCaptureID = captureEpoch; tapKept = false
            sinks.start()
            activeOperation = sinks.currentOperation()
            return true
        case .holdToTalk, .tapOrHold:
            // Tap-off arming: previous tap kept capture alive (press cleared, capture kept).
            if activePressID == nil, let _ = activeCaptureID, tapKept, recording || busy {
                let id = nextPressID; nextPressID += 1
                activePressID = id; pressStartTime = down
                return true // armed; release will finish
            }
            if activePressID != nil { return false }
            // Stale kept capture with no live recording: drop it and start fresh if idle.
            if activeCaptureID != nil, !recording, !busy {
                activeCaptureID = nil; activeOperation = nil; tapKept = false
            } else if activeCaptureID != nil {
                return false // kept capture still live but unexpected state; duplicate guard
            }
            if recording || busy { return false } // foreign capture: never steal; release must not finish it
            let id = nextPressID; nextPressID += 1
            activePressID = id; pressStartTime = down
            captureEpoch += 1; activeCaptureID = captureEpoch; tapKept = false
            sinks.start()
            activeOperation = sinks.currentOperation()
            return true
        }
    }

    @discardableResult
    public func release() -> Bool {
        guard let id = activePressID else {
            // Tap-kept capture has no active press; release without press is stale.
            return false
        }
        return releaseForPressID(id)
    }

    @discardableResult
    public func releaseForPressID(_ id: UInt64) -> Bool {
        guard let active = activePressID, active == id else { return false }
        // Toggle releases never act.
        if configuration.behavior == .toggle {
            activePressID = nil; activeCaptureID = nil; activeOperation = nil; pressStartTime = nil; tapKept = false
            return false
        }
        let start = pressStartTime ?? now()
        let duration = now() - start
        let owned = activeCaptureID
        let recording = sinks.isRecording()
        let busy = sinks.isBusy()
        // Ownership binds to the actual Model generation observed right after start.
        // A manual menu Finish + new Start changes generation; the stale release must not
        // finish or cancel the new unrelated capture.
        if let ownedOp = activeOperation, ownedOp != sinks.currentOperation() {
            activePressID = nil; activeCaptureID = nil; activeOperation = nil; pressStartTime = nil; tapKept = false
            return false
        }
        // Late release after foreign finish or completed capture: suppress.
        guard owned != nil else {
            activePressID = nil; activeOperation = nil; pressStartTime = nil
            return false
        }
        if !recording && !busy {
            activePressID = nil; activeCaptureID = nil; activeOperation = nil; pressStartTime = nil; tapKept = false
            return false
        }
        // Tap-or-hold short tap keeps recording (first tap only). Boundary (0.300s) belongs to hold.
        // Use epsilon so binary floating-point 0.300 still finishes.
        if configuration.behavior == .tapOrHold, !tapKept, duration + 1e-6 < ShortcutBehavior.tapHoldThreshold {
            activePressID = nil; pressStartTime = nil
            tapKept = true // keep activeCaptureID for tap-off cycle
            return false
        }
        // Hold finish (or tap-off finish, or busy abort).
        activePressID = nil; pressStartTime = nil; activeCaptureID = nil; activeOperation = nil; tapKept = false
        captureEpoch += 1
        if recording {
            sinks.finish()
        } else {
            // Preparing/transcribing: abort without runaway.
            sinks.cancel()
        }
        return true
    }

    public func handleInterruption() {
        guard activePressID != nil || activeCaptureID != nil else { return }
        let owned = activeCaptureID != nil
        let ownedOp = activeOperation
        activePressID = nil; pressStartTime = nil; tapKept = false
        // Only cancel the capture this press actually started. A generation change means
        // a manual Finish/Start already replaced it; never cancel unrelated work and never
        // insert automatically on interruption (sinks.cancel preserves audio, inserts nothing).
        if owned, let ownedOp, ownedOp == sinks.currentOperation(), sinks.isRecording() || sinks.isBusy() {
            sinks.cancel()
            captureEpoch += 1
        }
        activeCaptureID = nil; activeOperation = nil
    }
    public func handleTapDisabled() { handleInterruption() }
}
