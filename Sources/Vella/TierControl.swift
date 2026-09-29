import AppKit
import SwiftUI

// The Models table's Precision control: one row of segments, `16 8 4` (bits per weight).
// Shared verbatim by Verdict, Vella and Vireo (like TooltipCell.swift): AppKit and SwiftUI only, no app types; plain
// values in, one callback out.
//
// - Only the precisions the model offers on the current path are listed; an absent one is omitted, never greyed.
//   Segments stay in fixed columns (16, 8, 4), so a model that lacks its leading precision starts one column in.
// - Exactly one segment is selected. Clicking one reports it; what that means (preview, deltas, Reload) is the app's
//   business. No segment is coloured as recommended.
// - `enabled == false` is the in-use interlock (dictating, speaking, rendering, judging, loading): the segments are
//   disabled and every segment's tooltip gains `inUseHelp`.
// - Segment tooltips are NSSegmentedControl per-segment tooltips: they work inside an NSMenu, where SwiftUI `.help`
//   never shows (TooltipCell.swift).
// - The geometry is explicit (a regular segmented control, `segmentHeight` × `cellWidth` per segment): a hosted
//   NSControl can take the environment's control size until its first update, so nothing here asks the control for
//   its size and the FIRST layout of a menu is already right.

struct TierControl: View {
    /// The column header and its tooltip (Toby, 29 Sep).
    static let title = "Precision"
    static let headerHelp = "Bits per weight. 16 = as released; 8 and 4 compressed on your Mac \u{2014} smaller, faster, slightly less accurate."
    /// The one interlock line, shared by the Precision segments and the Exact/Fast switch in every app.
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    /// Columns, highest precision first. Labels are bare: 16, 8, 4.
    static let columns = ["16", "8", "4"]
    /// A regular NSSegmentedControl's height (24 pt on macOS 26).
    static let segmentHeight: CGFloat = 24
    static let height: CGFloat = segmentHeight
    /// Width of one column (a bare two-digit label in a regular segment).
    static let cellWidth: CGFloat = 32
    /// Width of the segments: each segment is `cellWidth - 2` wide plus a 1 pt divider, less the outer one.
    static func segmentsWidth(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * (cellWidth - 1) - 1 }
    /// Three columns.
    static let width: CGFloat = CGFloat(columns.count) * cellWidth
    static var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    /// Precisions offered (a subset of `columns`, in any order).
    let tiers: [String]
    let selected: String?
    let enabled: Bool
    /// The model is loaded: the selected segment uses the accent colour.
    var hot = false
    /// Tooltip per segment (the app's flavour and "vs standard" lines).
    let help: (String) -> String
    let onSelect: (String) -> Void

    /// A segment's tooltip as shown: the app's text, plus the interlock line while in use.
    static func tooltip(_ text: String, enabled: Bool) -> String { enabled ? text : text + "\n" + inUseHelp }

    var body: some View {
        let shown = Self.columns.filter(tiers.contains)
        HStack(spacing: 0) {
            if let first = shown.first {
                TierSegments(tiers: shown, selected: selected, enabled: enabled, hot: hot,
                             help: { Self.tooltip(help($0), enabled: enabled) }, onSelect: onSelect)
                    .frame(width: Self.segmentsWidth(shown.count), height: Self.segmentHeight)
                    .padding(.leading, CGFloat(Self.columns.firstIndex(of: first) ?? 0) * Self.cellWidth)
            }
        }.frame(width: Self.width, height: Self.height, alignment: .leading)
            .fixedSize()
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

/// The segments: a regular NSSegmentedControl with per-segment tooltips.
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
            HostRefresh.after(sender)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Always regular and always one segment high, whatever size the hosting environment pushes onto it.
    final class Control: NSSegmentedControl {
        override var controlSize: NSControl.ControlSize {
            get { super.controlSize }
            set { super.controlSize = .regular }
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: TierControl.segmentsWidth(segmentCount), height: TierControl.segmentHeight)
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
        }
        control.selectedSegment = selected.flatMap { tiers.firstIndex(of: $0) } ?? -1
        control.isEnabled = enabled
        control.selectedSegmentBezelColor = hot ? .controlAccentColor : nil
        control.needsDisplay = true
    }
}
