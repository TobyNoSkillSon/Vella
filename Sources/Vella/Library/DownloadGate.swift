import AppKit
import VellaCore

/// Explicit consent for one download: Download in the popup, or authenticated Get with --yes.
/// Only `DownloadGate.ask` makes one, and `ModelLibrary.download` requires it.
struct DownloadApproval: Equatable {
    let variantID: String
    fileprivate init(variantID: String) { self.variantID = variantID }
}

@MainActor enum DownloadGate {
    /// Shows the prompt; an approval only when the answer is Download. A refusal (not enough disk space) is shown and
    /// never approves, whatever the presenter answers.
    static func ask(_ prompt: DownloadPrompt, present: (DownloadPrompt) -> Bool) -> DownloadApproval? {
        let answer = present(prompt)
        return answer && !prompt.refusal ? DownloadApproval(variantID: prompt.variantID) : nil
    }
    /// Cancel | Download in the system layout; Return does nothing, Escape cancels. A refusal has OK only.
    static func alert(_ prompt: DownloadPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.body
        if prompt.refusal { alert.addButton(withTitle: "OK") } else { alert.addConfirmation("Download", returnConfirms: false) }
        return alert
    }
    /// The real presenter: activate (a menu-bar app is not frontmost), then ask modally.
    static func presentAlert(_ prompt: DownloadPrompt) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return alert(prompt).runModal() == .alertFirstButtonReturn && !prompt.refusal
    }
}
