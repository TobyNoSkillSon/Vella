import AppKit
import SwiftUI

// The Models table's tier picker: two segment rows, `Optimized [16][8][4]` above `Standard [16][8][4]`.
// Shared verbatim by Verdict, Vella and Vireo (like TooltipCell.swift): AppKit and SwiftUI only, no app types; plain
// values in, one callback out.
//
// - A row lists only the tiers it offers; an absent cell is omitted, never greyed. Cells stay in fixed tier columns
//   (16, 8, 4), so a row that lacks its leading tier starts one column in.
// - Exactly one cell is selected across both rows. Clicking a cell reports it; what that means (preview, deltas,
//   Reload) is the app's business. No cell is coloured as recommended.
// - `enabled == false` is the in-use interlock (dictating, speaking, rendering, judging, loading): both rows are
//   disabled and every cell's tooltip gains `inUseHelp`.
// - Cell tooltips are NSSegmentedControl per-segment tooltips: they work inside an NSMenu, where SwiftUI `.help`
//   never shows (TooltipCell.swift).

struct TierControl: View {
    enum Row: String, CaseIterable {
        case optimized, standard
        var title: String { self == .optimized ? "Optimized" : "Standard" }
    }
    struct Cell: Hashable {
        var row: Row
        var tier: String
        init(_ row: Row, _ tier: String) { self.row = row; self.tier = tier }
    }

    /// The one interlock line, shared by the tier rows and the Exact/Fast switch in every app.
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    /// Tier columns, highest precision first. Labels are bare: 16, 8, 4.
    static let columns = ["16", "8", "4"]
    static let labelWidth: CGFloat = 46
    static let rowSpacing: CGFloat = 2
    static let rowHeight: CGFloat = 15
    /// Width of one tier column (a bare two-digit label in a mini segment).
    static let cellWidth: CGFloat = 23
    /// Height of both rows; the Exact/Fast switch beside them uses the same.
    static let height: CGFloat = 2 * rowHeight + rowSpacing
    /// Label plus three cells.
    static let width: CGFloat = labelWidth + 4 + CGFloat(columns.count) * cellWidth

    /// Tiers each row offers (a subset of `columns`, in any order).
    let optimized: [String]
    let standard: [String]
    let selected: Cell?
    let enabled: Bool
    /// The model is loaded: the selected cell uses the accent colour.
    var hot = false
    /// Tooltip per cell (the app's flavour and delta lines).
    let help: (Cell) -> String
    let onSelect: (Cell) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            row(.optimized, optimized)
            row(.standard, standard)
        }.frame(width: Self.width, height: Self.height, alignment: .leading)
    }

    /// A cell's tooltip as shown: the app's text, plus the interlock line while in use.
    static func tooltip(_ text: String, enabled: Bool) -> String { enabled ? text : text + "\n" + inUseHelp }

    @ViewBuilder private func row(_ row: Row, _ offered: [String]) -> some View {
        let tiers = Self.columns.filter(offered.contains)
        HStack(spacing: 4) {
            Text(tiers.isEmpty ? "" : row.title)
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            if let first = tiers.first {
                TierSegments(tiers: tiers, selected: selected?.row == row ? selected?.tier : nil, enabled: enabled, hot: hot,
                             help: { Self.tooltip(help(Cell(row, $0)), enabled: enabled) },
                             onSelect: { onSelect(Cell(row, $0)) })
                    .fixedSize()
                    .padding(.leading, CGFloat(Self.columns.firstIndex(of: first) ?? 0) * Self.cellWidth)
            }
        }.frame(height: Self.rowHeight)
    }
}

/// One row's segments: a mini NSSegmentedControl with per-segment tooltips.
private struct TierSegments: NSViewRepresentable {
    let tiers: [String]
    let selected: String?
    let enabled: Bool
    let hot: Bool
    let help: (String) -> String
    let onSelect: (String) -> Void

    final class Coordinator: NSObject {
        var parent: TierSegments
        init(_ parent: TierSegments) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.tiers.indices.contains(index) else { return }
            parent.onSelect(parent.tiers[index])
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static var font: NSFont { .systemFont(ofSize: NSFont.systemFontSize(for: .mini)) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        update(control)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        update(control)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? { nsView.intrinsicContentSize }

    private func update(_ control: NSSegmentedControl) {
        if control.segmentCount != tiers.count { control.segmentCount = tiers.count }
        control.controlSize = .mini   // SwiftUI may push its environment size onto hosted controls
        control.font = Self.font
        for (i, tier) in tiers.enumerated() {
            control.setLabel(tier, forSegment: i)
            control.setWidth(TierControl.cellWidth - 2, forSegment: i)
            control.setToolTip(help(tier), forSegment: i)
        }
        control.selectedSegment = selected.flatMap { tiers.firstIndex(of: $0) } ?? -1
        control.isEnabled = enabled
        control.selectedSegmentBezelColor = hot ? .controlAccentColor : nil
        control.needsDisplay = true
    }
}
