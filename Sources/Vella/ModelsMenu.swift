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
            alert.informativeText = "Moves its downloaded weights to the Trash. If it is loaded it is unloaded first. You can download it again later. Recordings and transcripts are kept."
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

enum TableSortColumn: CaseIterable {
    case name, wer, format, speed, energy, memory
    var metric: TableMetric? {
        switch self {
        case .name: return nil
        case .wer: return .wer
        case .format: return .format
        case .speed: return .speed
        case .energy: return .energy
        case .memory: return .memory
        }
    }
}

struct ModelTable: View {
    /// Column widths; `spacing` between columns, `rowPadding` inside a row on each side.
    enum W {
        static let model: CGFloat = 182, capabilities: CGFloat = 82, params: CGFloat = 52
        static let precision: CGFloat = TierControl.width + 4, path: CGFloat = max(ExactFastSwitch.width, ExactFastSwitch.showsWords ? 0 : 64)
        static let wer: CGFloat = 62, format: CGFloat = 62, speed: CGFloat = 78, energy: CGFloat = 64, memory: CGFloat = 72
        static let action: CGFloat = RowAction.width
        static let spacing: CGFloat = 6, rowPadding: CGFloat = 8
        static let columns: [CGFloat] = [model, capabilities, params, precision, path, wer, format, speed, energy, memory, action]
        static let row: CGFloat = columns.reduce(0, +) + CGFloat(columns.count - 1) * spacing + 2 * rowPadding
    }
    static let width: CGFloat = W.row + 8
    /// One line per model: the Optimized and Standard segment rows with air around them; beside them a 13 pt value
    /// over a 10.5 pt delta (or the name over its engine label). A cloud row has no controls and keeps a 38 pt line.
    static let rowHeight: CGFloat = TierControl.height + 6
    static let referenceRowHeight: CGFloat = 38
    static let rowGap: CGFloat = 2
    static let headerHeight: CGFloat = 26, stripHeight: CGFloat = 30, sectionHeight: CGFloat = 24, footerHeight: CGFloat = 28
    /// Every visible row fits without scrolling: paddings, heading, filter strip, dividers, section labels and footer.
    static func height(models: Int, references: Int, sections: Int, strip: Bool = false) -> CGFloat {
        12 + headerHeight + (strip ? stripHeight : 0) + 18 + CGFloat(sections) * sectionHeight
            + CGFloat(models) * (rowHeight + rowGap) + CGFloat(references) * (referenceRowHeight + rowGap) + footerHeight
    }
    @MainActor static func height(_ c: ModelsController) -> CGFloat {
        let references = RecognitionMode.allCases.reduce(0) { $0 + c.visibleReferences($1).count }
        return height(models: c.rowCount - references, references: references, sections: c.sectionCount,
                      strip: c.filterOpen && !c.filterableCapabilities.isEmpty)
    }

    static let valueFont = Font.system(size: 13).monospacedDigit()
    static let deltaFont = Font.system(size: 10.5).monospacedDigit()

    @ObservedObject var controller: ModelsController
    var requestDelete: (ModelFamily) -> Void = { _ in }
    @VellaState private var sortColumn: TableSortColumn = .wer
    @VellaState private var ascending = true
    @VellaState private var copied = false
    @VellaState private var copyGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Subtle green/red; lighter on the loaded (accent-filled) row so they stay legible.
    static func tone(_ t: DeltaTone, hot: Bool) -> Color {
        switch t {
        case .better: return hot ? Color(red: 0.62, green: 0.96, blue: 0.68) : Color(red: 0.42, green: 0.82, blue: 0.52)
        case .worse: return hot ? Color(red: 1.0, green: 0.74, blue: 0.70) : Color(red: 1.0, green: 0.52, blue: 0.48)
        case .neutral: return .secondary
        }
    }
    /// Loaded row: the selection blue at 60 %, so the row reads as loaded without competing with the numbers.
    static let hotRow = Color(nsColor: .selectedContentBackgroundColor).opacity(0.6)
    static let hotText = Color(nsColor: .selectedMenuItemTextColor)

    private var runtime: TableRuntime? { controller.runtime }

    /// Rows of a section in a stable order: each column sorts by the model's best value across its precisions, so
    /// changing a row's selected precision never moves it. Cloud reference rows sort with the models (by their
    /// estimated WER). The capabilities filter hides rows without its capabilities.
    @MainActor static func rows(_ controller: ModelsController, _ mode: RecognitionMode, sort: TableSortColumn, ascending: Bool) -> [ModelTableRow] {
        sortedRows(controller.visibleFamilies(mode), references: controller.visibleReferences(mode), by: sort.metric, ascending: ascending, benchmarks: controller.benchmarks)
    }
    private func rows(_ mode: RecognitionMode) -> [ModelTableRow] { Self.rows(controller, mode, sort: sortColumn, ascending: ascending) }

    /// Header tooltips, in plain words (Toby, 26 Sep evening).
    static let werHeaderHelp = "Word error rate: the percentage of words wrong \u{2014} substituted, missed or added \u{2014} out of the words spoken. The industry-standard accuracy metric, as on the Hugging Face Open ASR Leaderboard. Lower is better. Our v2 benchmark is hard (meetings, far-field microphones, accents, earnings calls), so rates run higher than on public leaderboards. " + deltaHeaderLine
    static let formatHeaderHelp = "Our own measure of finished text: character error rate with case and punctuation kept. No industry standard exists for it. Lower is better. " + deltaHeaderLine
    static let speedHeaderHelp = "Real-time factor (RTFx): audio seconds per processing second. Higher is faster. " + deltaHeaderLine
    static let energyHeaderHelp = "Joules per minute of audio: whole-chip energy, net of idle. Lower is better. " + deltaHeaderLine
    static let memoryHeaderHelp = "Peak memory of Vella's model worker with the model loaded. Lower is better."
    /// The deltas' base, stated once per figure's header.
    static let deltaHeaderLine = "Difference vs Standard 16 below each figure."
    static let capabilitiesHeaderHelp = "What the model can do beyond English dictation; an empty slot means it cannot. Click to show only models with a capability."
    static let filterLead = "Show only models with"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: Self.headerHeight)
            if controller.filterOpen && !controller.filterableCapabilities.isEmpty {
                filterStrip.frame(height: Self.stripHeight)
            }
            Divider().opacity(0.35).padding(.vertical, 4)
            ForEach([RecognitionMode.dictation, .streaming], id: \.self) { mode in
                let sectionRows = rows(mode)
                if sectionRows.contains(where: { if case .family = $0 { return true }; return false }) {
                    Text(mode.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, W.rowPadding).padding(.bottom, 4)
                        .frame(height: Self.sectionHeight, alignment: .bottomLeading)
                        .appKitTooltip(mode == .dictation ? "Transcribes when you finish speaking" : "Types text while you speak")
                    ForEach(sectionRows) { item in
                        Group {
                            switch item {
                            case .family(let family): row(family)
                            case .reference(let reference): referenceRow(reference)
                            }
                        }.padding(.bottom, Self.rowGap)
                    }
                }
            }
            Divider().opacity(0.35).padding(.vertical, 4)
            footer.frame(height: Self.footerHeight)
        }.padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 2)
            .frame(width: Self.width, height: Self.height(controller), alignment: .top)
            .background(Color.clear)
            .foregroundStyle(.primary)
            .overlay(alignment: .top) {
                if copied {
                    Text("Copied").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 3).transition(.opacity).allowsHitTesting(false)
                }
            }
    }

    /// Column labels, each centred over its column (Model reads from the left).
    private var header: some View {
        HStack(spacing: W.spacing) {
            heading("Model", .name, W.model, .leading)
            capabilitiesHeading
            plainHeading("Params", W.params, help: "Model size in parameters.")
            plainHeading(TierControl.title, W.precision, help: TierControl.headerHelp)
            plainHeading(ExactFastSwitch.title, W.path, help: ExactFastSwitch.help)
            heading("WER", .wer, W.wer, .center, help: Self.werHeaderHelp)
            heading("Format", .format, W.format, .center, help: Self.formatHeaderHelp)
            heading("Speed", .speed, W.speed, .center, help: Self.speedHeaderHelp)
            heading("J / min", .energy, W.energy, .center, help: Self.energyHeaderHelp)
            heading("Memory", .memory, W.memory, .center, help: Self.memoryHeaderHelp)
            Color.clear.frame(width: W.action, height: 1)
        }.padding(.horizontal, W.rowPadding)
    }

    /// The Capabilities heading opens and closes the filter strip; a dot beside it while a filter is active. Without a
    /// capability that tells models apart it is a plain label.
    @ViewBuilder private var capabilitiesHeading: some View {
        if controller.filterableCapabilities.isEmpty {
            plainHeading("Capabilities", W.capabilities, help: Self.capabilitiesHeaderHelp)
        } else {
            Button { controller.toggleFilterStrip() } label: {
                Text("Capabilities")
                    .overlay(alignment: .trailing) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 9)
                            .opacity(controller.capabilityFilter.isEmpty ? 0 : 1).allowsHitTesting(false)
                    }
                    .frame(width: W.capabilities, height: Self.headerHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(controller.filterOpen || !controller.capabilityFilter.isEmpty ? .primary : .secondary)
                .accessibilityLabel(controller.capabilityFilter.isEmpty ? "Capabilities" : "Capabilities, filter active")
                .accessibilityHint(Self.capabilitiesHeaderHelp)
        }
    }

    /// "Show only models with ☐ 文 Chinese, Japanese and Korean": inline under the header, because a view hosted in a
    /// menu cannot open a pop-up or popover. A click toggles a checkbox; rows without that capability hide at once.
    private var filterStrip: some View {
        HStack(spacing: 14) {
            Text(Self.filterLead).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(controller.filterableCapabilities, id: \.self) { capability in
                let on = controller.capabilityFilter.contains(capability)
                Button { controller.toggleFilter(capability) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 13))
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Image(systemName: Self.symbol(capability)).font(.system(size: 13))
                        Text(capability.filterTitle).font(.system(size: 12))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(capability.filterTitle).accessibilityValue(on ? "on" : "off")
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, W.rowPadding)
    }
    /// A capability's symbol for the filter strip (a model's own slot may vary it, as the globe does).
    static func symbol(_ c: Capability) -> String { c == .languages ? "globe" : "character.textbox.zh" }

    /// The fixed icon slots: a filled slot shows its symbol with its own tooltip; an empty one keeps its place.
    private func capabilities(_ family: ModelFamily) -> some View {
        let slots = capabilitySlots(family)
        return HStack(spacing: 6) {
            ForEach(Capability.allCases, id: \.self) { c in
                if let slot = slots[c] {
                    Image(systemName: slot.symbol).font(.system(size: 14)).frame(width: 20, height: 22).appKitTooltip(slot.help)
                } else {
                    Color.clear.frame(width: 20, height: 22)
                }
            }
        }.frame(width: W.capabilities)
    }

    @ViewBuilder private func row(_ family: ModelFamily) -> some View {
        let loaded = controller.loaded(family)
        let hot = loaded != nil
        let loading = controller.isLoading(family)
        let precision = controller.selected(family)
        let variant = family.variants[precision]
        let bench = controller.shownResult(family)
        let base = controller.baseResult(family)
        let compare = controller.showsDeltas(family)
        let action = controller.action(family)
        let library = controller.library(family.mode)
        // A confirmed download for this row (a precision made here downloads its source).
        let downloading = controller.downloadRoot(family, precision).flatMap { family.variants[$0] }.map { library.downloadingID == $0.id } ?? false
        HStack(spacing: W.spacing) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 11)).foregroundStyle(Color.orange).frame(width: 12).opacity(hot ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(family.name).font(.system(size: 13)).lineLimit(1)
                    // A flip to Exact that moved the precision says so; else the engine beneath a loaded model.
                    if let note = controller.couplingNote(family) {
                        Text(note).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                            .foregroundStyle(hot ? Self.hotText.opacity(0.8) : .secondary)
                            .appKitTooltip("Exact offers only the precisions whose kernels give output identical to Standard")
                    } else if let loaded, loaded.engine != nil {
                        Text(engineLabel(engine: loaded.engine, chip: runtime?.chip, selection: shownEngineSelection(family, engine: loaded.engine)))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Self.tone(.better, hot: hot)).lineLimit(1)
                            .appKitTooltip(engineHelp(engine: loaded.engine, reason: loaded.engineReason, optimizations: loaded.optimizations,
                                                      chip: runtime?.chip, precision: loaded.precision))
                    }
                }
            }.frame(width: W.model, alignment: .leading)
                .appKitTooltip(modelHelp(family, loaded: loaded))
            capabilities(family)
            Text(family.params.isEmpty ? "—" : family.params).frame(width: W.params)
            precisionControl(family, hot: hot).frame(width: W.precision)
            // Beside the Optimized row, the one it applies to: its centre on that row's centre.
            pathSwitch(family)
                .offset(y: (TierControl.segmentHeight - ExactFastSwitch.height) / 2)
                .frame(width: W.path, height: TierControl.height, alignment: .top)
            metric(formatErrorRate(bench?.wer), compare ? errorRateDelta(bench?.wer, base: base?.wer) : nil, W.wer, hot: hot)
                .appKitTooltip(werHelp(bench, suites: suites))
            metric(formatErrorRate(bench?.format), compare ? errorRateDelta(bench?.format, base: base?.format) : nil, W.format, hot: hot)
                .appKitTooltip(formatHelp(bench, suites: suites))
            metric(formatSpeed(bench?.speed_x), compare ? speedDelta(bench?.speed_x, base: base?.speed_x) : nil, W.speed, hot: hot)
                .overlay(alignment: .leading) {
                    if family.mode == .dictation, let x = bench?.speed_x, x < slowSpeedFloor {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange).accessibilityLabel("very slow")
                    }
                }
                .appKitTooltip(speedHelp(family.mode, bench, suites: suites))
            metric(formatEnergy(bench?.j_per_min), compare ? energyDelta(bench?.j_per_min, base: base?.j_per_min) : nil, W.energy, hot: hot)
                .appKitTooltip(energyHelp(bench, suites: suites))
            metric(formatMemory(bench?.memory_mb), nil, W.memory, hot: hot)
                .appKitTooltip(memoryHelp(bench, suites: suites))
            rowAction(family, action: action, loading: loading, downloading: downloading, variant: variant, library: library, hot: hot, precision: precision, loaded: loaded)
        }.font(Self.valueFont)
            .padding(.horizontal, W.rowPadding).frame(height: Self.rowHeight)
            .background(hot ? Self.hotRow : .clear, in: RoundedRectangle(cornerRadius: 5))
            .background {
                if downloading, let value = library.progress {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.35))
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: value)
                    }.allowsHitTesting(false)
                }
            }
            .foregroundStyle(hot ? Self.hotText : Color.primary)
            .contentShape(Rectangle())
    }

    /// The row's action cell (RowAction.swift): the one-word button, delete beside it under the pointer.
    private func rowAction(_ family: ModelFamily, action: LoadAction, loading: Bool, downloading: Bool, variant: CatalogVariant?,
                           library: ModelLibrary, hot: Bool, precision: String, loaded: LoadedFamily?) -> some View {
        let enabled = !(loading || variant == nil || (action != .get && !controller.runtimeAvailable)
                        || (action == .unload && controller.actions == nil) || (controller.anyBusy && !downloading))
        let busy = downloading ? (library.progress.map { "\(Int($0 * 100))%" } ?? "…") : loading ? "…" : nil
        return RowAction(title: Self.title(action), busyText: busy, emphasized: action == .reload, enabled: enabled,
                         deletable: controller.localPath(family, precision) != nil && !loading, hot: hot,
                         hovered: controller.previewHover == family.id,
                         help: actionTooltip(action, family: family, precision: precision, loaded: loaded?.precision),
                         onPerform: { controller.perform(family) }, onDelete: { requestDelete(family) })
    }

    /// A cloud API for perspective, as a reference row: cloud glyph, greyed, no controls.
    /// Its WER is an estimate (`~13%`); the tooltip says from where and that we did not measure it.
    @ViewBuilder private func referenceRow(_ r: ReferenceEntry) -> some View {
        HStack(spacing: W.spacing) {
            HStack(spacing: 6) {
                Image(systemName: "cloud").font(.system(size: 11)).frame(width: 12)
                Text(r.name).font(.system(size: 13)).lineLimit(1)
            }.frame(width: W.model, alignment: .leading)
                .appKitTooltip(referenceModelHelp(r))
            Color.clear.frame(width: W.capabilities, height: 1)
            Text("\u{2014}").frame(width: W.params)
            Color.clear.frame(width: W.precision + W.spacing + W.path, height: 1)
            metric(formatEstimatedErrorRate(r.wer), nil, W.wer, hot: false)
                .appKitTooltip(referenceWERTooltip(r))
            metric(nil, nil, W.format, hot: false).appKitTooltip(referenceFormatHelp)
            metric(nil, nil, W.speed, hot: false).appKitTooltip(referenceNotApplicableHelp)
            metric(nil, nil, W.energy, hot: false).appKitTooltip(referenceNotApplicableHelp)
            metric(nil, nil, W.memory, hot: false).appKitTooltip(referenceNotApplicableHelp)
            Color.clear.frame(width: W.action, height: 1)
        }.font(Self.valueFont)
            .padding(.horizontal, W.rowPadding).frame(height: Self.referenceRowHeight)
            .foregroundStyle(Color.secondary)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

    static func title(_ action: LoadAction) -> String {
        switch action {
        case .get: return "Get"
        case .load: return "Load"
        case .unload: return "Unload"
        case .reload: return "Reload"
        }
    }

    /// What runs, for the engine label: where Fast = Exact the switch is pinned up (always on), so the label says Fast
    /// whichever position was recorded.
    private func shownEngineSelection(_ family: ModelFamily, engine: String?) -> ModelSelection? {
        guard var s = controller.loadedSelection(family).map({ effectiveSelection($0, engine: engine) }) else { return nil }
        if !controller.switchAvailable(family) { s.mode = .fast }
        return s
    }

    /// The action button's tooltip: the model's state (loaded, on disk, not downloaded), then what a click does.
    private func actionTooltip(_ action: LoadAction, family: ModelFamily, precision: String, loaded: String?) -> String {
        let state = controller.loaded(family) != nil ? "Loaded" : controller.available(family, precision) ? "On disk, not loaded" : "Not downloaded"
        return state + "\n" + actionHelp(action, family: family, precision: precision, loaded: loaded)
    }

    /// What a download fetches for a precision: its own weights, or for a derived precision the weights it is made from.
    private func downloadText(_ family: ModelFamily, _ precision: String) -> String {
        guard let root = controller.downloadRoot(family, precision), let v = family.variants[root] else { return "Download" }
        let size = formatBytes(v.downloadBytes)
        return root == precision ? "Asks, then downloads \(size) from Hugging Face" : "Asks, then downloads the \(precisionFormatName(root)) weights (\(size)) it is made from"
    }
    /// What the row's action does (the action cell's tooltip, second line).
    private func actionHelp(_ action: LoadAction, family: ModelFamily, precision: String, loaded: String?) -> String {
        let mode = family.mode.title.lowercased()
        let derived = controller.derivedSource(family, precision) != nil
        let make = derived ? " The first load makes the \(precisionFormatName(precision)) weights on this Mac." : ""
        switch action {
        case .get: return downloadText(family, precision) + "; then loads it for \(mode)." + make
        case .load: return "Load it for \(mode) and keep it loaded; manually loaded models load again when Vella starts." + make
        case .unload: return "Free its memory; it stays downloaded and does not load at next launch. Dictation loads it again when needed."
        case .reload:
            let swap = "load it at \(precisionFormatName(precision)) for \(mode) in place of the loaded \(precisionFormatName(loaded ?? family.native))."
            return (controller.available(family, precision) ? "Unload the loaded precision and " + swap : downloadText(family, precision) + ", then " + swap) + make
        }
    }


    /// Value on top, delta vs Standard 16 beneath it in small type; centred under the column's label.
    @ViewBuilder private func metric(_ value: String?, _ delta: Delta?, _ width: CGFloat?, hot: Bool) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(value ?? "—").lineLimit(1)
            if let delta {
                Text(delta.text).font(Self.deltaFont).lineLimit(1).fixedSize()
                    .foregroundStyle(Self.tone(delta.tone, hot: hot))
            }
        }.frame(width: width)
    }

    /// The Precision control (TierControl.swift): `Optimized` above `Standard`, each listing its present precisions;
    /// the Optimized row follows the Exact/Fast switch. Disabled while the model is in use.
    @ViewBuilder private func precisionControl(_ family: ModelFamily, hot: Bool) -> some View {
        let optimized = controller.hasOptimizedPath(family) ? controller.precisions(family).map(\.rawValue) : []
        let standard = controller.tiers(family, .standard).map(\.rawValue)
        if optimized.isEmpty && standard.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            TierControl(optimized: optimized, standard: standard,
                        selected: controller.shownCell(family).map { TierControl.Cell($0.path == .standard ? .standard : .optimized, $0.tier.rawValue) },
                        enabled: !controller.inUse(family), unmeasured: unmeasuredCells(family, optimized: optimized, standard: standard), hot: hot,
                        help: { controller.tierHelp(family, tier: ModelTier(rawValue: $0.tier) ?? .t16, path: $0.row == .standard ? .standard : .optimized) },
                        onSelect: { cell in
                            if let tier = ModelTier(rawValue: cell.tier) { controller.select(family, tier: tier, path: cell.row == .standard ? .standard : .optimized) }
                        })
        }
    }

    /// Cells without a measurement (greyed, 'Not measured yet'); the loaded cell always stays selectable.
    private func unmeasuredCells(_ family: ModelFamily, optimized: [String], standard: [String]) -> Set<TierControl.Cell> {
        let mode = controller.currentSelection(family).mode
        let loaded = controller.loadedSelection(family)
        var off: Set<TierControl.Cell> = []
        for (row, tiers, path) in [(TierControl.Row.optimized, optimized, EnginePath.optimized), (.standard, standard, .standard)] {
            for raw in tiers {
                guard let tier = ModelTier(rawValue: raw) else { continue }
                let s = ModelSelection(tier: tier, path: path, mode: mode)
                if !controller.measured(family, s), s != loaded { off.insert(TierControl.Cell(row, raw)) }
            }
        }
        return off
    }

    /// The Exact/Fast switch (ExactFastSwitch.swift) beside the Optimized row: up Fast, down Exact; none for a model
    /// without an Optimized path.
    @ViewBuilder private func pathSwitch(_ family: ModelFamily) -> some View {
        if controller.hasOptimizedPath(family) {
            ExactFastSwitch(position: controller.currentSelection(family).mode == .fast ? .fast : .exact,
                            available: controller.switchAvailable(family), enabled: !controller.inUse(family),
                            exactAvailable: controller.exactAvailable(family),
                            onChange: { controller.setMode(family, $0 == .fast ? .fast : .exact) })
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// The suites the benchmark file describes (names and minutes for the figures' tooltips).
    private var suites: [String: SuiteInfo]? { controller.benchmarks.suites }

    /// Every tooltip of a row as (column, text) in column order: the cells show these texts through AppKit tooltips;
    /// the render harness writes them to table-tooltips.txt and TableTooltipTests checks the format of each one.
    func tooltips(_ family: ModelFamily) -> [(String, String)] {
        let precision = controller.selected(family)
        let r = controller.shownResult(family)
        let loaded = controller.loaded(family)
        let enabled = !controller.inUse(family)
        var cells: [(String, String)] = [("Model", modelHelp(family, loaded: loaded))]
        if controller.couplingNote(family) == nil, let loaded, loaded.engine != nil {
            cells.append(("Engine", engineHelp(engine: loaded.engine, reason: loaded.engineReason, optimizations: loaded.optimizations,
                                               chip: runtime?.chip, precision: loaded.precision)))
        }
        let slots = capabilitySlots(family)
        for c in Capability.allCases { if let slot = slots[c] { cells.append(("Capability \(c.rawValue)", slot.help)) } }
        let optimized = controller.hasOptimizedPath(family)
        let optimizedTiers = optimized ? controller.precisions(family) : []
        let standardTiers = controller.tiers(family, .standard)
        let off = unmeasuredCells(family, optimized: optimizedTiers.map(\.rawValue), standard: standardTiers.map(\.rawValue))
        for tier in optimizedTiers {
            cells.append(("Precision Optimized \(tier.rawValue)", off.contains(TierControl.Cell(.optimized, tier.rawValue)) ? TierControl.notMeasuredHelp
                          : TierControl.tooltip(controller.tierHelp(family, tier: tier, path: .optimized), enabled: enabled)))
        }
        for tier in standardTiers {
            cells.append(("Precision Standard \(tier.rawValue)", off.contains(TierControl.Cell(.standard, tier.rawValue)) ? TierControl.notMeasuredHelp
                          : TierControl.tooltip(controller.tierHelp(family, tier: tier, path: .standard), enabled: enabled)))
        }
        if optimized {
            cells.append(("Exact/Fast", ExactFastSwitch.tooltip(available: controller.switchAvailable(family), enabled: enabled,
                                                                exactAvailable: controller.exactAvailable(family))))
        }
        let action = controller.action(family)
        return cells + [("WER", werHelp(r, suites: suites)), ("Format", formatHelp(r, suites: suites)),
                        ("Speed", speedHelp(family.mode, r, suites: suites)), ("J / min", energyHelp(r, suites: suites)),
                        ("Memory", memoryHelp(r, suites: suites)),
                        ("Action", actionTooltip(action, family: family, precision: precision, loaded: loaded?.precision))]
    }

    /// A reference row's tooltips as (column, text); Capabilities, Params and the controls have none (nothing is known).
    func tooltips(_ r: ReferenceEntry) -> [(String, String)] {
        [("Model", referenceModelHelp(r)), ("WER", referenceWERTooltip(r)), ("Format", referenceFormatHelp),
         ("Speed", referenceNotApplicableHelp), ("J / min", referenceNotApplicableHelp), ("Memory", referenceNotApplicableHelp)]
    }

    /// This Mac's chip: the runtime's, else the CPU brand string.
    static let localChip: String? = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return displayChip(String(cString: bytes))
    }()

    /// Left: an error, else download/Loading progress, else the measurement-hardware note. Right: the agent request,
    /// or Cancel while downloading.
    @ViewBuilder private var footer: some View {
        let busyLibrary = [controller.dictation, controller.streaming].first { $0.busy }
        Group {
            let appError = controller.lastError ?? (busyLibrary == nil ? [controller.dictation, controller.streaming].compactMap(\.downloadError).first : nil)
            if let error = footerNotice(lastError: appError, workerError: runtime?.workerError, refusal: runtime?.refusal, now: Date().timeIntervalSince1970) {
                let text = Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1).appKitTooltip(error)
                ViewThatFits(in: .horizontal) {
                    HStack { text.fixedSize(); Spacer(minLength: 16); requestButton }
                    HStack { text; Spacer(minLength: 0) }
                }
            } else if let busyLibrary {
                HStack {
                    if busyLibrary.progress == nil { ProgressView().controlSize(.mini) }
                    Text(busyLibrary.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).appKitTooltip(busyLibrary.message)
                    Spacer(minLength: 16)
                    Button("Cancel") { controller.cancelDownloads() }
                }
            } else {
                HStack {
                    if let loading = runtime?.loading, !loading.isEmpty {
                        ProgressView().controlSize(.mini)
                        Text("Loading \(controller.catalog.family(loading)?.name ?? loading)…").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if let note = hardwareNote(thisChip: runtime?.chip ?? Self.localChip, measuredOn: measurementChip(controller.benchmarks)) {
                        Text(note.text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.leading, 8).appKitTooltip(note.help)
                    }
                    Spacer(minLength: 16)
                    requestButton
                }
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }

    private var requestButton: some View {
        Button {
            guard controller.dictation.copyAgentRequest() else { return }
            copyGeneration += 1; let generation = copyGeneration
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard generation == copyGeneration else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Want another model? Copy instructions for your agent.")
                Image(systemName: "doc.on.doc").accessibilityHidden(true)
            }.padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            .accessibilityHint("Copies installation instructions to the clipboard. Nothing is sent automatically.")
    }


    private func plainHeading(_ text: String, _ width: CGFloat, help: String) -> some View {
        Text(text).frame(width: width).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).appKitTooltip(help)
    }

    /// Sortable heading; the active one is primary with a small arrow in an overlay beside it, so the label never
    /// shifts off its column's centre. A Button carries no hover text inside the menu (TooltipCell.swift), so `help` is
    /// its accessibility hint; each cell's tooltip says what its figure is.
    private func heading(_ text: String, _ column: TableSortColumn, _ width: CGFloat, _ alignment: Alignment, help: String? = nil) -> some View {
        Button {
            if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = true }
        } label: {
            Text(text)
                .overlay(alignment: .trailing) {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .offset(x: 13)
                        .opacity(sortColumn == column ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: Self.headerHeight, alignment: alignment)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(sortColumn == column ? .primary : .secondary)
            .accessibilityHint(column == .name ? "Sort by name." : (help.map { $0 + " " } ?? "") + "Sorts by each model's best value across its precisions.")
    }
}
