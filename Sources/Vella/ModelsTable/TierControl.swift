import AppKit
import SwiftUI

// The Models table's Precision control: two segment rows, `Optimized [16][8][4]` above `Standard [16][8][4]`.
// Shared verbatim by Verdict, Vella and Vireo (like TooltipCell.swift): AppKit and SwiftUI only, no app types; plain
// values in, one callback out.
//
// - A row lists only the precisions it offers; an absent one is omitted, never greyed. Segments stay in fixed columns
//   (16, 8, 4), so a row that lacks its leading precision starts one column in. A row with none shows no label either.
// - Exactly one cell is selected across both rows. Clicking a cell reports it; what that means (preview, deltas,
//   Reload) is the app's business. No cell is coloured as recommended.
// - The row labels are in the body type of the table (13 pt, primary), not a caption.
// - `enabled == false` is the in-use interlock (dictating, speaking, rendering, judging, loading): both rows are
//   disabled and every segment's tooltip gains `inUseHelp`.
// - Segment tooltips are NSSegmentedControl per-segment tooltips: they work inside an NSMenu, where SwiftUI `.help`
//   never shows (TooltipCell.swift).
// - The geometry is explicit (two regular segmented controls, `segmentHeight` each, `rowSpacing` apart): a hosted
//   NSControl can take the environment's control size until its first update, so nothing here asks the control for
//   its size and the FIRST layout of a menu already has both rows apart.

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

    /// The column header and its tooltip (Toby, 29 Sep).
    static let title = "Precision"
    static let headerHelp = "Bits per weight. 16 = as released; 8 and 4 compressed on your Mac \u{2014} smaller, faster, slightly less accurate."
    /// The one interlock line, shared by the Precision segments and the Exact/Fast switch in every app.
    /// The selected cell's fill on a loaded row.
    static let hotSelection = NSColor(white: 0.1, alpha: 0.85)
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    /// Columns, highest precision first. Labels are bare: 16, 8, 4.
    static let columns = ["16", "8", "4"]
    /// A regular NSSegmentedControl's height (24 pt on macOS 26).
    static let segmentHeight: CGFloat = 24
    /// Air between the Optimized and the Standard row.
    static let rowSpacing: CGFloat = 6
    /// Both rows: the control's own height, which the table row and the Exact/Fast switch beside it use.
    static let height: CGFloat = 2 * segmentHeight + rowSpacing
    /// Width of one column (a bare two-digit label in a regular segment).
    static let cellWidth: CGFloat = 32
    /// The row label ("Optimized" in 13 pt) and the gap after it.
    static let labelWidth: CGFloat = 68, labelGap: CGFloat = 6
    static let labelFont = Font.system(size: 13)
    /// Width of a row's segments: each segment is `cellWidth - 2` wide plus a 1 pt divider, less the outer one.
    static func segmentsWidth(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * (cellWidth - 1) - 1 }
    /// Label plus three columns.
    static let width: CGFloat = labelWidth + labelGap + CGFloat(columns.count) * cellWidth
    static var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    /// Precisions each row offers (a subset of `columns`, in any order).
    let optimized: [String]
    let standard: [String]
    let selected: Cell?
    let enabled: Bool
    /// Cells whose recipe has no measurement yet: shown greyed with `notMeasuredHelp`, never selectable (family rule,
    /// 29 Sep). They become selectable as soon as the app's data has their numbers.
    var unmeasured: Set<Cell> = []
    /// The model is loaded: the selected segment uses the accent colour.
    var hot = false
    /// Tooltip per cell (the app's flavour and "vs Standard 16" lines).
    let help: (Cell) -> String
    let onSelect: (Cell) -> Void

    /// A segment's tooltip as shown: the app's text, plus the interlock line while in use.
    static func tooltip(_ text: String, enabled: Bool) -> String { enabled ? text : text + "\n" + inUseHelp }
    /// The tooltip of a cell with no measurement.
    static let notMeasuredHelp = "Not measured yet"

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            row(.optimized, optimized)
            row(.standard, standard)
        }.frame(width: Self.width, height: Self.height, alignment: .topLeading)
            .fixedSize()
    }

    @ViewBuilder private func row(_ row: Row, _ offered: [String]) -> some View {
        let shown = Self.columns.filter(offered.contains)
        HStack(spacing: Self.labelGap) {
            Text(shown.isEmpty ? "" : row.title).font(Self.labelFont).lineLimit(1).fixedSize()
                .frame(width: Self.labelWidth, alignment: .leading)
            if let first = shown.first {
                let off = Set(shown.filter { unmeasured.contains(Cell(row, $0)) })
                TierSegments(tiers: shown, selected: selected?.row == row ? selected?.tier : nil, enabled: enabled, hot: hot, unmeasured: off,
                             help: { off.contains($0) ? Self.notMeasuredHelp : Self.tooltip(help(Cell(row, $0)), enabled: enabled) },
                             onSelect: { tier in if !off.contains(tier) { onSelect(Cell(row, tier)) } })
                    .frame(width: Self.segmentsWidth(shown.count), height: Self.segmentHeight)
                    .padding(.leading, CGFloat(Self.columns.firstIndex(of: first) ?? 0) * Self.cellWidth)
            }
        }.frame(width: Self.width, height: Self.segmentHeight, alignment: .leading)
    }
}

/// After a click inside a menu, redraw the hosting view on the next run-loop pass in the menu's tracking mode as well:
/// a SwiftUI table hosted in an NSMenuItem must show the new state while the menu stays open, whatever run-loop mode
/// SwiftUI's own update is scheduled in. Shared with ExactFastSwitch.swift and RowAction.swift.
enum HostRefresh {
    static func after(_ view: NSView) {
        var host: NSView = view
        while let parent = host.superview { host = parent }
        RunLoop.main.perform(inModes: [.common, .eventTracking, .default]) { [weak host] in
            guard let host else { return }
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
        }
    }
}

/// One row's segments: a regular NSSegmentedControl with per-segment tooltips.
private struct TierSegments: NSViewRepresentable {
    let tiers: [String]
    let selected: String?
    let enabled: Bool
    let hot: Bool
    var unmeasured: Set<String> = []
    let help: (String) -> String
    let onSelect: (String) -> Void

    final class Coordinator: NSObject {
        var parent: TierSegments
        init(_ parent: TierSegments) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.tiers.indices.contains(index) else { return }
            parent.onSelect(parent.tiers[index])
            HostRefresh.after(sender)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Always regular and always one segment high, whatever size the hosting environment pushes onto it.
    final class Control: NSSegmentedControl {
        override var controlSize: NSControl.ControlSize {
            get { super.controlSize }
            set { _ = newValue; super.controlSize = .regular } // any requested size stays regular
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: TierControl.segmentsWidth(segmentCount), height: TierControl.segmentHeight)
        }
        /// A loaded row rings its selected cell in white: on the accent-blue row a fill alone does not stand out.
        var ringsSelection = false { didSet { if ringsSelection != oldValue { needsDisplay = true } } }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard ringsSelection, selectedSegment >= 0, selectedSegment < segmentCount else { return }
            let x = CGFloat(selectedSegment) * (TierControl.cellWidth - 1)
            let cell = NSRect(x: x, y: 0, width: TierControl.cellWidth - 1, height: bounds.height).insetBy(dx: 1, dy: 1.5)
            let ring = NSBezierPath(roundedRect: cell, xRadius: 5, yRadius: 5)
            ring.lineWidth = 1.5
            NSColor.white.withAlphaComponent(isEnabled ? 0.95 : 0.5).setStroke()
            ring.stroke()
        }
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = Control()
        control.controlSize = .regular
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: TierControl.segmentsWidth(tiers.count), height: TierControl.segmentHeight)
    }

    private func update(_ control: NSSegmentedControl) {
        if control.segmentCount != tiers.count { control.segmentCount = tiers.count }
        control.controlSize = .regular   // SwiftUI may push its environment size onto hosted controls
        control.font = TierControl.font
        for (i, tier) in tiers.enumerated() {
            control.setLabel(tier, forSegment: i)
            control.setWidth(TierControl.cellWidth - 2, forSegment: i)
            control.setToolTip(help(tier), forSegment: i)
            control.setEnabled(!unmeasured.contains(tier), forSegment: i)
        }
        control.selectedSegment = selected.flatMap { tiers.firstIndex(of: $0) } ?? -1
        control.isEnabled = enabled
        // On a loaded (accent-blue) row an accent selection disappears into the row; a near-black selection with the
        // white label stands out from the light unselected cells there.
        control.selectedSegmentBezelColor = hot ? TierControl.hotSelection : nil
        (control as? Control)?.ringsSelection = hot
        control.needsDisplay = true
    }
}
