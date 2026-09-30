import Foundation

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
