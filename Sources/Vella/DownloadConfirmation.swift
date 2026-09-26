import AppKit
import VellaCore

/// Proof that the user chose Download in the confirmation popup for one variant. Only `DownloadGate.ask` makes one
/// (the initializer is private to this file), and `ModelLibrary.download` requires it, so no path can start a model
/// download without the popup.
struct DownloadApproval: Equatable {
    let variantID: String
    fileprivate init(variantID: String) { self.variantID = variantID }
}

@MainActor enum DownloadGate {
    /// Shows the prompt; an approval only when the answer is Download.
    static func ask(_ prompt: DownloadPrompt, present: (DownloadPrompt) -> Bool) -> DownloadApproval? {
        present(prompt) ? DownloadApproval(variantID: prompt.variantID) : nil
    }
    /// Download / Cancel with Cancel the default button (Return and Escape both cancel).
    static func alert(_ prompt: DownloadPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.body
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Download")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert
    }
    /// The real presenter: activate (a menu-bar app is not frontmost), then ask modally.
    static func presentAlert(_ prompt: DownloadPrompt) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return alert(prompt).runModal() == .alertSecondButtonReturn
    }
}
