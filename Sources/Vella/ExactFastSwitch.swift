import AppKit
import SwiftUI

// The Models table's Exact/Fast switch: a vertical two-position switch beside the tier rows, up = Fast, down = Exact.
// Shared verbatim by Verdict, Vella and Vireo (like TooltipCell.swift): AppKit and SwiftUI only, no app types; plain
// values in, one callback out.
//
// - `available == false` greys it for a model where Fast measures the same as Exact (no inexact kernel qualified);
//   the knob then sits at Exact and a click does nothing.
// - `enabled == false` is the in-use interlock, with the same line as the tier rows (`TierControl.inUseHelp`).
// - An NSView draws it and carries the tooltip, because SwiftUI `.help` never shows inside an NSMenu.

struct ExactFastSwitch: View {
    enum Position: String { case exact, fast }

    /// The switch's tooltip (Toby, 29 Sep); state lines follow it on their own lines.
    static let help = "Exact: only kernels with output identical to Standard. Fast: adds chip-specific kernels within the model's own noise."
    static let sameHelp = "Fast measures the same as Exact for this model"
    static let inUseHelp = "Locked while the model is in use; a change applies at the next load"
    static let width: CGFloat = 44
    static let height: CGFloat = TierControl.height   // beside the two tier rows, same height

    let position: Position
    /// False: Fast measures identically to Exact for this model (greyed).
    let available: Bool
    /// False: the model is in use.
    let enabled: Bool
    let onChange: (Position) -> Void

    /// The tooltip as shown for a state.
    static func tooltip(available: Bool, enabled: Bool) -> String {
        [help, available ? nil : sameHelp, enabled ? nil : inUseHelp].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        SwitchRepresentable(position: available ? position : .exact, active: available && enabled, greyed: !available,
                            tooltip: Self.tooltip(available: available, enabled: enabled), onChange: onChange)
            .frame(width: Self.width, height: Self.height)
    }
}

private struct SwitchRepresentable: NSViewRepresentable {
    let position: ExactFastSwitch.Position
    let active: Bool
    let greyed: Bool
    let tooltip: String
    let onChange: (ExactFastSwitch.Position) -> Void

    func makeNSView(context: Context) -> SwitchView { let view = SwitchView(); update(view); return view }
    func updateNSView(_ view: SwitchView, context: Context) { update(view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwitchView, context: Context) -> CGSize? {
        CGSize(width: ExactFastSwitch.width, height: ExactFastSwitch.height)
    }
    private func update(_ view: SwitchView) {
        view.position = position; view.active = active; view.greyed = greyed; view.onChange = onChange
        if view.toolTip != tooltip { view.toolTip = tooltip }
        view.needsDisplay = true
    }
}

/// Track on the left (knob up = Fast, down = Exact), the two words beside it; the current one reads in the primary
/// colour. A click on the upper half chooses Fast, on the lower half Exact.
private final class SwitchView: NSView {
    var position: ExactFastSwitch.Position = .exact
    var active = true
    var greyed = false
    var onChange: ((ExactFastSwitch.Position) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let trackWidth: CGFloat = 11
    static let font = NSFont.systemFont(ofSize: 8.5)

    override func draw(_ dirtyRect: NSRect) {
        // Disabled or greyed: the whole switch at reduced opacity (system colours keep their own alpha).
        NSGraphicsContext.current?.cgContext.setAlpha(active ? 1 : 0.4)
        let track = NSRect(x: 1, y: 1, width: Self.trackWidth, height: bounds.height - 2)
        let path = NSBezierPath(roundedRect: track, xRadius: Self.trackWidth / 2, yRadius: Self.trackWidth / 2)
        (position == .fast && !greyed ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
        path.fill()
        let knobSize = Self.trackWidth - 3
        let knobY = position == .fast ? track.minY + 1.5 : track.maxY - 1.5 - knobSize
        let knob = NSBezierPath(ovalIn: NSRect(x: track.minX + 1.5, y: knobY, width: knobSize, height: knobSize))
        NSColor.white.setFill()
        knob.fill()
        for (word, which, y) in [("Fast", ExactFastSwitch.Position.fast, track.minY), ("Exact", .exact, track.maxY - 11)] {
            let color: NSColor = which == position ? .labelColor : .tertiaryLabelColor
            NSAttributedString(string: word, attributes: [.font: Self.font, .foregroundColor: color])
                .draw(at: NSPoint(x: track.maxX + 3, y: y))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard active else { return }
        let point = convert(event.locationInWindow, from: nil)
        let chosen: ExactFastSwitch.Position = point.y < bounds.midY ? .fast : .exact
        guard chosen != position else { return }
        position = chosen; needsDisplay = true
        onChange?(chosen)
        HostRefresh.after(self)
    }

    // Accessibility: a two-state switch reading "Fast" or "Exact".
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { "Exact or Fast" }
    override func accessibilityValue() -> Any? { position == .fast ? "Fast" : "Exact" }
    override func isAccessibilityEnabled() -> Bool { active }
    override func accessibilityPerformPress() -> Bool {
        guard active else { return false }
        position = position == .fast ? .exact : .fast; needsDisplay = true
        onChange?(position)
        return true
    }
}
