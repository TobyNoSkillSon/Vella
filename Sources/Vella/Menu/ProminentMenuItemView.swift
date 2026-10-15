import AppKit

// The one menu item that rests on a slightly lighter background (Toby, 15 Oct, on Copy Last Transcript: "without
// hovering over it, it is slightly, slightly lighter ... so that when I'm just skimming ... this is the thing that you
// click when you want the last transcript"). AppKit has no resting background for a native item, so the item carries
// this view, which draws what the native item draws, at the native geometry:
//
// - Title and icon come from the item (`title`, `image`) at every draw, so the title variants and the macOS 27 image
//   rule (MenuImages) keep working on the item itself.
// - Under the pointer or keyboard selection the item is highlighted by the system's own selection material
//   (NSVisualEffectView `.selection`, emphasized): the same blue as every other row. AppKit redraws an item's view
//   when its highlight changes.
// - A click performs the item's action after the menu closes, as a native item does; Return on a highlighted item and
//   accessibility presses go through NSMenu's own `performActionForItem(at:)`.
// - Geometry measured from the real macOS 26 menu (docs/images/menu-current.png, 2×): rows 24 pt, icon centred 23 pt
//   from the leading edge, title at 38.5 pt, content margins 16 pt. When any item in the menu shows a checkmark
//   (Launch at Login on), AppKit reserves a state column and shifts every native icon and title right by
//   `stateColumn`; this view follows (Toby's screenshot, 15 Oct: the row sat 14 pt left of its neighbours).

@MainActor final class ProminentMenuItemView: NSView {
    static let height: CGFloat = 24
    static let iconCentre: CGFloat = 23, titleX: CGFloat = 38.5, trailing: CGFloat = 16, stateColumn: CGFloat = 14
    /// The highlight's (and the resting background's) inset from the menu's edges, and its corner radius.
    static let inset: CGFloat = 5, radius: CGFloat = 6
    /// The resting background: the label colour at a few percent, slightly lighter than the menu in dark mode.
    static let restingAlpha: CGFloat = 0.13
    static var font: NSFont { .menuFont(ofSize: 0) }

    private let selection = NSVisualEffectView()
    /// The item this view draws (AppKit's `enclosingMenuItem` exists only while the menu shows the view).
    private(set) weak var item: NSMenuItem?
    /// Renders: drawn highlighted without a menu tracking it. Offscreen drawing cannot show the system's selection
    /// material, so renders fill the accent colour in its place (`rendersSelectionFill`).
    var forcesHighlight = false { didSet { needsDisplay = true } }
    var rendersSelectionFill = false

    /// Becomes `item`'s view.
    init(item: NSMenuItem) {
        let width = Self.stateColumn + Self.titleX + ceil((item.title as NSString).size(withAttributes: [.font: Self.font]).width) + Self.trailing + 24
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = [.width]
        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.blendingMode = .behindWindow
        selection.wantsLayer = true
        selection.layer?.cornerRadius = Self.radius
        selection.layer?.masksToBounds = true
        selection.isHidden = true
        addSubview(selection)
        self.item = item
        item.view = self
    }
    required init?(coder: NSCoder) { nil }

    private var menuItem: NSMenuItem? { item ?? enclosingMenuItem }
    var highlighted: Bool { forcesHighlight || menuItem?.isHighlighted == true }
    /// The rounded row both backgrounds fill.
    var rowRect: NSRect { bounds.insetBy(dx: Self.inset, dy: 0) }
    /// The native content shift: the state column, present while any item in the menu has a state.
    var leading: CGFloat { menuItem?.menu?.items.contains { $0.state != .off } == true ? Self.stateColumn : 0 }

    override func viewWillDraw() {
        super.viewWillDraw()
        selection.frame = rowRect
        selection.isHidden = !highlighted || rendersSelectionFill
    }
    override func draw(_ dirtyRect: NSRect) {
        let item = menuItem
        let lit = highlighted
        if lit && rendersSelectionFill {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: rowRect, xRadius: Self.radius, yRadius: Self.radius).fill()
        } else if !lit {
            NSColor.labelColor.withAlphaComponent(Self.restingAlpha).setFill()
            NSBezierPath(roundedRect: rowRect, xRadius: Self.radius, yRadius: Self.radius).fill()
        }
        let enabled = item?.isEnabled ?? true
        let color: NSColor = lit ? .selectedMenuItemTextColor : enabled ? .labelColor : .tertiaryLabelColor
        if let image = item?.image.map(Self.menuSized), let tinted = Self.tinted(image, color) {
            let size = tinted.size
            tinted.draw(
                in: NSRect(x: leading + Self.iconCentre - size.width / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
        let title = NSAttributedString(string: item?.title ?? "", attributes: [.font: Self.font, .foregroundColor: color])
        let size = title.size()
        title.draw(at: NSPoint(x: leading + Self.titleX, y: (bounds.height - size.height) / 2))
    }
    /// A symbol at the size a native menu row draws it (10 pt wide for doc.on.doc in the real menu).
    static func menuSized(_ image: NSImage) -> NSImage {
        image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .small)) ?? image
    }
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage? {
        guard let copy = image.copy() as? NSImage else { return nil }
        copy.isTemplate = false
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform()
    }
    /// Closes the menu, then sends the item's action through NSMenu, as a native click does.
    func perform() {
        guard let item = menuItem, item.isEnabled, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityLabel() -> String? { menuItem?.title }
    override func accessibilityPerformPress() -> Bool { perform(); return true }
}
