import AppKit

extension NSAlert {
    /// A two-button confirmation in the system's layout (macOS 26/27 NSAlert: the first button added is drawn on the
    /// right; a second button titled Cancel is drawn on the left and answers Escape). The action is added first and
    /// answers `.alertFirstButtonReturn`. `returnConfirms` false (downloads, deletions): Return does nothing, so only a
    /// click starts the action; Escape still cancels.
    func addConfirmation(_ action: String, returnConfirms: Bool) {
        addButton(withTitle: action)
        addButton(withTitle: "Cancel")
        if !returnConfirms { buttons[0].keyEquivalent = "" }
    }
}
