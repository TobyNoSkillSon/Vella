import AppKit
import SwiftUI
import VellaCore

/// Every size of the table is a base size scaled by `ModelTable.Metrics.scale` (TableMetrics, TierControl.swift): a
/// length with `pt`, a font or symbol size with `size`. The comments give the base sizes.
private func pt(_ base: CGFloat) -> CGFloat { TableMetrics.pt(base) }
private func size(_ base: CGFloat) -> CGFloat { TableMetrics.font(base) }

struct ModelTable: View {
    typealias Metrics = TableMetrics
    /// Column widths; `spacing` between columns, `rowPadding` inside a row on each side.
    enum W {
        static let model: CGFloat = pt(194), params: CGFloat = pt(52)
        static let precision: CGFloat = TierControl.width + pt(4), path: CGFloat = max(ExactFastSwitch.width, ExactFastSwitch.showsWords ? 0 : pt(64))
        static let wer: CGFloat = pt(62), format: CGFloat = pt(62), speed: CGFloat = pt(78), energy: CGFloat = pt(64), memory: CGFloat = pt(72)
        static let action: CGFloat = RowAction.width
        static let spacing: CGFloat = pt(6), rowPadding: CGFloat = pt(8)
        /// The leading icon slot of the Model column: the loaded row's 17 pt flame (taller than the name, shorter than the two-line label)
        /// (13 pt name over the 10.5 pt engine line), and the cloud rows' icon, so every name starts at the same x.
        static let icon: CGFloat = pt(24), flameSize: CGFloat = size(17)
        /// The gap after the icon slot, and between the name and the engine line.
        static let iconGap: CGFloat = pt(6), lineGap: CGFloat = pt(1)
        static let columns: [CGFloat] = [model, params, precision, path, wer, format, speed, energy, memory, action]
        static let row: CGFloat = columns.reduce(0, +) + CGFloat(columns.count - 1) * spacing + 2 * rowPadding
    }
    /// The table's padding around the rows: 6 pt leading, `trailingPadding` after the last column (as before v3).
    static let leadingPadding: CGFloat = pt(6), trailingPadding: CGFloat = pt(2)
    /// The table's width, from the columns above: the menu item view and so the menu window take exactly this width, and
    /// the table's own content is exactly this wide in every state (TableWidthTests checks both, on the first layout
    /// pass). Nothing in a row, the header or the footer may be wider than `W.row`.
    static let width: CGFloat = leadingPadding + W.row + trailingPadding
    /// Room right of the action cell (the row padding and the table padding), as the buttons had before v3: the action
    /// button and its trash glyph stay at least this far inside the item view (TableWidthTests).
    static let trailingMargin: CGFloat = W.rowPadding + trailingPadding
    /// One line per model: the Optimized and Standard segment rows with air around them, the Exact/Fast switch as tall as
    /// both; beside them a 13 pt value over a 10.5 pt delta (or the name over its engine label). A cloud row has no
    /// controls and keeps a 38 pt line.
    static let rowHeight: CGFloat = TierControl.height + pt(6)
    static let referenceRowHeight: CGFloat = pt(38)
    static let rowGap: CGFloat = pt(2)
    static let headerHeight: CGFloat = pt(26), sectionHeight: CGFloat = pt(24), footerHeight: CGFloat = pt(28)
    /// The table's padding above and below, the air above and below each hairline divider (the divider itself is 1 pt),
    /// the section label's inset above its bottom, and the loaded and progress rows' corner radius.
    static let verticalPadding: CGFloat = pt(6), dividerPadding: CGFloat = pt(4), sectionBottom: CGFloat = pt(4), rowCorner: CGFloat = pt(5)
    /// The thick line between the Dictation and the Streaming group (Toby, 30 Sep): `groupRule` thick, with air above
    /// and below; it carries the separation, the group words stay.
    static let groupRule: CGFloat = pt(3), groupRuleAbove: CGFloat = pt(8), groupRuleBelow: CGFloat = pt(2)
    static let groupRuleHeight: CGFloat = groupRuleAbove + groupRule + groupRuleBelow
    /// Every visible row fits without scrolling: paddings, heading, dividers, section labels, the group rule and footer.
    static func height(models: Int, references: Int, sections: Int) -> CGFloat {
        2 * verticalPadding + headerHeight + 2 * (1 + 2 * dividerPadding) + CGFloat(sections) * sectionHeight + CGFloat(max(0, sections - 1)) * groupRuleHeight
            + CGFloat(models) * (rowHeight + rowGap) + CGFloat(references) * (referenceRowHeight + rowGap) + footerHeight
    }
    @MainActor static func height(_ c: ModelsController) -> CGFloat {
        let references = RecognitionMode.allCases.reduce(0) { $0 + c.references($1).count }
        return height(models: c.rowCount - references, references: references, sections: c.sectionCount)
    }

    /// Base 13 pt values over 10.5 pt deltas; the name at the value's size over the engine line at the delta's; 12 pt
    /// headings and section labels; 10 pt footer notes, 11 pt for its request.
    static let valueSize = size(13), deltaSize = size(10.5), headingSize = size(12), footerSize = size(10), requestSize = size(11)
    static let valueFont = Font.system(size: valueSize).monospacedDigit()
    static let deltaFont = Font.system(size: deltaSize).monospacedDigit()

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
    /// estimated WER).
    @MainActor static func rows(_ controller: ModelsController, _ mode: RecognitionMode, sort: TableSortColumn, ascending: Bool) -> [ModelTableRow] {
        sortedRows(controller.families(mode), references: controller.references(mode), by: sort.metric, ascending: ascending, benchmarks: controller.benchmarks)
    }
    /// The sections with a model, in order: Dictation, then Streaming.
    @MainActor static func sections(_ controller: ModelsController) -> [RecognitionMode] {
        [RecognitionMode.dictation, .streaming].filter { !controller.families($0).isEmpty }
    }
    private func rows(_ mode: RecognitionMode) -> [ModelTableRow] { Self.rows(controller, mode, sort: sortColumn, ascending: ascending) }

    /// Header tooltips, one line each (Toby, 30 Sep). The four figures with a small change figure under them add
    /// `deltaHeaderLine` on a second line.
    static let werHeaderHelp = "Word error rate: share of words wrong. Ignores capitals and punctuation. Lower is better.\n" + deltaHeaderLine
    static let formatHeaderHelp =
        "Finished-text errors: share of characters wrong, capitals and punctuation included. Lower is better.\n" + deltaHeaderLine
    static let speedHeaderHelp = "Seconds of audio transcribed per second. Higher is faster.\n" + deltaHeaderLine
    static let energyHeaderHelp = "Energy per minute of audio, whole chip, idle subtracted. Lower is better.\n" + deltaHeaderLine
    static let memoryHeaderHelp = "Peak memory of the model worker during loading and transcription. Lower is better."
    static let modelHeaderHelp = "The speech model. Hover a name for its languages and details."
    static let paramsHeaderHelp = "Model size in parameters."
    /// The small figures' base, one shared line.
    static let deltaHeaderLine = "Small figure: change vs Standard 16-bit."
    /// The Memory column's heading (Toby, 30 Sep).
    static let memoryTitle = "Peak RAM"

    /// The table is exactly as wide as its columns (`width`): header, rows and footer each take `W.row`, and nothing
    /// widens the stack, so the item view, the menu window and the content agree in every state.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(width: W.row, height: Self.headerHeight)
            Divider().opacity(0.35).padding(.vertical, Self.dividerPadding)
            let sections = Self.sections(controller)
            ForEach(sections, id: \.self) { mode in
                let sectionRows = rows(mode)
                if mode != sections.first {
                    // One thick line between the groups, in the dividers' colour.
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: W.row, height: Self.groupRule)
                        .padding(.top, Self.groupRuleAbove).padding(.bottom, Self.groupRuleBelow)
                        .accessibilityHidden(true)
                }
                Text(mode.title).font(.system(size: Self.headingSize, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, W.rowPadding).padding(.bottom, Self.sectionBottom)
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
            Divider().opacity(0.35).padding(.vertical, Self.dividerPadding)
            footer.frame(width: W.row, height: Self.footerHeight)
        }.padding(.vertical, Self.verticalPadding).padding(.leading, Self.leadingPadding).padding(.trailing, Self.trailingPadding)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: Self.height(controller), alignment: .top)
            .background(Color.clear)
            .foregroundStyle(.primary)
            .overlay(alignment: .top) {
                if copied {
                    Text("Copied").font(.system(size: Self.headingSize, weight: .medium))
                        .padding(.horizontal, pt(12)).padding(.vertical, pt(5))
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, pt(3)).transition(.opacity).allowsHitTesting(false)
                }
            }
    }

    /// Column labels, each centred over its column (Model reads from the left).
    private var header: some View {
        HStack(spacing: W.spacing) {
            heading("Model", .name, W.model, .leading, help: Self.modelHeaderHelp)
            plainHeading("Params", W.params, help: Self.paramsHeaderHelp)
            plainHeading(TierControl.title, W.precision, help: TierControl.headerHelp)
            plainHeading(ExactFastSwitch.title, W.path, help: ExactFastSwitch.help)
            heading("WER", .wer, W.wer, .center, help: Self.werHeaderHelp)
            heading("Format", .format, W.format, .center, help: Self.formatHeaderHelp)
            heading("Speed", .speed, W.speed, .center, help: Self.speedHeaderHelp)
            heading("J / min", .energy, W.energy, .center, help: Self.energyHeaderHelp)
            heading(Self.memoryTitle, .memory, W.memory, .center, help: Self.memoryHeaderHelp)
            Color.clear.frame(width: W.action, height: 1)
        }.padding(.horizontal, W.rowPadding)
    }

    @ViewBuilder private func row(_ family: ModelFamily) -> some View {
        let loaded = controller.loaded(family)
        let hot = loaded != nil
        let loading = controller.isLoading(family)
        let precision = controller.selected(family)
        let variant = family.variants[precision]
        // benchmarks.json `figures_pending`: no figure and no delta anywhere until the final build is measured.
        let pending = controller.benchmarks.figuresPending
        let bench = pending ? nil : controller.shownResult(family)
        let base = pending ? nil : controller.baseResult(family)
        let compare = !pending && controller.showsDeltas(family)
        let action = controller.action(family)
        let library = controller.library(family.mode)
        // A confirmed download for this row (a precision made here downloads its source).
        let downloading = controller.downloadRoot(family, precision).flatMap { family.variants[$0] }.map { library.downloadingID == $0.id } ?? false
        HStack(spacing: W.spacing) {
            HStack(spacing: W.iconGap) {
                Image(systemName: "flame.fill").font(.system(size: W.flameSize)).foregroundStyle(Color.orange)
                    .frame(width: W.icon).opacity(hot ? 1 : 0)
                VStack(alignment: .leading, spacing: W.lineGap) {
                    Text(family.name).font(.system(size: Self.valueSize)).lineLimit(1)
                    // A flip to Exact that moved the precision says so; else the engine beneath a loaded model.
                    if let note = controller.couplingNote(family) {
                        Text(note).font(.system(size: Self.deltaSize, weight: .medium)).lineLimit(1)
                            .foregroundStyle(hot ? Self.hotText.opacity(0.8) : .secondary)
                            .appKitTooltip("Exact offers exact-only components that must match Standard on the load-time self-test")
                    } else if let loaded, loaded.engine != nil {
                        Text(
                            controller.fellBack(family)
                                ? "Fell back to Standard" : engineLabel(engine: loaded.engine, chip: runtime?.chip, selection: shownEngineSelection(family, engine: loaded.engine))
                        )
                        .font(.system(size: Self.deltaSize, weight: .medium))
                        .foregroundStyle(controller.fellBack(family) ? Color(nsColor: TierControl.hotBoltTint) : Self.tone(.better, hot: hot)).lineLimit(1)
                        .appKitTooltip(
                            controller.loadedEngineHelp(family))
                    }
                }
            }.frame(width: W.model, alignment: .leading)
                .appKitTooltip(modelHelp(family, loaded: loaded))
            Text(family.params.isEmpty ? "—" : family.params).frame(width: W.params)
            precisionControl(family, hot: hot).frame(width: W.precision)
            // As tall as both segment rows and centred on the pair; it applies to the Optimized row (its knob's bolt).
            pathSwitch(family)
                .frame(width: W.path, height: TierControl.height)
            metric(formatErrorRate(bench?.wer), compare ? errorRateDelta(bench?.wer, base: base?.wer) : nil, W.wer, hot: hot)
                .appKitTooltip(pending ? figuresPendingHelp : figureHelp(family, werHelp(bench, suites: suites)))
            metric(formatErrorRate(bench?.format), compare ? errorRateDelta(bench?.format, base: base?.format) : nil, W.format, hot: hot)
                .appKitTooltip(pending ? figuresPendingHelp : figureHelp(family, formatHelp(bench, suites: suites)))
            metric(
                controller.benchmarkHardware.speedText(bench?.speed_x),
                compare && controller.benchmarkHardware.isMeasuredConfiguration ? speedDelta(bench?.speed_x, base: base?.speed_x) : nil, W.speed, hot: hot,
                referenceLabel: bench?.speed_x == nil ? nil : controller.benchmarkHardware.speedReferenceLabel
            )
            .overlay(alignment: .leading) {
                if family.mode == .dictation, let x = bench?.speed_x, x < slowSpeedFloor {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size(9))).foregroundStyle(.orange).accessibilityLabel("very slow")
                }
            }
            .appKitTooltip(pending ? figuresPendingHelp : figureHelp(family, speedHelp(family.mode, bench, suites: suites)))
            metric(
                controller.benchmarkHardware.energyText(bench?.j_per_min),
                compare && controller.benchmarkHardware.isMeasuredConfiguration ? energyDelta(bench?.j_per_min, base: base?.j_per_min) : nil, W.energy, hot: hot,
                subdued: !controller.benchmarkHardware.isMeasuredConfiguration
            )
            .appKitTooltip(pending ? figuresPendingHelp : figureHelp(family, energyHelp(bench, suites: suites)))
            metric(formatMemory(bench?.memory_mb), nil, W.memory, hot: hot)
                .appKitTooltip(pending ? figuresPendingHelp : figureHelp(family, memoryHelp(bench, suites: suites)))
            rowAction(family, action: action, loading: loading, downloading: downloading, variant: variant, library: library, hot: hot, precision: precision, loaded: loaded)
        }.font(Self.valueFont)
            .padding(.horizontal, W.rowPadding).frame(height: Self.rowHeight)
            .background(hot ? Self.hotRow : .clear, in: RoundedRectangle(cornerRadius: Self.rowCorner))
            .background {
                if downloading, let value = library.progress {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: Self.rowCorner)
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
    private func rowAction(
        _ family: ModelFamily, action: LoadAction, loading: Bool, downloading: Bool, variant: CatalogVariant?,
        library: ModelLibrary, hot: Bool, precision: String, loaded: LoadedFamily?
    ) -> some View {
        let enabled =
            !(loading || variant == nil || (action != .get && !controller.runtimeAvailable)
            || (action == .unload && controller.actions == nil) || (controller.anyBusy && !downloading))
        let busy = downloading ? (library.progress.map { "\(Int($0 * 100))%" } ?? "…") : loading ? "…" : nil
        return RowAction(
            title: Self.title(action), busyText: busy, emphasized: action == .reload, enabled: enabled,
            deletable: controller.localPath(family, precision) != nil && !loading, hot: hot,
            hovered: controller.previewHover == family.id,
            help: actionTooltip(action, family: family, precision: precision, loaded: loaded?.precision),
            onPerform: { controller.perform(family) }, onDelete: { requestDelete(family) })
    }

    /// A cloud API for perspective, as a reference row: cloud glyph, greyed, no controls.
    /// Its WER is an estimate (`~13%`); the tooltip says from where and that we did not measure it.
    @ViewBuilder private func referenceRow(_ r: ReferenceEntry) -> some View {
        HStack(spacing: W.spacing) {
            HStack(spacing: W.iconGap) {
                Image(systemName: "cloud").font(.system(size: size(11))).frame(width: W.icon)
                Text(r.name).font(.system(size: Self.valueSize)).lineLimit(1)
            }.frame(width: W.model, alignment: .leading)
                .appKitTooltip(referenceModelHelp(r))
            Text("\u{2014}").frame(width: W.params)
            Color.clear.frame(width: W.precision + W.spacing + W.path, height: 1)
            // The estimate is scaled from the local models' measured WER: pending with them.
            metric(controller.benchmarks.figuresPending ? nil : formatEstimatedErrorRate(r.wer), nil, W.wer, hot: false)
                .appKitTooltip(controller.benchmarks.figuresPending ? figuresPendingHelp : referenceWERTooltip(r))
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
        let make = derived ? " The quantized weights are made in memory each time this precision loads." : ""
        switch action {
        case .get: return downloadText(family, precision) + "; then loads it for \(mode)." + make
        case .load: return "Load it for \(mode) and keep it loaded; manually loaded models load again when Vella starts." + make
        case .unload: return "Free its memory; it stays downloaded and does not load at next launch. Its next use loads it again."
        case .reload:
            let swap = "load it at \(precisionFormatName(precision)) for \(mode) in place of the loaded \(precisionFormatName(loaded ?? family.native))."
            return (controller.available(family, precision) ? "Unload the loaded precision and " + swap : downloadText(family, precision) + ", then " + swap) + make
        }
    }

    /// Value on top, delta vs Standard 16 beneath it in small type; centred under the column's label.
    @ViewBuilder private func metric(_ value: String?, _ delta: Delta?, _ width: CGFloat?, hot: Bool, referenceLabel: String? = nil, subdued: Bool = false) -> some View {
        VStack(alignment: .center, spacing: W.lineGap) {
            Text(value ?? "—").lineLimit(1).foregroundStyle(referenceLabel == nil && !subdued ? Color.primary : Color.secondary)
            if let referenceLabel { Text(referenceLabel).font(Self.deltaFont).foregroundStyle(.secondary) }
            if let delta {
                Text(delta.text).font(Self.deltaFont).lineLimit(1).fixedSize()
                    .foregroundStyle(Self.tone(delta.tone, hot: hot))
            }
        }.frame(width: width)
    }

    /// The Precision control (TierControl.swift): the Optimized row (bolt) above the Standard row (MLX logo), each with
    /// all three cells labelled with the dtype that runs; the Optimized row follows the Exact/Fast switch. A cell that
    /// cannot be chosen is greyed in place with its reason. Disabled while the model is in use.
    private func precisionControl(_ family: ModelFamily, hot: Bool) -> some View {
        TierControl(
            labels: TierControl.columns.map { ModelTier(rawValue: $0).map { tierDTypeLabel(family, $0) } ?? $0 },
            selected: controller.shownCell(family).map { TierControl.Cell($0.path == .standard ? .standard : .optimized, $0.tier.rawValue) },
            enabled: !controller.inUse(family), unavailable: unavailableCells(family), hot: hot,
            loaded: controller.loadedSelection(family).map { TierControl.Cell($0.path == .standard ? .standard : .optimized, $0.tier.rawValue) },
            help: { controller.tierHelp(family, tier: ModelTier(rawValue: $0.tier) ?? .t16, path: $0.row == .standard ? .standard : .optimized) },
            onSelect: { cell in
                if let tier = ModelTier(rawValue: cell.tier) { controller.select(family, tier: tier, path: cell.row == .standard ? .standard : .optimized) }
            })
    }

    /// The cells of both rows that cannot be chosen, each with its one-line reason (the greyed cell's tooltip), in this
    /// order: a model without an Optimized path; a tier the catalog does not offer (or malformed gate data); under
    /// Exact, a tier with only a Fast recipe; a cell without a measurement ('Not measured yet'), except the loaded cell,
    /// which always stays selectable. Selection itself follows `SelectionRules` as before; this only names the cells.
    func unavailableCells(_ family: ModelFamily) -> [TierControl.Cell: String] {
        let mode = controller.currentSelection(family).mode
        let loaded = controller.loadedSelection(family)
        var off: [TierControl.Cell: String] = [:]
        for tier in ModelTier.allCases {
            for (row, path) in [(TierControl.Row.optimized, EnginePath.optimized), (.standard, .standard)] {
                let cell = TierControl.Cell(row, tier.rawValue)
                let s = ModelSelection(tier: tier, path: path, mode: mode)
                if let reason = controller.rules(family).cellRefusal(s, loaded: loaded) { off[cell] = reason }
            }
        }
        return off
    }

    /// The Exact/Fast switch (ExactFastSwitch.swift) beside both rows, for the Optimized one: up Fast, down Exact; none
    /// for a model without an Optimized path.
    @ViewBuilder private func pathSwitch(_ family: ModelFamily) -> some View {
        if controller.hasOptimizedPath(family) {
            ExactFastSwitch(
                position: controller.currentSelection(family).mode == .fast ? .fast : .exact,
                available: controller.switchAvailable(family), enabled: !controller.inUse(family),
                exactAvailable: controller.exactAvailable(family), hot: controller.loadedSelection(family)?.path == .optimized,
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
        if controller.couplingNote(family) == nil, loaded?.engine != nil {
            cells.append(
                (
                    "Engine",
                    controller.loadedEngineHelp(family)
                ))
        }
        let optimized = controller.hasOptimizedPath(family)
        let off = unavailableCells(family)
        for row in TierControl.Row.allCases {
            cells.append(("Path \(row.title)", row.help))
            for tier in ModelTier.allCases {
                let cell = TierControl.Cell(row, tier.rawValue)
                cells.append(
                    (
                        "Precision \(row.title) \(tierDTypeLabel(family, tier))",
                        off[cell] ?? TierControl.tooltip(controller.tierHelp(family, tier: tier, path: row == .standard ? .standard : .optimized), enabled: enabled)
                    ))
            }
        }
        if optimized {
            cells.append(
                (
                    "Exact/Fast",
                    ExactFastSwitch.tooltip(
                        available: controller.switchAvailable(family), enabled: enabled,
                        exactAvailable: controller.exactAvailable(family))
                ))
        }
        let action = controller.action(family)
        let figures: [(String, String)] =
            controller.benchmarks.figuresPending
            ? ["WER", "Format", "Speed", "J / min", Self.memoryTitle].map { ($0, figuresPendingHelp) }
            : [
                ("WER", figureHelp(family, werHelp(r, suites: suites))), ("Format", figureHelp(family, formatHelp(r, suites: suites))),
                ("Speed", figureHelp(family, speedHelp(family.mode, r, suites: suites))), ("J / min", figureHelp(family, energyHelp(r, suites: suites))),
                (Self.memoryTitle, figureHelp(family, memoryHelp(r, suites: suites)))
            ]
        return cells + figures + [("Action", actionTooltip(action, family: family, precision: precision, loaded: loaded?.precision))]
    }

    /// Retained loaded selections can point at a withdrawn cell; its reason still belongs on every figure.
    private func figureHelp(_ family: ModelFamily, _ measuredHelp: String) -> String {
        let cell = controller.shownCell(family).flatMap { benchmarkCell(controller.benchmark(family), $0) }
        return cell?.isPending == true ? unmeasuredReasonHelp(cell) : [measuredHelp, controller.benchmarkHardware.caveat].compactMap { $0 }.joined(separator: "\n")
    }

    /// A reference row's tooltips as (column, text); Params and the controls have none (nothing is known).
    func tooltips(_ r: ReferenceEntry) -> [(String, String)] {
        [
            ("Model", referenceModelHelp(r)), ("WER", controller.benchmarks.figuresPending ? figuresPendingHelp : referenceWERTooltip(r)),
            ("Format", referenceFormatHelp), ("Speed", referenceNotApplicableHelp), ("J / min", referenceNotApplicableHelp),
            (Self.memoryTitle, referenceNotApplicableHelp)
        ]
    }

    /// This Mac's chip: the runtime's, else the CPU brand string.
    static let localChip: String? = displayChip(HostInfo.cpuBrand)

    /// Left: an error, else download/Loading progress, else the measurement-hardware note. Right: the agent request,
    /// or Cancel while downloading.
    @ViewBuilder private var footer: some View {
        let busyLibrary = [controller.dictation, controller.streaming].first { $0.busy }
        Group {
            let appError = controller.lastError ?? (busyLibrary == nil ? [controller.dictation, controller.streaming].compactMap(\.downloadFooter).first : nil)
            if let error = footerNotice(lastError: appError, workerError: runtime?.workerError, refusal: runtime?.refusal, now: Date().timeIntervalSince1970) {
                let text = Text(error).font(.system(size: Self.footerSize)).foregroundStyle(.red).lineLimit(1).appKitTooltip(error)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        text.fixedSize(); Spacer(minLength: pt(16)); requestButton
                    }
                    HStack {
                        text; Spacer(minLength: 0)
                    }
                }
            } else if let busyLibrary {
                HStack {
                    if busyLibrary.progress == nil { ProgressView().controlSize(.mini) }
                    Text(busyLibrary.message).font(.system(size: Self.footerSize)).foregroundStyle(.secondary).lineLimit(1).appKitTooltip(busyLibrary.message)
                    Spacer(minLength: pt(16))
                    // A stock small button (its bezel stays 20 pt high); its title at the table's scale.
                    Button {
                        controller.cancelDownloads()
                    } label: {
                        Text("Cancel").font(.system(size: Self.requestSize))
                    }
                }
            } else {
                HStack {
                    if let loading = runtime?.loading, !loading.isEmpty {
                        ProgressView().controlSize(.mini)
                        Text("Loading \(controller.catalog.family(loading)?.name ?? loading)…").font(.system(size: Self.footerSize)).foregroundStyle(.secondary)
                    } else if !controller.benchmarks.figuresPending,
                        let note = hardwareNote(
                            thisChip: controller.benchmarkHardware.chip, measuredOn: measurementChip(controller.benchmarks), gpuCores: controller.benchmarkHardware.gpuCores)
                    {
                        Text(note.text).font(.system(size: Self.footerSize)).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.leading, pt(8)).appKitTooltip(note.help)
                    }
                    Spacer(minLength: pt(16))
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
            HStack(spacing: pt(6)) {
                Text("Want another model? Copy instructions for your agent.")
                Image(systemName: "doc.on.doc").accessibilityHidden(true)
            }.padding(.horizontal, pt(8)).contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: Self.requestSize)).foregroundStyle(.secondary).fixedSize()
            .accessibilityHint("Copies installation instructions to the clipboard. Nothing is sent automatically.")
    }

    private func plainHeading(_ text: String, _ width: CGFloat, help: String) -> some View {
        Text(text).frame(width: width).font(.system(size: Self.headingSize, weight: .medium)).foregroundStyle(.secondary).appKitTooltip(help)
    }

    /// Sortable heading. An AppKit view (SortHeaderView) draws the label and the sort arrow and carries the tooltip and
    /// the click: inside an NSMenu only AppKit's tooltip manager runs, and a SwiftUI Button can neither show `.help`
    /// there nor sit over a TooltipCell (TooltipCell.swift), so the header text used to reach VoiceOver only.
    private func heading(_ text: String, _ column: TableSortColumn, _ width: CGFloat, _ alignment: Alignment, help: String) -> some View {
        // While the figures are pending, a figure column sorts nothing (catalog order): no arrow, not highlighted.
        let active = sortColumn == column && (column == .name || !controller.benchmarks.figuresPending)
        return SortHeader(
            title: text, help: help, active: active, ascending: ascending, leading: alignment == .leading,
            onClick: { if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = true } }
        )
        .frame(width: width, height: Self.headerHeight)
    }
}

/// A sortable column heading as an AppKit view: label, sort arrow beside it (never shifting the label off its column's
/// centre), the column's tooltip, and a click that sorts. The whole cell is the hit target.
private struct SortHeader: NSViewRepresentable {
    let title: String
    let help: String
    let active: Bool
    let ascending: Bool
    let leading: Bool
    let onClick: () -> Void

    func makeNSView(context: Context) -> SortHeaderView { let view = SortHeaderView(); update(view); return view }
    func updateNSView(_ view: SortHeaderView, context: Context) { update(view) }
    private func update(_ view: SortHeaderView) {
        view.title = title; view.active = active; view.ascending = ascending; view.leading = leading; view.onClick = onClick
        if view.toolTip != help { view.toolTip = help }
        view.setAccessibilityHelp(help)
        view.needsDisplay = true
    }
}

final class SortHeaderView: NSView {
    var title = ""
    var active = false
    var ascending = true
    var leading = false
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var font: NSFont { .systemFont(ofSize: ModelTable.headingSize, weight: .medium) }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let x = leading ? 0 : (bounds.width - size.width) / 2
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        guard active else { return }
        let config = NSImage.SymbolConfiguration(pointSize: TableMetrics.font(9), weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor]))
        guard
            let arrow = NSImage(systemSymbolName: ascending ? "arrow.up" : "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return }
        let a = arrow.size
        arrow.draw(
            in: NSRect(x: x + size.width + TableMetrics.pt(3), y: (bounds.height - a.height) / 2, width: a.width, height: a.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        HostRefresh.after(self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
