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
    func menuDidClose(_ menu: NSMenu) { controller.discardPreviews() }
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
        // The item view, and so the menu window, is exactly the table's width: the table's content is that wide in every
        // state (ModelTable.width, from its column constants; TableWidthTests), so no column is ever clipped.
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(controller))
        menu.minimumWidth = ModelTable.width
        item.view = view; menu.addItem(item)
        // Unoffered legacy tiers cannot be selected, but their retained files remain manageable.
        let legacy = controller.catalog.families.flatMap { family in
            family.variants.keys.sorted().filter { !controller.options(family).contains($0) && controller.localPath(family, $0) != nil }
                .map { (family, $0) }
        }
        if !legacy.isEmpty {
            menu.addItem(.separator())
            for (family, precision) in legacy {
                let entry = NSMenuItem(title: "Delete " + family.name + " " + legacyQuantization(precision) + "…", action: #selector(deleteLegacy(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = [family.id, precision]
                menu.addItem(entry)
            }
        }
        root.submenu = menu
        return root
    }
    @objc private func deleteLegacy(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String], value.count == 2, let family = controller.catalog.family(value[0]) else { return }
        confirmDeletion(family, precision: value[1])
    }
    /// Deletes the selected precision's weights of a family, after confirmation.
    private func confirmDeletion(_ family: ModelFamily, precision: String? = nil) {
        let precision = precision ?? controller.selected(family)
        tableMenu?.cancelTracking()
        DispatchQueue.main.async { [self] in
            let plan: ModelDeletionPlan
            do { plan = try controller.deletionPlan(family, precision: precision) } catch {
                let blocked = NSAlert(); blocked.messageText = "Model cannot be deleted here"
                blocked.informativeText = (error as? APIError)?.message ?? error.localizedDescription
                blocked.addButton(withTitle: "OK")
                _ = presentDeletionConfirmation(blocked)
                return
            }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = plan.title; alert.informativeText = plan.body
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Move to Trash")
            guard presentDeletionConfirmation(alert) == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                do { try await controller.performDeletion(family, plan: plan) } catch {
                    let failure = NSAlert(); failure.messageText = "Model was not deleted"
                    failure.informativeText = (error as? APIError)?.message ?? error.localizedDescription
                    _ = presentDeletionConfirmation(failure)
                }
            }
        }
    }
}
