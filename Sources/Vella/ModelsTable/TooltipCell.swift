import AppKit
import SwiftUI

// Hover text for SwiftUI cells hosted inside an NSMenu (a table in an NSHostingView set as an NSMenuItem's view).
// Shared verbatim by Verdict, Vella and Vireo: AppKit and SwiftUI only, no app types.
//
// SwiftUI's `.help` never shows in that setting: while NSMenu tracks the mouse, only AppKit's tooltip manager runs,
// and it looks for an NSView with a `toolTip` under the pointer (the Bits segmented control, an NSSegmentedControl,
// is why its segment tooltips work). `.appKitTooltip(text)` puts a transparent NSView carrying that `toolTip` behind
// the cell, sized to the cell's frame; it draws nothing.
//
// Use it on non-interactive cells only (text, numbers, icons). AppKit hit-tests NSView subviews before the hosting
// view's own SwiftUI content, so a click on the cell reaches the tooltip view first; it forwards mouse events to the
// hosting view, but a SwiftUI Button or segmented control must not sit over it. Nested cells work: a cell's tooltip
// view is added before its content's, so an inner cell's own tooltip wins inside its rect.

/// A transparent, hit-testable NSView whose only job is to carry `toolTip` for AppKit's tooltip manager.
struct TooltipCell: NSViewRepresentable {
    /// nil or empty: no tooltip.
    var text: String?

    final class TooltipView: NSView {
        override var isOpaque: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func draw(_ dirtyRect: NSRect) {}
        // Not a control: a click lands where it would have without the tooltip view.
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
        override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
        override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
        override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
    }

    func makeNSView(context: Context) -> TooltipView {
        let view = TooltipView()
        view.toolTip = Self.trimmed(text)
        return view
    }
    func updateNSView(_ view: TooltipView, context: Context) {
        let next = Self.trimmed(text)
        if view.toolTip != next { view.toolTip = next }
    }
    /// The cell's whole frame, whatever SwiftUI proposes (an NSView has no intrinsic size of its own).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TooltipView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

extension View {
    /// AppKit hover text for a non-interactive cell in a menu-hosted SwiftUI view (see the note above). nil or an
    /// empty string means no tooltip.
    func appKitTooltip(_ text: String?) -> some View {
        background(TooltipCell(text: text))
    }
}
