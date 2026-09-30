import AppKit
import SwiftUI

// The Models table's action cell: a normal small bordered button at the row end, always visible, one word (Get, Load,
// Unload, Reload), fixed size, at the weight of the table's numbers; delete is a trash glyph beside it under the pointer.
// Written to be shared verbatim like TierControl.swift: AppKit and SwiftUI only, no app types; plain values in,
// callbacks out.
//
// - A pending change (`emphasized`, Reload) is the green button. While busy (a download's percentage, a load's "…")
//   the button shows that text and takes no click.
// - Hover inside an NSMenu (for the trash glyph only): menus track the mouse in their own run-loop mode and their
//   windows are never key, so SwiftUI's `.onHover` is not relied on. An NSTrackingArea with `.activeAlways` (active in
//   any window, key or not) and `.inVisibleRect` delivers mouseEntered/mouseExited to this view during menu tracking;
//   the view redraws itself at once (`display()`), not on SwiftUI's schedule. Menus cannot host context menus.
// - A click on the trash glyph deletes; anywhere else in the cell performs the action.
// - Tooltips are AppKit tooltip rects (SwiftUI `.help` never shows in a menu): the action's text on the cell, the
//   delete text on the trash glyph.
// - The geometry is explicit (`width` × `height`, `buttonRect`, `trashRect`), so the first frame of a menu is right.

struct RowAction: View {
    static let width: CGFloat = 96
    static let height: CGFloat = 28
    /// The button: wide enough for "Unload" and "Reload"; a small control's height.
    static let buttonWidth: CGFloat = 64, buttonHeight: CGFloat = 22
    /// Delete's tooltip.
    static let deleteHelp = "Delete these weights (asks first)"

    /// The button's title: Get, Load, Unload or Reload.
    let title: String
    /// A download's percentage or a load's "…": shown instead of the title; no click.
    var busyText: String?
    /// A pending change (Reload): the green button.
    var emphasized = false
    let enabled: Bool
    let deletable: Bool
    /// The row is the loaded one (accent-filled): the button uses the selected-text colour.
    var hot = false
    /// Render harness: draw the pointer over the cell (the trash glyph shows).
    var hovered = false
    let help: String
    let onPerform: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ActionRepresentable(spec: self).frame(width: Self.width, height: Self.height)
    }
}

private struct ActionRepresentable: NSViewRepresentable {
    let spec: RowAction
    func makeNSView(context: Context) -> RowActionView { let view = RowActionView(); view.spec = spec; view.forcedHover = spec.hovered; return view }
    func updateNSView(_ view: RowActionView, context: Context) { view.spec = spec; view.forcedHover = spec.hovered; view.needsDisplay = true }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowActionView, context: Context) -> CGSize? {
        CGSize(width: RowAction.width, height: RowAction.height)
    }
}

final class RowActionView: NSView, NSViewToolTipOwner {
    var spec: RowAction? { didSet { refreshToolTips() } }
    var forcedHover = false
    private(set) var hovered = false
    /// Green of the deltas' family, deep enough for white text on the loaded row.
    static let green = NSColor(calibratedRed: 0.20, green: 0.56, blue: 0.31, alpha: 1)
    static let titleFont = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var buttonRect: NSRect {
        NSRect(x: 2, y: (bounds.height - RowAction.buttonHeight) / 2, width: RowAction.buttonWidth, height: RowAction.buttonHeight)
    }
    var trashRect: NSRect { NSRect(x: RowAction.buttonWidth + 8, y: (bounds.height - 22) / 2, width: 22, height: 22) }
    private var showsHover: Bool { hovered || forcedHover }

    // MARK: Hover (see the note above)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
        if window != nil { display() }
    }

    // MARK: Click: trash deletes, anywhere else performs
    override func mouseDown(with event: NSEvent) {
        guard let spec, spec.busyText == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if spec.deletable, trashRect.insetBy(dx: -2, dy: -4).contains(point) {
            spec.onDelete()
        } else if spec.enabled {
            spec.onPerform()
        } else { return }
        HostRefresh.after(self)
    }

    // MARK: Tooltips
    private func refreshToolTips() {
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); refreshToolTips() }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let spec else { return "" }
        return spec.deletable && trashRect.contains(point) ? RowAction.deleteHelp : spec.help
    }
    /// The text a tooltip shows at a point (tests and renders).
    func toolTipText(at point: NSPoint) -> String { view(self, stringForToolTip: 0, point: point, userData: nil) }

    // MARK: Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let spec else { return }
        let text: NSColor = spec.hot ? .selectedMenuItemTextColor : .labelColor
        let quiet: NSColor = spec.hot ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.7) : .secondaryLabelColor
        let button = buttonRect
        let shape = NSBezierPath(roundedRect: button.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let context = NSGraphicsContext.current?.cgContext
        if let busy = spec.busyText {
            NSColor.white.withAlphaComponent(0.18).setStroke(); shape.lineWidth = 1; shape.stroke()
            drawCentred(busy, in: button, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: quiet)
        } else if spec.emphasized {
            context?.setAlpha(spec.enabled ? 1 : 0.5)
            Self.green.setFill(); shape.fill()
            drawCentred(spec.title, in: button, font: Self.titleFont, color: .white)
            context?.setAlpha(1)
        } else {
            // A small bordered button: a faint fill and a hairline border, lighter on the loaded row.
            context?.setAlpha(spec.enabled ? 1 : 0.4)
            NSColor.white.withAlphaComponent(spec.hot ? 0.20 : 0.10).setFill(); shape.fill()
            NSColor.white.withAlphaComponent(spec.hot ? 0.35 : 0.22).setStroke(); shape.lineWidth = 1; shape.stroke()
            drawCentred(spec.title, in: button, font: Self.titleFont, color: text)
            context?.setAlpha(1)
        }
        if showsHover && spec.deletable && spec.busyText == nil { drawSymbol("trash", in: trashRect, size: 13, color: quiet) }
    }
    private func drawCentred(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = s.size()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
    private func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // Accessibility: a button named by its action.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { spec.map { $0.busyText ?? $0.title } }
    override func accessibilityHelp() -> String? { spec?.help }
    override func isAccessibilityEnabled() -> Bool { spec.map { $0.enabled && $0.busyText == nil } ?? false }
    override func accessibilityPerformPress() -> Bool {
        guard let spec, spec.enabled, spec.busyText == nil else { return false }
        spec.onPerform(); return true
    }
    /// Delete, for VoiceOver (the trash glyph shows only under the pointer).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let spec, spec.deletable, spec.busyText == nil else { return nil }
        return [NSAccessibilityCustomAction(name: RowAction.deleteHelp) { spec.onDelete(); return true }]
    }
}
