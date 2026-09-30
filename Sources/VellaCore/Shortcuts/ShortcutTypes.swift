import Foundation

// MARK: - Activation customization core (pure Foundation, no AppKit/Carbon/taps)
// Shared activation configuration, validation and deterministic input state machine.

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
