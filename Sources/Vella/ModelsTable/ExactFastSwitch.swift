import AppKit
import SwiftUI

// The Models table's Exact/Fast switch: a vertical two-position switch, up = Fast, down = Exact, beside the Optimized
// row of the Precision control (it applies to that row only; Standard has no recipe to choose).
// Shared verbatim by Verdict, Vella and Vireo (like TooltipCell.swift): AppKit and SwiftUI only, no app types; plain
// values in, one callback out.
//
// - The whole control is the hit target: a click anywhere on it (the pill, the knob or either word) flips it.
// - `available == false` greys it for a model where Fast measures the same as Exact (no inexact kernel qualified):
//   the knob is pinned up (Fast, always on) and a click does nothing.
// - `enabled == false` is the in-use interlock, with the same line as the Precision segments (`TierControl.inUseHelp`).
// - `showsWords`: the words "Fast" and "Exact" beside the pill, or the pill alone (its column header then names it).
// - An NSView draws it and carries the tooltip, because SwiftUI `.help` never shows inside an NSMenu. Its size is
//   explicit (`width` × `height`), never asked of the environment, so the first frame of a menu is right.

struct ExactFastSwitch: View {
    enum Position: String { case exact, fast }

    /// THE variant: the words "Fast"/"Exact" beside the pill (true) or the pill alone (false).
    static let showsWords = true
    /// The column header: none beside the words (they name the positions), else the two positions, top first.
    static var title: String { showsWords ? "" : "Fast/Exact" }
    /// The switch's tooltip (Toby, 29 Sep); state lines follow it on their own lines.
    static let help = "Exact: only kernels with output identical to Standard. Fast: adds chip-specific kernels within the model's own noise."
    static let sameHelp = "Always on: Fast measures the same as Exact for this model"
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    /// The Exact position with no measured recipe: greyed, not selectable.
    static let exactNotMeasuredHelp = "Exact: not measured yet"
    static let pillWidth: CGFloat = 18
    static let width: CGFloat = showsWords ? 52 : pillWidth
    /// About one segment row high (28 pt beside a 24 pt Optimized row), so it reads as that row's.
    static let height: CGFloat = 28

    let position: Position
    /// False: Fast measures identically to Exact for this model (greyed, pinned up).
    let available: Bool
    /// False: the model is in use.
    let enabled: Bool
    /// False: no Exact recipe of this model has a measurement yet; the Exact position is greyed and a click does nothing
    /// (from Exact itself a click still goes to Fast).
    var exactAvailable = true
    let onChange: (Position) -> Void

    /// The tooltip as shown for a state.
    static func tooltip(available: Bool, enabled: Bool, exactAvailable: Bool = true) -> String {
        [help, available ? nil : sameHelp, available && !exactAvailable ? exactNotMeasuredHelp : nil, enabled ? nil : inUseHelp]
            .compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        SwitchRepresentable(
            position: available ? position : .fast, active: available && enabled,
            greyed: !available, exactUnavailable: available && !exactAvailable,
            tooltip: Self.tooltip(available: available, enabled: enabled, exactAvailable: exactAvailable), onChange: onChange
        )
        .frame(width: Self.width, height: Self.height)
    }
}

private struct SwitchRepresentable: NSViewRepresentable {
    let position: ExactFastSwitch.Position
    let active: Bool
    let greyed: Bool
    var exactUnavailable = false
    let tooltip: String
    let onChange: (ExactFastSwitch.Position) -> Void

    func makeNSView(context: Context) -> SwitchView { let view = SwitchView(); update(view); return view }
    func updateNSView(_ view: SwitchView, context: Context) { update(view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwitchView, context: Context) -> CGSize? {
        CGSize(width: ExactFastSwitch.width, height: ExactFastSwitch.height)
    }
    private func update(_ view: SwitchView) {
        view.position = position; view.active = active; view.greyed = greyed; view.exactUnavailable = exactUnavailable; view.onChange = onChange
        if view.toolTip != tooltip { view.toolTip = tooltip }
        view.needsDisplay = true
    }
}

/// Pill on the left (knob up = Fast, down = Exact), with `showsWords` the two words beside it; the current one reads in
/// the primary colour. A click anywhere in the view flips the position.
final class SwitchView: NSView {
    var position: ExactFastSwitch.Position = .exact
    var active = true
    var greyed = false
    /// The Exact position has no measurement: its word is dimmed; the switch stays on Fast.
    var exactUnavailable = false
    var onChange: ((ExactFastSwitch.Position) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let trackWidth: CGFloat = 14
    static let font = NSFont.systemFont(ofSize: 11)

    /// The pill's rectangle (the words sit to its right).
    var track: NSRect { NSRect(x: 2, y: 1, width: Self.trackWidth, height: bounds.height - 2) }

    override func draw(_ dirtyRect: NSRect) {
        // Locked while in use: the whole switch at reduced opacity (system colours keep their own alpha). Greyed (Fast =
        // Exact): a grey pill pinned up, so "always on" never reads as a live Fast.
        NSGraphicsContext.current?.cgContext.setAlpha(greyed ? 0.55 : active ? 1 : 0.4)
        let track = self.track
        let path = NSBezierPath(roundedRect: track, xRadius: Self.trackWidth / 2, yRadius: Self.trackWidth / 2)
        (position == .fast && !greyed ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        path.fill()
        let knobSize = Self.trackWidth - 4
        let knobY = position == .fast ? track.minY + 2 : track.maxY - 2 - knobSize
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: track.minX + 2, y: knobY, width: knobSize, height: knobSize)).fill()
        guard ExactFastSwitch.showsWords else { return }
        let lineHeight: CGFloat = 13
        for (word, which, y) in [("Fast", ExactFastSwitch.Position.fast, track.minY - 1), ("Exact", .exact, track.maxY - lineHeight)] {
            let color: NSColor = which == position ? .labelColor : which == .exact && exactUnavailable ? .quaternaryLabelColor : .tertiaryLabelColor
            NSAttributedString(string: word, attributes: [.font: Self.font, .foregroundColor: color])
                .draw(at: NSPoint(x: track.maxX + 5, y: y))
        }
    }

    /// The whole view is the hit target: pill, knob and words.
    override func mouseDown(with event: NSEvent) {
        guard active, !(exactUnavailable && position == .fast) else { return }
        flip()
        HostRefresh.after(self)
    }
    private func flip() {
        position = position == .fast ? .exact : .fast
        needsDisplay = true
        onChange?(position)
    }

    // Accessibility: a two-state switch reading "Fast" or "Exact".
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { "Path: Exact or Fast" }
    override func accessibilityValue() -> Any? { position == .fast ? "Fast" : "Exact" }
    override func isAccessibilityEnabled() -> Bool { active }
    override func accessibilityPerformPress() -> Bool {
        guard active, !(exactUnavailable && position == .fast) else { return false }
        flip()
        return true
    }
}
