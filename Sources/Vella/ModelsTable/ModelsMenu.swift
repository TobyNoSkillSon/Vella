import AppKit
import SwiftUI
import VellaCore

// The Models table: layout, colours and footer.

/// A transparent, vibrant host lets NSMenu supply its own material and shadow.
final class MenuTableHostingView: NSHostingView<ModelTable> {
    override var allowsVibrancy: Bool { true }
}

/// The Models… item: one submenu holding the table, Dictation and Streaming as sections.
@MainActor final class ModelsMenu: NSObject, NSMenuDelegate {
    let controller: ModelsController
    private weak var tableMenu: NSMenu?
    var presentDeletionConfirmation: (NSAlert) -> NSApplication.ModalResponse = {
        NSApp.activate(ignoringOtherApps: true)
        return $0.runModal()
    }
    /// The download confirmation popup (tests answer it without a window).
    var presentDownload: (DownloadPrompt) -> Bool = { DownloadGate.presentAlert($0) }
    init(controller: ModelsController? = nil) {
        self.controller = controller ?? ModelsController(); super.init()
        // Every download from the table asks first, like Delete: close the menu, activate, then the popup.
        self.controller.confirmDownload = { [weak self] prompt, answer in
            guard let self else { return answer(nil) }
            self.tableMenu?.cancelTracking()
            DispatchQueue.main.async { answer(DownloadGate.ask(prompt, present: self.presentDownload)) }
        }
    }
    /// Closing the menu discards previews: a row returns to its loaded (or last loaded) precision.
    func menuDidClose(_ menu: NSMenu) { controller.discardPreviews(); controller.filterOpen = false }
    func modelItem() -> NSMenuItem {
        if !controller.previewing { controller.reload() }
        let root = NSMenuItem(title: "Models…", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; tableMenu = menu
        let item = NSMenuItem()
        let view = MenuTableHostingView(rootView: ModelTable(controller: controller, requestDelete: { [weak self] family in self?.confirmDeletion(family) }))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(controller))
        // The filter strip and filtered rows change the table's height while the menu is open: the item view takes the
        // new height (NSMenu lays out its items again when an item view's frame changes), then redraws in tracking mode.
        controller.onLayoutChange = { [weak view, controller] in
            guard let view else { return }
            view.setFrameSize(NSSize(width: ModelTable.width, height: ModelTable.height(controller)))
            HostRefresh.after(view)
        }
        item.view = view; menu.addItem(item); root.submenu = menu
        return root
    }
    /// Deletes the selected precision's weights of a family, after confirmation.
    private func confirmDeletion(_ family: ModelFamily) {
        let precision = controller.selected(family)
        guard let variant = family.variants[precision] else { return }
        let library = controller.library(family.mode)
        guard let path = library.modelFilePath(variant.id) else { return }
        let wasInstalled = library.installed[variant.id] != nil
        let name = "\(family.name) \(legacyQuantization(precision))"
        tableMenu?.cancelTracking()
        DispatchQueue.main.async { [self] in
            if let reason = library.deletionBlockReason(variant.id) {
                let blocked = NSAlert(); blocked.messageText = "Model cannot be deleted here"
                blocked.informativeText = reason
                blocked.addButton(withTitle: "OK")
                _ = presentDeletionConfirmation(blocked)
                return
            }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = wasInstalled ? "Delete \(name)?" : "Delete unfinished \(name) download?"
            alert.informativeText =
                "Moves its downloaded weights to the Trash. If it is loaded it is unloaded first. You can download it again later. Recordings and transcripts are kept."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Move to Trash")
            guard presentDeletionConfirmation(alert) == .alertSecondButtonReturn else { return }
            // Deleting a source also removes the manifests of precisions made from it (they hold no weights of their own).
            let delete: @MainActor () -> Bool = {
                guard library.deleteModel(variant.id, expectedPath: path, expectedInstalled: wasInstalled) else { return false }
                removeDerivedModels(sourcePath: path, modelsDirectory: library.modelsDirectory)
                return true
            }
            let reportFailure: @MainActor () -> Void = { [self] in
                let failure = NSAlert(); failure.messageText = "Model was not deleted"
                failure.informativeText = library.downloadError ?? "Reopen Models and try again."
                _ = presentDeletionConfirmation(failure)
            }
            // With a runtime: unload (awaited) → delete → launch-set clean-up, as one ordered operation.
            guard let actions = controller.actions else { if !delete() { reportFailure() }; return }
            Task { @MainActor in
                if !(await actions.delete(family: family, path: path, delete: delete)) { reportFailure() }
            }
        }
    }
}
