import AppKit

// MenuMock and TooltipSheet: generic drawing for documentation renders only.

/// Draws NSMenuItems the way macOS does in dark mode. A real NSMenu cannot be rendered offscreen.
final class MenuMock: NSView {
    let items: [NSMenuItem]
    init(items: [NSMenuItem], width: CGFloat) {
        self.items = items.filter { !$0.isHidden }
        // Wide enough for the longest title (menus size to their content).
        let font = NSFont.systemFont(ofSize: 13)
        let longest = self.items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width + (MenuMock.keyEquivalentText($0).isEmpty ? 0 : 50) }.max() ?? 0
        let width = max(width, ceil(longest) + 80)
        let height = self.items.reduce(CGFloat(12)) { $0 + ($1.isSeparatorItem ? 11 : $1.isSectionHeader ? 22 : 26) }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }
    required init?(coder: NSCoder) { nil }

    /// Draws `view` offscreen to `url` (PNG), then calls `done`.
    static func capture(_ view: NSView, to url: URL, done: @escaping () -> Void) {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear; window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless(); window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil); done()
        }
    }
    static func render(_ items: [NSMenuItem], width: CGFloat, to url: URL, done: @escaping () -> Void) {
        capture(MenuMock(items: items, width: width), to: url, done: done)
    }
    /// `<prefix><name>.png` for each named submenu of `menu`.
    static func renderSubmenus(of menu: NSMenu, titles: [(String, String)], into directory: URL, prefix: String = "", done: @escaping () -> Void) {
        let subs = titles.compactMap { title, name in menu.items.first(where: { $0.title == title })?.submenu.map { ($0.items, name) } }
        func next(_ index: Int) {
            guard index < subs.count else { done(); return }
            render(subs[index].0, width: 300, to: directory.appendingPathComponent("\(prefix)\(subs[index].1).png")) { next(index + 1) }
        }
        next(0)
    }
    /// Every item with a tooltip in the main menu and the named submenus: its title above the tooltip text as macOS
    /// shows it on hover (a static capture cannot hover).
    static func renderTooltips(of menu: NSMenu, submenus: [String], to url: URL, done: @escaping () -> Void) {
        var pairs: [(String, String)] = menu.items.compactMap { item in item.toolTip.map { (item.title, $0) } }
        for title in submenus {
            var seen = Set<String>()
            for item in menu.items.first(where: { $0.title == title })?.submenu?.items ?? [] {
                guard let tip = item.toolTip, seen.insert(tip).inserted else { continue }
                pairs.append(("\(title) → \(item.title)", tip))
            }
        }
        capture(TooltipSheet(pairs: pairs, width: 520), to: url, done: done)
    }

    static func keyEquivalentText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var text = ""
        if m.contains(.control) { text += "⌃" }
        if m.contains(.option) { text += "⌥" }
        if m.contains(.shift) { text += "⇧" }
        if m.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1).setFill(); panel.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke(); panel.lineWidth = 1; panel.stroke()
        var y = bounds.height - 6
        let attrs: (NSColor, CGFloat) -> [NSAttributedString.Key: Any] = { c, size in [.font: NSFont.systemFont(ofSize: size), .foregroundColor: c] }
        for item in items {
            if item.isSectionHeader {
                y -= 22
                NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.5)]).draw(at: NSPoint(x: 14, y: y + 4))
                continue
            }
            if item.isSeparatorItem {
                y -= 5.5
                NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(rect: NSRect(x: 14, y: y, width: bounds.width - 28, height: 1)).fill()
                y -= 5.5; continue
            }
            y -= 26
            let color: NSColor = item.isEnabled ? .white : NSColor.white.withAlphaComponent(0.4)
            let title = item.attributedTitle.map { NSAttributedString(string: $0.string, attributes: attrs(($0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) ?? color, 13)) }
                ?? NSAttributedString(string: item.title, attributes: attrs(color, 13))
            var x: CGFloat = 14
            if item.state == .on { NSAttributedString(string: "✓", attributes: attrs(color, 12)).draw(at: NSPoint(x: 8, y: y + 5)) }
            if items.contains(where: { $0.state == .on }) { x += 8 }
            if let image = item.image {
                let tinted = image.copy() as! NSImage; tinted.isTemplate = false
                let r = NSRect(x: x, y: y + 6, width: 14, height: 14)
                NSGraphicsContext.saveGraphicsState()
                tinted.lockFocus(); color.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                x += 22
            } else if items.contains(where: { $0.image != nil }) { x += 22 }
            title.draw(at: NSPoint(x: x, y: y + 5))
            if item.submenu != nil { NSAttributedString(string: "›", attributes: attrs(color, 15)).draw(at: NSPoint(x: bounds.width - 22, y: y + 4)) }
            let key = Self.keyEquivalentText(item)
            if !key.isEmpty {
                let text = NSAttributedString(string: key, attributes: attrs(NSColor.white.withAlphaComponent(0.5), 13))
                text.draw(at: NSPoint(x: bounds.width - 16 - text.size().width, y: y + 5))
            }
        }
    }
}

/// Menu item titles with their tooltip text in macOS's tooltip style (documentation renders only).
final class TooltipSheet: NSView {
    let blocks: [(NSAttributedString, NSAttributedString)]
    static let pad: CGFloat = 14, gap: CGFloat = 12
    init(pairs: [(String, String)], width: CGFloat) {
        blocks = pairs.map { title, tip in
            (NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.55)]),
             NSAttributedString(string: tip, attributes: [.font: NSFont.toolTipsFont(ofSize: 0), .foregroundColor: NSColor.white]))
        }
        let inner = width - 2 * Self.pad - 16
        let height = blocks.reduce(Self.pad) { sum, block in
            sum + 18 + ceil(block.1.boundingRect(with: NSSize(width: inner, height: 1000), options: [.usesLineFragmentOrigin]).height) + 10 + Self.gap
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let inner = bounds.width - 2 * Self.pad - 16
        var y = bounds.height - Self.pad
        for (title, tip) in blocks {
            y -= 16; title.draw(at: NSPoint(x: Self.pad, y: y)); y -= 2
            let h = ceil(tip.boundingRect(with: NSSize(width: inner, height: 1000), options: [.usesLineFragmentOrigin]).height)
            let bubble = NSRect(x: Self.pad, y: y - h - 10, width: inner + 16, height: h + 10)
            NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.23, alpha: 1).setFill(); NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
            NSColor.white.withAlphaComponent(0.15).setStroke(); NSBezierPath(roundedRect: bubble.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
            tip.draw(with: NSRect(x: bubble.minX + 8, y: bubble.minY + 5, width: inner, height: h), options: [.usesLineFragmentOrigin])
            y = bubble.minY - Self.gap
        }
    }
}
