import AppKit
import SwiftUI

// The Models table's Precision control: two segment rows, Optimized (a bolt) above Standard (the MLX logo), each with
// the same three cells, e.g. `⚡ [bf16][int8][int4]` over `MLX [bf16][int8][int4]`.
// Shared verbatim by Verdict, Vella and Vireo (like TooltipCell.swift): AppKit and SwiftUI only, no app types; plain
// values in, one callback out.
//
// - Every row shows all three columns (16, 8, 4), equal width, labelled with the dtype that runs (`labels`, e.g. bf16,
//   fp16, int8, int4). A cell that cannot be chosen (a tier the presence gate removed, a recipe the switch position
//   lacks, a cell without a measurement) is greyed in place, never hidden: the grid never shifts. `unavailable` maps it
//   to its one-line reason, which is its tooltip; a click on it does nothing.
// - Exactly one cell is selected across both rows. Clicking a cell reports it; what that means (preview, deltas,
//   Reload) is the app's business. No cell is coloured as recommended.
// - The rows are named by icons in the text colour, each with a one-line tooltip naming its path: a plain bolt for
//   Optimized, the MLX logo (`mlx-logo.pdf` in the app's Resources, a template image; ml-explore/mlx, MIT) for Standard.
// - `enabled == false` is the in-use interlock (dictating, speaking, rendering, judging, loading): both rows are
//   disabled and every segment's tooltip gains `inUseHelp`.
// - Segment tooltips are NSSegmentedControl per-segment tooltips: they work inside an NSMenu, where SwiftUI `.help`
//   never shows (TooltipCell.swift).
// - The geometry is explicit (two regular segmented controls, `segmentHeight` each, `rowSpacing` apart, `cellWidth`
//   per column): a hosted NSControl can take the environment's control size until its first update, so nothing here
//   asks the control for its size and the FIRST layout of a menu already has both rows apart.

struct TierControl: View {
    enum Row: String, CaseIterable {
        case optimized, standard
        var title: String { self == .optimized ? "Optimized" : "Standard" }
        /// The row icon's tooltip: one line naming the path.
        var help: String {
            self == .optimized
                ? "Optimized: the same weights with custom kernels for this Mac's chip"
                : "Standard: the plain MLX runtime, same weights, no custom kernels"
        }
    }
    struct Cell: Hashable {
        var row: Row
        var tier: String
        init(_ row: Row, _ tier: String) { self.row = row; self.tier = tier }
    }

    /// The column header and its tooltip.
    static let title = "Precision"
    static let headerHelp =
        "The number format the weights run in: bf16 or fp16 as released; int8 and int4 compressed on your Mac \u{2014} smaller, faster, slightly less accurate."
    /// The selected cell's fill on a loaded row.
    static let hotSelection = NSColor(white: 0.1, alpha: 0.85)
    /// The one interlock line, shared by the Precision segments and the Exact/Fast switch in every app.
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    /// Columns, highest precision first: 16, 8, 4 bits (the cells' identity; `labels` names them).
    static let columns = ["16", "8", "4"]
    /// A regular NSSegmentedControl's height (24 pt on macOS 26).
    static let segmentHeight: CGFloat = 24
    /// Air between the Optimized and the Standard row.
    static let rowSpacing: CGFloat = 6
    /// Both rows: the control's own height, which the table row and the Exact/Fast switch beside it use.
    static let height: CGFloat = 2 * segmentHeight + rowSpacing
    /// Width of one column: room for a four-letter dtype (`bf16`, `int8`) in a regular segment. Every cell is this wide.
    static let cellWidth: CGFloat = 46
    /// The row icon's slot (the MLX logo at `logoHeight` is about 34 pt wide) and the gap after it.
    static let iconWidth: CGFloat = 36, iconGap: CGFloat = 8
    static let logoHeight: CGFloat = 11
    /// Width of a row's segments: each segment is `cellWidth - 2` wide plus a 1 pt divider, less the outer one.
    static func segmentsWidth(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * (cellWidth - 1) - 1 }
    /// Icon plus three columns.
    static let width: CGFloat = iconWidth + iconGap + CGFloat(columns.count) * cellWidth
    static var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    /// The Standard row's icon: the MLX logo as a template image, from the app's Resources (or ./Resources when run from
    /// the package, as in tests). Nil when the file is missing: the row then shows the letters MLX.
    static let mlxLogo: NSImage? = {
        let name = "mlx-logo.pdf"
        let places = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources").appendingPathComponent(name)
        ]
        for url in places.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) { image.isTemplate = true; return image }
        }
        return nil
    }()

    /// The label of each column, in `columns` order: the dtype that runs (`bf16`, `int8`, `int4`); bare bits by default.
    var labels: [String] = columns
    let selected: Cell?
    let enabled: Bool
    /// Cells that cannot be chosen, each with its one-line reason (shown as its tooltip): greyed in place, never
    /// selectable. A cell becomes selectable as soon as the app stops listing it.
    var unavailable: [Cell: String] = [:]
    /// The model is loaded: the selected segment uses the accent colour.
    var hot = false
    /// Tooltip per available cell (the app's flavour and "vs Standard" lines).
    let help: (Cell) -> String
    let onSelect: (Cell) -> Void

    /// A segment's tooltip as shown: the app's text, plus the interlock line while in use.
    static func tooltip(_ text: String, enabled: Bool) -> String { enabled ? text : text + "\n" + inUseHelp }
    /// The tooltip of a cell with no measurement (family rule, 29 Sep).
    static let notMeasuredHelp = "Not measured yet"

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            row(.optimized)
            row(.standard)
        }.frame(width: Self.width, height: Self.height, alignment: .topLeading)
            .fixedSize()
    }

    private func row(_ row: Row) -> some View {
        var off: [String: String] = [:]
        for tier in Self.columns { if let reason = unavailable[Cell(row, tier)] { off[tier] = reason } }
        return HStack(spacing: Self.iconGap) {
            Self.icon(row, hot: hot).frame(width: Self.iconWidth, height: Self.segmentHeight)
                .appKitTooltip(row.help)
                .accessibilityElement().accessibilityLabel(row.title)
            TierSegments(
                tiers: Self.columns, labels: labels, selected: selected?.row == row ? selected?.tier : nil, enabled: enabled, hot: hot,
                unavailable: Set(off.keys), tint: row == .optimized ? Self.boltColor(hot: hot) : nil,
                help: { off[$0] ?? Self.tooltip(help(Cell(row, $0)), enabled: enabled) },
                onSelect: { tier in if off[tier] == nil { onSelect(Cell(row, tier)) } }
            )
            .frame(width: Self.segmentsWidth(Self.columns.count), height: Self.segmentHeight)
        }.frame(width: Self.width, height: Self.segmentHeight, alignment: .leading)
    }

    /// The bolt's tint (Toby, 30 Sep): light blue on an unloaded row; on the loaded row, whose background is blue (hue
    /// ≈ 221°), a warm yellow at the complementary hue (≈ 41°) with matched lightness, so it sits on that blue.
    /// HSL: blue 221° 85 % 76 % (#8EAFF6), yellow 41° 85 % 72 % (#F4CE7B); both ≥ 5.8:1 on their row.
    static let boltTint = NSColor(srgbRed: 142 / 255, green: 175 / 255, blue: 246 / 255, alpha: 1)
    static let hotBoltTint = NSColor(srgbRed: 244 / 255, green: 206 / 255, blue: 123 / 255, alpha: 1)
    static func boltColor(hot: Bool) -> NSColor { hot ? hotBoltTint : boltTint }

    /// The row's icon: the bolt in its tint, or the MLX logo in the text colour.
    @ViewBuilder static func icon(_ row: Row, hot: Bool = false) -> some View {
        if row == .optimized {
            Image(systemName: "bolt.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(nsColor: boltColor(hot: hot)))
        } else if let logo = mlxLogo {
            Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit().frame(height: logoHeight)
        } else {
            Text("MLX").font(.system(size: 11, weight: .heavy))
        }
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
    let labels: [String]
    let selected: String?
    let enabled: Bool
    let hot: Bool
    var unavailable: Set<String> = []
    /// The Optimized row takes the bolt's tint (Toby, 30 Sep): a wash behind its cells and its labels in that colour,
    /// light blue on an unloaded row, the warm yellow on the loaded one. The Standard row stays neutral (nil).
    var tint: NSColor? = nil
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
        /// The Optimized row is drawn tinted as a whole (Toby, 30 Sep): the cells washed in the bolt's colour, the selected
        /// cell solid in it with a dark label, the others white, greyed cells dimmed. Stock drawing for the Standard row.
        var tint: NSColor? { didSet { if tint != oldValue { needsDisplay = true } } }
        static let hotWash = NSColor(srgbRed: 208 / 255, green: 162 / 255, blue: 81 / 255, alpha: 1)
        override func draw(_ dirtyRect: NSRect) {
            guard let tint else { return drawStock(dirtyRect) }
            NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.5)
            let pitch = TierControl.cellWidth - 1
            // On the loaded row the yellow must win over the blue behind it, so the wash is strong and labels are dark.
            let hotRow = ringsSelection
            // Yellow over the complementary blue greys out when blended, so the loaded row's wash is an opaque, deeper
            // shade of the same yellow (41° 62 % 58 %).
            (hotRow ? Self.hotWash : tint.withAlphaComponent(0.36)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
            for i in 0..<segmentCount {
                let cell = NSRect(x: CGFloat(i) * pitch, y: 0, width: pitch, height: bounds.height)
                let selected = i == selectedSegment
                if selected {
                    tint.setFill()
                    NSBezierPath(roundedRect: cell.insetBy(dx: 1.5, dy: 2), xRadius: 5, yRadius: 5).fill()
                } else if i > 0, i - 1 != selectedSegment {
                    (hotRow ? NSColor(white: 0.1, alpha: 0.25) : NSColor.white.withAlphaComponent(0.18)).setFill()
                    NSRect(x: cell.minX - 0.5, y: cell.minY + 6, width: 1, height: cell.height - 12).fill()
                }
                let text = label(forSegment: i) ?? ""
                let color: NSColor =
                    !isEnabled(forSegment: i)
                    ? (hotRow ? NSColor(white: 0.1, alpha: 0.35) : NSColor.white.withAlphaComponent(0.3))
                    : selected || hotRow ? NSColor(white: 0.1, alpha: 1) : NSColor.white.withAlphaComponent(0.92)
                let attributes: [NSAttributedString.Key: Any] = [.font: font ?? TierControl.font, .foregroundColor: color]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2), withAttributes: attributes)
            }
            if ringsSelection, selectedSegment >= 0 {
                let cell = NSRect(x: CGFloat(selectedSegment) * pitch, y: 0, width: pitch, height: bounds.height).insetBy(dx: 1, dy: 1.5)
                let ring = NSBezierPath(roundedRect: cell, xRadius: 5, yRadius: 5)
                ring.lineWidth = 1.5
                NSColor.white.withAlphaComponent(0.95).setStroke()
                ring.stroke()
            }
        }
        private func drawStock(_ dirtyRect: NSRect) {
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

    /// Draws an enabled segment's label in the row's tint; everything else (bezels, selection, greyed cells) is stock.
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
        control.controlSize = .regular // SwiftUI may push its environment size onto hosted controls
        control.font = TierControl.font
        for (i, tier) in tiers.enumerated() {
            control.setLabel(labels.indices.contains(i) ? labels[i] : tier, forSegment: i)
            control.setWidth(TierControl.cellWidth - 2, forSegment: i)
            control.setToolTip(help(tier), forSegment: i)
            control.setEnabled(!unavailable.contains(tier), forSegment: i)
        }
        control.selectedSegment = selected.flatMap { tiers.firstIndex(of: $0) } ?? -1
        control.isEnabled = enabled
        // On a loaded (accent-blue) row an accent selection disappears into the row; a near-black selection with the
        // white label stands out from the light unselected cells there.
        control.selectedSegmentBezelColor = hot ? TierControl.hotSelection : nil
        (control as? Control)?.ringsSelection = hot
        (control as? Control)?.tint = tint
        control.needsDisplay = true
    }
}
