import AppKit
import SwiftUI
import VellaCore

/// A transparent, vibrant host lets NSMenu supply its own material and shadow.
final class MenuTableHostingView: NSHostingView<ModelTable> {
    override var allowsVibrancy: Bool { true }
}

/// A single shallow menu containing the compact comparison table.
@MainActor final class ModelsMenu: NSObject {
    let library: ModelLibrary
    private weak var tableMenu: NSMenu?
    var presentDeletionConfirmation: (NSAlert) -> NSApplication.ModalResponse = {
        NSApp.activate(ignoringOtherApps: true)
        return $0.runModal()
    }
    init(library: ModelLibrary? = nil) { self.library = library ?? ModelLibrary(); super.init() }
    func modelItem() -> NSMenuItem {
        library.reload()
        let root = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        let menu = NSMenu(); menu.autoenablesItems = false; tableMenu = menu
        let item = NSMenuItem()
        let view = MenuTableHostingView(rootView: ModelTable(library: library, dismiss: { [weak self] in self?.tableMenu?.cancelTracking() }, requestDelete: { [weak self] id in self?.confirmDeletion(id) }))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.frame = NSRect(x: 0, y: 0, width: 534, height: 272)
        item.view = view; menu.addItem(item); root.submenu = menu
        return root
    }
    private func confirmDeletion(_ id: String) {
        guard let path = library.modelFilePath(id) else { return }
        let wasInstalled = library.installed[id] != nil
        let name = library.models.first(where: { $0.id == id }).map { "\($0.name) \($0.quantization)" } ?? id
        tableMenu?.cancelTracking()
        DispatchQueue.main.async { [self] in
            if let reason = library.deletionBlockReason(id) {
                let blocked = NSAlert(); blocked.messageText = "Model cannot be deleted here"
                blocked.informativeText = reason
                blocked.addButton(withTitle: "OK")
                _ = presentDeletionConfirmation(blocked)
                return
            }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = wasInstalled ? "Delete \(name)?" : "Delete unfinished \(name) download?"
            alert.informativeText = "Move these local files to Trash. Empty Trash to reclaim disk space. You can download them again later. Recordings, transcripts and reference scores are kept."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Move to Trash")
            guard presentDeletionConfirmation(alert) == .alertSecondButtonReturn else { return }
            if !library.deleteModel(id, expectedPath: path, expectedInstalled: wasInstalled) {
                let failure = NSAlert(); failure.messageText = "Model was not deleted"
                failure.informativeText = library.downloadError ?? "Reopen Models and try again."
                _ = presentDeletionConfirmation(failure)
            }
        }
    }

}

struct ModelTable: View {
    @ObservedObject var library: ModelLibrary
    var dismiss: () -> Void = {}
    var requestDelete: (String) -> Void = { _ in }
    @State private var sortColumn: ModelSortColumn = .formattedError
    @State private var ascending = true
    @State private var copied = false
    @State private var copyGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = Color.primary
    private var results: [String: BenchmarkResult] { library.references }
    private var rows: [ModelRecommendation] { sortedRecommendations(library.displayedModels, results: results, column: sortColumn, ascending: ascending) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                heading("Model", .name, 122)
                heading("Q", .quantization, 32)
                heading("Words", .errorRate, 54)
                heading("Text", .formattedError, 54)
                heading("Speed", .speed, 56)
                heading("RAM", .memory, 56)
                Text("").frame(width: 80)
            }.padding(.horizontal, 6)
            Divider().opacity(0.35)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(rows) { model in
                        let result = results[model.id]
                        let installed = library.installed[model.id]
                        let localPath = library.modelFilePath(model.id)
                        let active = installed?.path == library.activeModelPath
                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: active ? "checkmark" : "circle").font(.system(size: 10)).foregroundStyle(active ? accent : .secondary)
                                Text(model.repository.isEmpty ? model.name.replacingOccurrences(of: " large-v3", with: "") + " (local)" : model.name.replacingOccurrences(of: " ASR ·", with: "")).font(.system(size: 11)).lineLimit(1)
                            }.frame(width: 122, alignment: .leading)
                            Text(model.quantization.replacingOccurrences(of: "-bit", with: "b")).frame(width: 32, alignment: .leading)
                            Text(result.map { String(format: "%.2f%%", $0.wordErrorRate * 100) } ?? "—").frame(width: 54, alignment: .trailing)
                            Text(result?.formatting.map { String(format: "%.2f%%", $0.formattedCharacterErrorRate * 100) } ?? "—").frame(width: 54, alignment: .trailing)
                                .help(result.map { library.formattingDescription($0) } ?? "Not measured")
                            Text(result.map { String(format: "%.1f×", $0.realtimeFactor) } ?? "—").frame(width: 56, alignment: .trailing)
                            Text(result?.runtimePeakMLXBytes.map { String(format: "%.2f GB", Double($0) / 1_000_000_000) } ?? "—").frame(width: 56, alignment: .trailing)
                            Button(library.busy && library.downloadingID == model.id ? library.progress.map { "\(Int($0 * 100))%" } ?? "…" : active ? "In use" : installed == nil ? (localPath == nil ? "Install" : "Resume") : "Use") {
                                library.selectedID = model.id
                                if installed == nil { library.download() }
                                else if library.useSelected() { dismiss() }
                            }.buttonStyle(.bordered).controlSize(.small).frame(width: 52)
                                .disabled(active || library.busy || !library.mayChangeModel() || (installed == nil && model.repository.isEmpty))
                                .help(installed == nil ? "Download \(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)) from Hugging Face: \(model.repository). License: \(model.license). Selecting for dictation is separate." : "Use this model for your next dictation")
                            Button { requestDelete(model.id) } label: {
                                Image(systemName: "trash").frame(width: 20)
                            }.buttonStyle(.plain)
                                .opacity(localPath == nil ? 0 : 1)
                                .disabled(localPath == nil)
                                .help(library.deletionBlockReason(model.id) ?? "Delete this model's local files (with confirmation)")
                                .accessibilityLabel("Delete \(model.name) \(model.quantization)")
                        }.font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6).frame(height: 32)
                            .background(active ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .background {
                                if library.busy && library.downloadingID == model.id {
                                    GeometryReader { geometry in
                                        if let value = library.progress {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.35))
                                                .frame(width: geometry.size.width * min(1, max(0, value)))
                                                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: value)
                                        }
                                    }.allowsHitTesting(false)
                                }
                            }
                            .foregroundStyle(active ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
                            .contentShape(Rectangle())
                            .help(result.map { "\(library.formattingDescription($0)). \($0.transcriptionSeconds.formatted(.number.precision(.fractionLength(2)))) seconds for \($0.audioSeconds.formatted(.number.precision(.fractionLength(1)))) seconds of audio." } ?? "Not measured. No score is borrowed from another quantization.")
                    }
                }
            }.frame(height: 180)
            Divider().opacity(0.35)
            HStack {
                if library.busy {
                    if library.progress == nil { ProgressView().controlSize(.mini) }
                    Text(library.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else if let error = library.downloadError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1).help(error)
                }
                if library.busy { Spacer(); Button("Cancel", action: library.cancel) }
                else {
                    Button {
                        guard library.copyAgentRequest() else { return }
                        copyGeneration += 1
                        let generation = copyGeneration
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            guard generation == copyGeneration else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = false }
                        }
                    } label: {
                        HStack {
                            Text("Want another model? Copy instructions for your agent.")
                            Spacer(minLength: 8)
                            Image(systemName: "doc.on.doc").accessibilityHidden(true)
                        }.padding(.horizontal, 8)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(library.agentRequest)
                        .accessibilityHint("Copies installation instructions to the clipboard. Nothing is sent automatically.")
                }
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 2)
            .frame(width: 534, height: 272)
            .background(Color.clear)
            .foregroundStyle(.primary)
            .overlay(alignment: .top) {
                if copied {
                    Text("Copied").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 3)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
    }
    private func heading(_ text: String, _ column: ModelSortColumn, _ width: CGFloat) -> some View {
        Button {
            if sortColumn == column { ascending.toggle() }
            else { sortColumn = column; ascending = column != .speed }
        } label: {
            Text(text).frame(width: width, alignment: .center)
                .overlay(alignment: .trailing) {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 9)
                        .opacity(sortColumn == column ? 1 : 0)
                        .allowsHitTesting(false)
                }
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(sortColumn == column ? accent : .secondary)
            .help(column == .formattedError ? "Character errors with capitalization and punctuation retained. Lower is better; reference-style agreement, not a universal quality score." : column == .memory ? "Observed peak MLX allocation during warmed-up transcription, in decimal GB. Excludes untracked Python/native memory; not total process or system RAM." : column == .errorRate ? "Word recognition errors; ignores case and punctuation. Lower is better." : text)
    }
}
