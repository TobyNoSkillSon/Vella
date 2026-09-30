import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

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
