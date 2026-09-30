import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

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
