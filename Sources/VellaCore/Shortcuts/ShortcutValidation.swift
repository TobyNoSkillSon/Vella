import Foundation

// MARK: Validation

public enum ShortcutValidation {
    /// Modifier keyCodes that must use modifier-only, not key chords.
    static var modifierKeyCodes: Set<UInt32> { [54, 55, 56, 58, 59, 60, 61, 62, 63] }
    /// Function keys safe with Shift alone (Shift+F-keys never produce typing).
    /// Covers F1-F20 using Apple key codes (F13-F20: 105,107,113,106,64,79,80,90).
    static var shiftAloneFunctionKeys: Set<UInt32> { [64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122] }
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
        let allowed: UInt32 =
            ShortcutConfiguration.cmdFlag | ShortcutConfiguration.shiftFlag
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
