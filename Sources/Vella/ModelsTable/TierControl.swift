import AppKit
import SwiftUI

// The Models table's Precision control: one row of three cells after a bolt, e.g. `⚡ [bf16][int8][int4]` (Toby, 15 Oct:
// "we should just have the lightning option. And then BF16, int 8, and int 4, like just one row"). Every model runs the
// optimized path and falls back to stock MLX by itself, so there is no path to choose.
// AppKit and SwiftUI only, no app types; plain values in, one callback out. (Vella's own variant: Verdict and Vireo
// still carry the two-row control this one replaced.)
//
// - The row always shows all three columns (16, 8, 4), equal width, labelled with the dtype that runs (`labels`, e.g.
//   bf16, fp16, int8, int4). A cell that cannot be chosen (a tier the catalog does not offer, a recipe the switch
//   position lacks, a cell without a measurement) is greyed in place, never hidden: the row never shifts. `unavailable`
//   maps it to its one-line reason, which is its tooltip; a click on it does nothing.
// - Exactly one cell is selected. Clicking a cell reports it; what that means (preview, deltas, Reload) is the app's
//   business.
// - Cell states (Toby, 15 Oct): not chosen, the Get button's neutral background; chosen, light blue; chosen and
//   recommended, gold; loaded, that same fill edged in white on the row's blue. `recommended`, not chosen: a gold
//   label and ring (Toby, 15 Oct: highlighted "in gold").
// - `warnings`: cells that run without the GPU's matrix hardware on this Mac carry the table's orange triangle after
//   their label; the warning is the first line of their tooltip.
// - `enabled == false` is the in-use interlock (dictating, loading): the row is disabled and every segment's tooltip
//   gains `inUseHelp`.
// - Segment tooltips are NSSegmentedControl per-segment tooltips: they work inside an NSMenu, where SwiftUI `.help`
//   never shows (TooltipCell.swift).
// - The geometry is explicit (a regular segmented control, `segmentHeight` high, `cellWidth` per column): a hosted
//   NSControl can take the environment's control size until its first update, so nothing here asks the control for its
//   size and the FIRST layout of a menu is already right.
// - Scale: every size here, in ExactFastSwitch.swift, RowAction.swift and the table is a base size times
//   `TableMetrics.scale`. The segments are the exception in mechanism, not in result: AppKit draws a regular segment's
//   bezel 24 pt high whatever its frame (the small size is 20 pt), so the segmented control keeps that natural geometry
//   (`natural`) as its own bounds and its frame is the scaled size. Bezel, labels, tint and ring scale with it, and hit
//   testing stays AppKit's own (a control's bounds are its coordinate system), unlike a scaled view around the hosting view.

/// The Models table's size (Toby, 30 Sep: about 10 % smaller in both directions, proportions kept): one factor for the
/// table and its shared controls. Lengths round to the half point; font and symbol sizes are exact.
enum TableMetrics {
    static let scale: CGFloat = 0.9
    /// A length (width, height, spacing, padding, radius): `base × scale` to the nearest half point.
    static func pt(_ base: CGFloat) -> CGFloat { (base * scale * 2).rounded() / 2 }
    /// A font or symbol point size: `base × scale`.
    static func font(_ base: CGFloat) -> CGFloat { base * scale }
}

struct TierControl: View {
    /// The column header and its tooltip.
    static let title = "Precision"
    static let headerHelp =
        "The running weight format: bf16 or fp16 from the checkpoint; int8 and int4 are quantized on your Mac to reduce weight size. Gold: recommended for this Mac. Speed, peak RAM and accuracy depend on the model and precision."
    /// The bolt's tooltip: true on every Mac, whichever path the worker ends up on.
    static let boltHelp = "Vella runs each model the fastest way this Mac supports and falls back to plain MLX by itself if that fails"
    /// The one interlock line, shared by the Precision segments and the Exact/Fast switch in every app.
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    /// Columns, highest precision first: 16, 8, 4 bits (the cells' identity; `labels` names them).
    static let columns = ["16", "8", "4"]
    /// A segmented control's own coordinate space (its bounds): a regular NSSegmentedControl as AppKit draws it, 24 pt
    /// high (macOS 26), 52 pt per column (a four-letter dtype and the warning triangle), labels at 13 pt medium. Its frame
    /// is this times `TableMetrics.scale`.
    enum Natural {
        static let segmentHeight: CGFloat = 24
        static let cellWidth: CGFloat = 52
        static func segmentsWidth(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * (cellWidth - 1) - 1 }
        static var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }
        /// The warning triangle's point size and its gap after the label.
        static let triangleSize: CGFloat = 10, triangleGap: CGFloat = 3
    }
    /// The row's height on screen (the regular 24 pt, scaled); the control's own height.
    static let segmentHeight: CGFloat = TableMetrics.pt(Natural.segmentHeight)
    static let height: CGFloat = segmentHeight
    /// Width of one column on screen. Every cell is this wide.
    static let cellWidth: CGFloat = TableMetrics.pt(Natural.cellWidth)
    /// The bolt's slot and the gap after it.
    static let iconWidth: CGFloat = TableMetrics.pt(24), iconGap: CGFloat = TableMetrics.pt(6)
    /// Width of the segments on screen: each segment is `cellWidth - 2` wide plus a 1 pt divider, less the outer one.
    static func segmentsWidth(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * (cellWidth - 1) - 1 }
    /// Bolt plus three columns.
    static let width: CGFloat = iconWidth + iconGap + CGFloat(columns.count) * cellWidth
    /// The segment labels in the control's own (natural) space; on screen 13 × scale.
    static var font: NSFont { Natural.font }

    /// The label of each column, in `columns` order: the dtype that runs (`bf16`, `int8`, `int4`); bare bits by default.
    var labels: [String] = columns
    let selected: String?
    let enabled: Bool
    /// Cells that cannot be chosen, each with its one-line reason (shown as its tooltip): greyed in place, never
    /// selectable. A cell becomes selectable as soon as the app stops listing it.
    var unavailable: [String: String] = [:]
    /// The model is loaded: the row sits on the loaded (blue) background.
    var hot = false
    /// The cell recommended for this Mac (gold).
    var recommended: String?
    /// Cells running without matrix hardware on this Mac → their warning (the triangle; the tooltip's first line).
    var warnings: [String: String] = [:]
    /// Tooltip per available cell (the app's flavour, delta and loss lines).
    let help: (String) -> String
    let onSelect: (String) -> Void

    /// A segment's tooltip as shown: the app's text, plus the interlock line while in use.
    static func tooltip(_ text: String, enabled: Bool) -> String { enabled ? text : text + "\n" + inUseHelp }

    var body: some View {
        HStack(spacing: Self.iconGap) {
            Self.bolt().frame(width: Self.iconWidth, height: Self.segmentHeight)
                .appKitTooltip(Self.boltHelp)
                .accessibilityHidden(true) // decorative: the path is not a choice
            TierSegments(
                tiers: Self.columns, labels: labels, selected: selected, enabled: enabled, hot: hot,
                unavailable: Set(unavailable.keys), recommended: recommended, warned: Set(warnings.keys),
                help: { tier in unavailable[tier] ?? Self.tooltip([warnings[tier], help(tier)].compactMap { $0 }.joined(separator: "\n"), enabled: enabled) },
                onSelect: { tier in if unavailable[tier] == nil { onSelect(tier) } }
            )
            .frame(width: Self.segmentsWidth(Self.columns.count), height: Self.segmentHeight)
        }.frame(width: Self.width, height: Self.height, alignment: .leading)
            .fixedSize()
    }

    /// The bolt's colour: ONE switch for the Precision bolt and the Exact/Fast knob (Toby, 15 Oct: "lightning should be
    /// like yellow. So that it's fast"). Flip it here and both follow.
    static let boltPalette: BoltPalette = .yellow
    enum BoltPalette {
        case yellow, blue
        /// The Precision row's bolt, on the dark menu and on the loaded (blue) row alike.
        var row: NSColor {
            switch self {
            // A lemon yellow, 54° 100 % 63 % (#FFE840): 7:1 on the loaded blue, 13:1 on the menu. The 30 Sep yellow
            // (#F4CE7B, 41°) read as a pale copy of the recommended gold (43°) beside it; this one reads as yellow.
            case .yellow: NSColor(srgbRed: 255 / 255, green: 232 / 255, blue: 64 / 255, alpha: 1)
            case .blue: NSColor(srgbRed: 142 / 255, green: 175 / 255, blue: 246 / 255, alpha: 1)
            }
        }
        /// The same hue deepened to read on the switch's white knob.
        var knob: NSColor {
            switch self {
            // 41° 90 % 38 % (#B8800A), 3.3:1 on white (the 30 Sep knob amber).
            case .yellow: NSColor(srgbRed: 184 / 255, green: 128 / 255, blue: 10 / 255, alpha: 1)
            // 221° 75 % 45 % (#1D53C9), 6.7:1 on white.
            case .blue: NSColor(srgbRed: 29 / 255, green: 83 / 255, blue: 201 / 255, alpha: 1)
            }
        }
    }
    static var boltTint: NSColor { boltPalette.row }
    /// The selected cell that is not the recommended one (Toby, 15 Oct: "it should actually turn the exact shade of blue
    /// that we currently have"): light blue, 221° 85 % 76 % (#8EAFF6), dark label.
    static let selectionBlue = NSColor(srgbRed: 142 / 255, green: 175 / 255, blue: 246 / 255, alpha: 1)
    /// Recommended for this Mac: a warm gold, ≥ 7:1 on the dark menu and ≥ 4.5:1 on the loaded row's blue.
    static let gold = NSColor(srgbRed: 236 / 255, green: 190 / 255, blue: 72 / 255, alpha: 1)
    /// The loaded cell's edge and the faint light around it.
    static let loadedEdge = NSColor.white
    static let loadedLight = NSColor.white.withAlphaComponent(0.35)
    /// The warning triangle's colour, as in the table's Speed column.
    static let warningColor = NSColor.systemOrange

    @ViewBuilder static func bolt() -> some View {
        Image(systemName: "bolt.fill").font(.system(size: TableMetrics.font(15), weight: .semibold)).foregroundStyle(Color(nsColor: boltTint))
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

/// The row's segments: a regular NSSegmentedControl with per-segment tooltips, drawn by hand (`Control.draw`).
private struct TierSegments: NSViewRepresentable {
    let tiers: [String]
    let labels: [String]
    let selected: String?
    let enabled: Bool
    let hot: Bool
    var unavailable: Set<String> = []
    var recommended: String?
    var warned: Set<String> = []
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

    /// Always regular and always one segment high, whatever size the hosting environment pushes onto it. Its bounds are
    /// the natural regular geometry (`TierControl.Natural`) whatever its frame: everything below draws in that space.
    final class Control: NSSegmentedControl {
        override var controlSize: NSControl.ControlSize {
            get { super.controlSize }
            set { _ = newValue; super.controlSize = .regular } // any requested size stays regular
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: TierControl.segmentsWidth(segmentCount), height: TierControl.segmentHeight)
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            naturalBounds()
        }
        /// Bounds = the natural size, so a frame of `TableMetrics.scale` of it scales the drawing and its hit testing.
        func naturalBounds() {
            let natural = NSSize(width: TierControl.Natural.segmentsWidth(segmentCount), height: TierControl.Natural.segmentHeight)
            if frame.width > 0, frame.height > 0, natural.width > 0, bounds.size != natural { setBoundsSize(natural) }
        }
        /// The row is loaded (blue background): a lighter track, the selected cell's fill edged in white.
        var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }
        var recommendedSegment = -1 { didSet { if recommendedSegment != oldValue { needsDisplay = true } } }
        var warnedSegments: Set<Int> = [] { didSet { if warnedSegments != oldValue { needsDisplay = true } } }

        static let triangle: NSImage? = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "runs without matrix hardware")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: TierControl.Natural.triangleSize, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [TierControl.warningColor])))

        override func draw(_ dirtyRect: NSRect) {
            // In use (disabled): the track and labels at half strength; the chosen cell's fill and loaded edge stay
            // opaque, since gold or blue at half strength over the loaded row's blue turns muddy.
            let dimmed: CGFloat = isEnabled ? 1 : 0.5
            let context = NSGraphicsContext.current?.cgContext
            context?.setAlpha(dimmed)
            let pitch = TierControl.Natural.cellWidth - 1
            // The track is the Get/Load button's own background (RowAction): a faint fill and a hairline, lighter on
            // the loaded row. No colour until a cell is chosen (Toby, 15 Oct: "something that we haven't chose is just
            // like the default color").
            let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(hot ? 0.20 : 0.10).setFill(); track.fill()
            NSColor.white.withAlphaComponent(hot ? 0.35 : 0.22).setStroke(); track.lineWidth = 1; track.stroke()
            for i in 0..<segmentCount {
                let cell = NSRect(x: CGFloat(i) * pitch, y: 0, width: pitch, height: bounds.height)
                let selected = i == selectedSegment
                let recommended = i == recommendedSegment
                let available = isEnabled(forSegment: i)
                let fill = cell.insetBy(dx: 1.5, dy: 2)
                if selected {
                    // Chosen: blue, or gold when it is the recommended cell; loaded: the same fill with a white edge
                    // (Toby, 15 Oct: "when we choose the recommended one it's yellow. And once we actually load it, it
                    // should be white").
                    context?.setAlpha(1)
                    (recommended && available ? TierControl.gold : TierControl.selectionBlue).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5).fill()
                    context?.setAlpha(dimmed)
                } else if i > 0, i - 1 != selectedSegment {
                    NSColor.white.withAlphaComponent(0.18).setFill()
                    NSRect(x: cell.minX - 0.5, y: cell.minY + 6, width: 1, height: cell.height - 12).fill()
                }
                let text = label(forSegment: i) ?? ""
                let color: NSColor =
                    !available ? NSColor.white.withAlphaComponent(0.3)
                    : selected ? NSColor(white: 0.1, alpha: 1)
                    : recommended ? TierControl.gold
                    : NSColor.white.withAlphaComponent(0.92)
                let font = recommended && available ? NSFont.systemFont(ofSize: TierControl.Natural.font.pointSize, weight: .semibold) : (self.font ?? TierControl.font)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (text as NSString).size(withAttributes: attributes)
                let warn = available && warnedSegments.contains(i) ? Self.triangle : nil
                let extra = warn.map { $0.size.width + TierControl.Natural.triangleGap } ?? 0
                let x = cell.midX - (size.width + extra) / 2
                (text as NSString).draw(at: NSPoint(x: x, y: cell.midY - size.height / 2), withAttributes: attributes)
                if let warn {
                    let w = warn.size
                    warn.draw(
                        in: NSRect(x: x + size.width + TierControl.Natural.triangleGap, y: cell.midY - w.height / 2, width: w.width, height: w.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                // Recommended, not chosen: a gold ring around the gold label. Loaded: a white edge on the chosen
                // cell's fill and a faint light just outside it, so the loaded cell reads as lit, not as another fill.
                if recommended && available && !selected {
                    let ring = NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1.5), xRadius: 5, yRadius: 5)
                    ring.lineWidth = 1.5
                    TierControl.gold.setStroke()
                    ring.stroke()
                } else if selected && hot {
                    context?.setAlpha(1)
                    defer { context?.setAlpha(dimmed) }
                    let edge = NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5)
                    edge.lineWidth = 1.5
                    TierControl.loadedEdge.setStroke()
                    edge.stroke()
                    let light = NSBezierPath(roundedRect: fill.insetBy(dx: -1.25, dy: -1.25), xRadius: 6.25, yRadius: 6.25)
                    light.lineWidth = 1
                    TierControl.loadedLight.setStroke()
                    light.stroke()
                }
            }
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
        control.controlSize = .regular // SwiftUI may push its environment size onto hosted controls
        control.font = TierControl.font
        for (i, tier) in tiers.enumerated() {
            control.setLabel(labels.indices.contains(i) ? labels[i] : tier, forSegment: i)
            control.setWidth(TierControl.Natural.cellWidth - 2, forSegment: i)
            control.setToolTip(help(tier), forSegment: i)
            control.setEnabled(!unavailable.contains(tier), forSegment: i)
        }
        (control as? Control)?.naturalBounds()
        control.selectedSegment = selected.flatMap { tiers.firstIndex(of: $0) } ?? -1
        control.isEnabled = enabled
        if let control = control as? Control {
            control.hot = hot
            control.recommendedSegment = recommended.flatMap { tiers.firstIndex(of: $0) } ?? -1
            control.warnedSegments = Set(warned.compactMap { tiers.firstIndex(of: $0) })
        }
        control.needsDisplay = true
    }
}
