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
        root.toolTip = modelsHelp
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; tableMenu = menu
        let item = NSMenuItem()
        let view = MenuTableHostingView(rootView: ModelTable(controller: controller, requestDelete: { [weak self] family in self?.confirmDeletion(family) }))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(controller))
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
    case name, wer, format, speed, energy, memory, disk
    var metric: TableMetric? {
        switch self {
        case .name: return nil
        case .wer: return .wer
        case .format: return .format
        case .speed: return .speed
        case .energy: return .energy
        case .memory: return .memory
        case .disk: return .disk
        }
    }
}

struct ModelTable: View {
    static let width: CGFloat = 968
    /// Every row fits without scrolling: heading, dividers and footer, 39 pt per row (two tier rows), 21 pt per section label.
    static func height(rows: Int, sections: Int) -> CGFloat { 64 + CGFloat(rows) * rowPitch + CGFloat(sections) * 21 }
    static let rowHeight: CGFloat = 36
    static let rowPitch: CGFloat = rowHeight + 3
    @MainActor static func height(_ c: ModelsController) -> CGFloat { height(rows: c.rowCount, sections: c.sectionCount) }

    @ObservedObject var controller: ModelsController
    var requestDelete: (ModelFamily) -> Void = { _ in }
    @VellaState private var sortColumn: TableSortColumn = .wer
    @VellaState private var ascending = true
    @VellaState private var copied = false
    @VellaState private var copyGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Column widths; spacing 6 between columns.
    private enum W {
        static let model: CGFloat = 152, languages: CGFloat = 64, params: CGFloat = 42
        static let precision: CGFloat = TierControl.width + 4 + ExactFastSwitch.width
        static let wer: CGFloat = 54, format: CGFloat = 54, speed: CGFloat = 64, energy: CGFloat = 58, memory: CGFloat = 64, disk: CGFloat = 64
        static let button: CGFloat = 58, trash: CGFloat = 18
    }
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
    /// Same green family as the deltas, deep enough for white text on the loaded row.
    static let reloadGreen = Color(red: 0.20, green: 0.56, blue: 0.31)

    private var runtime: TableRuntime? { controller.runtime }

    /// Rows of a section in a stable order: each column sorts by the model's best value across its precisions, so
    /// changing a row's selected precision never moves it.
    /// Cloud reference rows sort with the models (by their estimated WER).
    @MainActor static func rows(_ controller: ModelsController, _ mode: RecognitionMode, sort: TableSortColumn, ascending: Bool) -> [ModelTableRow] {
        sortedRows(controller.families(mode), references: controller.references(mode), by: sort.metric, ascending: ascending, benchmarks: controller.benchmarks)
    }
    private func rows(_ mode: RecognitionMode) -> [ModelTableRow] { Self.rows(controller, mode, sort: sortColumn, ascending: ascending) }

    /// Header tooltips, in plain words (Toby, 26 Sep evening).
    static let werHeaderHelp = "Word error rate: the percentage of words wrong \u{2014} substituted, missed or added \u{2014} out of the words spoken. The industry-standard accuracy metric, as on the Hugging Face Open ASR Leaderboard. Lower is better. Our v2 benchmark is hard (meetings, far-field microphones, accents, earnings calls), so rates run higher than on public leaderboards."
    static let formatHeaderHelp = "Our own measure of finished text: character error rate with case and punctuation kept. No industry standard exists for it. Lower is better."
    static let speedHeaderHelp = "Real-time factor (RTFx): audio seconds per processing second. Higher is faster."
    static let energyHeaderHelp = "Joules per minute of audio: whole-chip energy, net of idle. Lower is better."
    static let memoryHeaderHelp = "Peak memory of Vella's model worker with the model loaded. Lower is better."
    static let tierHeaderHelp = "Precision kept: 16 is the checkpoint as published, 8 and 4 are made on this Mac from it. Standard runs stock MLX, as on any Apple-silicon Mac; Optimized adds Vella's kernels for this chip. A tier that breaks against 16 is not offered. A change applies at the next load."
    static let diskHeaderHelp = "Download size of the selected precision; for one made on this Mac, the size of the weights it is made from."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                heading("Model", .name, W.model, .leading)
                plainHeading("Languages", W.languages, .trailing, help: "Languages the model transcribes.")
                plainHeading("Params", W.params, .trailing, help: "Model size in parameters.")
                plainHeading("Tier", W.precision, .leading, help: Self.tierHeaderHelp)
                heading("WER", .wer, W.wer, .trailing, help: Self.werHeaderHelp)
                heading("Format", .format, W.format, .trailing, help: Self.formatHeaderHelp)
                heading("Speed", .speed, W.speed, .trailing, help: Self.speedHeaderHelp)
                heading("J / min", .energy, W.energy, .trailing, help: Self.energyHeaderHelp)
                heading("Memory", .memory, W.memory, .trailing, help: Self.memoryHeaderHelp)
                heading("On disk", .disk, W.disk, .trailing, help: Self.diskHeaderHelp)
                Text("").frame(width: W.button + W.trash + 6)
            }.padding(.horizontal, 6)
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 3) {
                ForEach([RecognitionMode.dictation, .streaming], id: \.self) { mode in
                    let sectionRows = rows(mode)
                    if !sectionRows.isEmpty {
                        Text(mode.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.leading, 6).frame(height: 18, alignment: .bottomLeading)
                            .appKitTooltip(mode == .dictation ? "Transcribes when you finish speaking" : "Types text while you speak")
                        ForEach(sectionRows) { item in
                            switch item {
                            case .family(let family): row(family)
                            case .reference(let reference): referenceRow(reference)
                            }
                        }
                    }
                }
            }
            Divider().opacity(0.35)
            footer
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

    @ViewBuilder private func row(_ family: ModelFamily) -> some View {
        let loaded = controller.loaded(family)
        let hot = loaded != nil
        let loading = controller.isLoading(family)
        let precision = controller.selected(family)
        let variant = family.variants[precision]
        let installed = controller.installed(family, precision)
        let bench = controller.shownResult(family)
        let base = controller.baseResult(family)
        let compare = controller.showsDeltas(family)
        let action = controller.action(family)
        let library = controller.library(family.mode)
        // A confirmed download for this row (a precision made here downloads its source).
        let downloading = controller.downloadRoot(family, precision).flatMap { family.variants[$0] }.map { library.downloadingID == $0.id } ?? false
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: hot ? "flame.fill" : "circle").font(.system(size: 10))
                    .foregroundStyle(hot ? Color.orange : .secondary).frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(family.name).font(.system(size: 11)).lineLimit(1)
                    // Engine label beneath a loaded model. Both paths work, so both are green; the tooltip says which.
                    if let loaded, loaded.engine != nil {
                        Text(engineLabel(engine: loaded.engine, chip: runtime?.chip, selection: controller.loadedSelection(family).map { effectiveSelection($0, engine: loaded.engine) })).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Self.tone(.better, hot: hot)).lineLimit(1)
                            .appKitTooltip(engineHelp(engine: loaded.engine, reason: loaded.engineReason, optimizations: loaded.optimizations,
                                                      chip: runtime?.chip, precision: loaded.precision))
                    }
                }
            }.frame(width: W.model, alignment: .leading)
                .appKitTooltip(modelHelp(family, loaded: loaded))
            Text(formatLanguages(family.languages)).frame(width: W.languages, alignment: .trailing)
                .appKitTooltip(languagesHelp(family, bench))
            Text(family.params.isEmpty ? "—" : family.params).frame(width: W.params, alignment: .trailing)
            tierPicker(family, hot: hot)
                .frame(width: W.precision, alignment: .leading)
            metric(formatErrorRate(bench?.wer), compare ? errorRateDelta(bench?.wer, base: base?.wer) : nil, W.wer, hot: hot)
                .appKitTooltip(werHelp(bench, suites: suites))
            metric(formatErrorRate(bench?.format), compare ? errorRateDelta(bench?.format, base: base?.format) : nil, W.format, hot: hot)
                .appKitTooltip(formatHelp(bench, suites: suites))
            HStack(spacing: 2) {
                if family.mode == .dictation, let x = bench?.speed_x, x < slowSpeedFloor {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange).accessibilityLabel("very slow")
                }
                metric(formatSpeed(bench?.speed_x), compare ? speedDelta(bench?.speed_x, base: base?.speed_x) : nil, nil, hot: hot)
            }.frame(width: W.speed, alignment: .trailing)
                .appKitTooltip(speedHelp(family.mode, bench, suites: suites))
            metric(formatEnergy(bench?.j_per_min), compare ? energyDelta(bench?.j_per_min, base: base?.j_per_min) : nil, W.energy, hot: hot)
                .appKitTooltip(energyHelp(bench, suites: suites))
            metric(formatMemory(bench?.memory_mb), nil, W.memory, hot: hot)
                .appKitTooltip(memoryHelp(bench, suites: suites))
            Text(controller.disk(family, precision).map(formatBytes) ?? "—").frame(width: W.disk, alignment: .trailing)
                .foregroundStyle(installed == nil ? (hot ? Color(nsColor: .selectedMenuItemTextColor).opacity(0.6) : Color.secondary) : (hot ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary))
                .appKitTooltip(diskHelp(family, precision))
            loadButton(title(action, loading: loading, downloading: downloading, library: library), reload: action == .reload && !loading && !downloading) {
                controller.perform(family)
            }.frame(width: W.button)
                .disabled(loading || variant == nil || (action != .get && !controller.runtimeAvailable)
                          || (action == .unload && controller.actions == nil) || (controller.anyBusy && !downloading))
                .accessibilityHint(actionHelp(action, family: family, precision: precision, loaded: loaded?.precision))
            Button { requestDelete(family) } label: { Image(systemName: "trash").frame(width: W.trash) }
                .buttonStyle(.plain)
                .opacity(controller.localPath(family, precision) == nil ? 0 : 1)
                .disabled(controller.localPath(family, precision) == nil || loading)
                .accessibilityHint("Moves the \(precisionFormatName(precision)) weights to the Trash, after you confirm")
                .accessibilityLabel("Delete \(family.name) \(precisionFormatName(precision))")
        }.font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6).frame(height: Self.rowHeight)
            .background(hot ? Self.hotRow : .clear, in: RoundedRectangle(cornerRadius: 4))
            .background {
                if downloading, let value = library.progress {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.35))
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: value)
                    }.allowsHitTesting(false)
                }
            }
            .foregroundStyle(hot ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
            .contentShape(Rectangle())
    }

    /// A cloud API for perspective, as a reference row: cloud glyph, greyed, no controls, `API` on disk.
    /// Its WER is an estimate (`~13%`); the tooltip says from where and that we did not measure it.
    @ViewBuilder private func referenceRow(_ r: ReferenceEntry) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "cloud").font(.system(size: 10)).frame(width: 12)
                Text(r.name).font(.system(size: 11)).lineLimit(1)
            }.frame(width: W.model, alignment: .leading)
                .appKitTooltip(referenceModelHelp(r))
            Text("\u{2014}").frame(width: W.languages, alignment: .trailing)
            Text("\u{2014}").frame(width: W.params, alignment: .trailing)
            Text("").frame(width: W.precision, alignment: .leading)
            metric(formatEstimatedErrorRate(r.wer), nil, W.wer, hot: false)
                .appKitTooltip(referenceWERTooltip(r))
            metric(nil, nil, W.format, hot: false)
                .appKitTooltip(referenceFormatHelp)
            metric(nil, nil, W.speed, hot: false).appKitTooltip(referenceNotApplicableHelp)
            metric(nil, nil, W.energy, hot: false).appKitTooltip(referenceNotApplicableHelp)
            metric(nil, nil, W.memory, hot: false).appKitTooltip(referenceNotApplicableHelp)
            Text("API").frame(width: W.disk, alignment: .trailing)
                .appKitTooltip(referenceDiskHelp)
            Text("").frame(width: W.button + W.trash + 6)
        }.font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6).frame(height: Self.rowHeight)
            .foregroundStyle(Color.secondary)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

    private func title(_ action: LoadAction, loading: Bool, downloading: Bool, library: ModelLibrary) -> String {
        if downloading { return library.progress.map { "\(Int($0 * 100))%" } ?? "…" }
        if loading { return "…" }
        switch action {
        case .get: return "Get"
        case .load: return "Load"
        case .unload: return "Unload"
        case .reload: return "Reload"
        }
    }

    /// What a download fetches for a precision: its own weights, or for a derived precision the weights it is made from.
    private func downloadText(_ family: ModelFamily, _ precision: String) -> String {
        guard let root = controller.downloadRoot(family, precision), let v = family.variants[root] else { return "Download" }
        let size = formatBytes(v.downloadBytes)
        return root == precision ? "Asks, then downloads \(size) from Hugging Face" : "Asks, then downloads the \(precisionFormatName(root)) weights (\(size)) it is made from"
    }
    /// The row button's accessibility hint (a Button carries no hover text inside the menu).
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
    /// Derived precisions are made tensor by tensor at load (DerivedModels.swift); only the source is stored.
    private func diskHelp(_ family: ModelFamily, _ precision: String) -> String {
        VellaCore.diskHelp(family, precision, installed: controller.installed(family, precision) != nil,
                           derivedSource: controller.derivedSource(family, precision), sizeKnown: controller.disk(family, precision) != nil)
    }

    /// Value on top, delta vs Standard 16 beneath it in small type.
    @ViewBuilder private func metric(_ value: String?, _ delta: Delta?, _ width: CGFloat?, hot: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value ?? "—").lineLimit(1)
            if let delta {
                Text(delta.text).font(.system(size: 9)).lineLimit(1).fixedSize()
                    .foregroundStyle(Self.tone(delta.tone, hot: hot))
            }
        }.frame(width: width, alignment: .trailing)
    }

    /// Reload (another precision is selected for the loaded model) is the green variant of the same button.
    @ViewBuilder private func loadButton(_ title: String, reload: Bool, action: @escaping () -> Void) -> some View {
        if reload {
            Button(title, action: action).buttonStyle(ReloadButtonStyle()).controlSize(.small)
        } else {
            Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// `Optimized [16][8][4]` above `Standard [16][8][4]`, the Exact/Fast switch beside them (TierControl.swift,
    /// ExactFastSwitch.swift). Present cells only; disabled while the model is in use.
    @ViewBuilder private func tierPicker(_ family: ModelFamily, hot: Bool) -> some View {
        let selection = controller.currentSelection(family)
        let optimized = controller.tiers(family, .optimized).map(\.rawValue)
        let standard = controller.tiers(family, .standard).map(\.rawValue)
        let enabled = !controller.inUse(family)
        if optimized.isEmpty && standard.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                TierControl(optimized: optimized, standard: standard,
                            selected: controller.shownCell(family).map { TierControl.Cell($0.path == .standard ? .standard : .optimized, $0.tier.rawValue) },
                            enabled: enabled, hot: hot,
                            help: { cell in controller.tierHelp(family, tier: ModelTier(rawValue: cell.tier) ?? .t16, path: cell.row == .standard ? .standard : .optimized) },
                            onSelect: { cell in
                                guard let tier = ModelTier(rawValue: cell.tier) else { return }
                                controller.select(family, tier: tier, path: cell.row == .standard ? .standard : .optimized)
                            })
                ExactFastSwitch(position: selection.mode == .fast ? .fast : .exact, available: controller.switchAvailable(family), enabled: enabled,
                                onChange: { controller.setMode(family, $0 == .fast ? .fast : .exact) })
            }
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
        if let loaded, loaded.engine != nil {
            cells.append(("Engine", engineHelp(engine: loaded.engine, reason: loaded.engineReason, optimizations: loaded.optimizations,
                                               chip: runtime?.chip, precision: loaded.precision)))
        }
        if let languages = languagesHelp(family, r) { cells.append(("Languages", languages)) }
        for path in [EnginePath.optimized, .standard] {
            for tier in controller.tiers(family, path) {
                cells.append(("\(path == .optimized ? "Optimized" : "Standard") \(tier.rawValue)",
                              TierControl.tooltip(controller.tierHelp(family, tier: tier, path: path), enabled: enabled)))
            }
        }
        cells.append(("Exact/Fast", ExactFastSwitch.tooltip(available: controller.switchAvailable(family), enabled: enabled)))
        return cells + [("WER", werHelp(r, suites: suites)), ("Format", formatHelp(r, suites: suites)),
                        ("Speed", speedHelp(family.mode, r, suites: suites)), ("J / min", energyHelp(r, suites: suites)),
                        ("Memory", memoryHelp(r, suites: suites)), ("On disk", diskHelp(family, precision))]
    }

    /// A reference row's tooltips as (column, text); Languages, Params and Q have none (nothing is known).
    func tooltips(_ r: ReferenceEntry) -> [(String, String)] {
        [("Model", referenceModelHelp(r)), ("WER", referenceWERTooltip(r)), ("Format", referenceFormatHelp),
         ("Speed", referenceNotApplicableHelp), ("J / min", referenceNotApplicableHelp), ("Memory", referenceNotApplicableHelp),
         ("On disk", referenceDiskHelp)]
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

    private func plainHeading(_ text: String, _ width: CGFloat, _ alignment: Alignment, help: String) -> some View {
        Text(text).frame(width: width, alignment: alignment).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).appKitTooltip(help)
    }

    /// Sortable heading; the active one is primary with a small arrow in an overlay, so the label never shifts. A Button
    /// carries no hover text inside the menu (TooltipCell.swift), so `help` is its accessibility hint; each cell's
    /// tooltip says what its figure is.
    private func heading(_ text: String, _ column: TableSortColumn, _ width: CGFloat, _ alignment: Alignment, help: String? = nil) -> some View {
        Button {
            if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = true }
        } label: {
            // The arrow sits beside the label in an overlay, so the label never shifts.
            Text(text)
                .overlay(alignment: alignment == .leading ? .trailing : .leading) {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 9)
                        .offset(x: alignment == .leading ? 11 : -11)
                        .opacity(sortColumn == column ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .frame(width: width, alignment: alignment)
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(sortColumn == column ? .primary : .secondary)
            .accessibilityHint(column == .name ? "Sort by name." : (help.map { $0 + " " } ?? "") + "Sorts by each model's best value across its precisions.")
    }
}

/// The pending-Reload button: the bordered small button's shape filled in the deltas' green family (deep enough for
/// white text on the loaded row). Drawn directly, so it stays green in a menu's inactive window.
struct ReloadButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 7).frame(height: 16)
            .background(ModelTable.reloadGreen.opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
