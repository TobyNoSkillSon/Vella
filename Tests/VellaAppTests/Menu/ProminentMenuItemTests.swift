import AppKit
import XCTest
@testable import Vella

@MainActor private final class ActionSpy: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

/// Copy Last Transcript rests on a slightly lighter row (Toby, 15 Oct: "without hovering over it, it is slightly,
/// slightly lighter ... so that when I'm just skimming ... this is the thing that you click"), while keeping the native
/// highlight, the action, both titles and its icon. Only that item carries a view.
@MainActor final class ProminentMenuItemTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-prominent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func delegate() -> AppDelegate {
        _ = NSApplication.shared
        return AppDelegate(model: DictationController(configurationURL: root.appendingPathComponent("config.json")))
    }

    func testOnlyCopyLastTranscriptCarriesTheViewWithItsTitleIconAndAction() throws {
        let app = delegate()
        defer { app.model.shutdown() }
        app.model.lastText = "text"
        app.rebuildMenu()
        let item = try XCTUnwrap(app.menu.item(withTitle: "Copy Last Transcript"))
        let view = try XCTUnwrap(item.view as? ProminentMenuItemView)
        XCTAssertTrue(view.item === item)
        XCTAssertEqual(item.action.map(NSStringFromSelector), "copyLast")
        XCTAssertTrue(item.target === app)
        XCTAssertNotNil(item.image, "doc.on.doc, kept on the item for MenuImages and the view")
        XCTAssertEqual(view.frame.height, ProminentMenuItemView.height)
        XCTAssertEqual(view.accessibilityLabel(), "Copy Last Transcript")
        XCTAssertEqual(app.menu.items.filter { $0.view is ProminentMenuItemView }.count, 1)
        app.model.lastTranscriptIncomplete = true
        app.rebuildMenu()
        let incomplete = try XCTUnwrap(app.menu.item(withTitle: "Copy Recognized Text (Incomplete)"))
        XCTAssertEqual((incomplete.view as? ProminentMenuItemView)?.accessibilityLabel(), "Copy Recognized Text (Incomplete)")
        app.model.lastText = ""
        app.rebuildMenu()
        XCTAssertFalse(app.menu.items.contains { $0.view is ProminentMenuItemView }, "no item without a transcript")
    }

    /// Draws the view at the menu's width over the dark menu colour and samples a point of the row away from the text.
    private func sample(highlighted: Bool) throws -> (row: NSColor, menu: NSColor, title: NSColor) {
        let item = NSMenuItem(title: "Copy Last Transcript", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let view = ProminentMenuItemView(item: item)
        view.forcesHighlight = highlighted; view.rendersSelectionFill = highlighted
        let slot = NSView(frame: NSRect(x: 0, y: 0, width: 374, height: ProminentMenuItemView.height))
        slot.wantsLayer = true
        slot.layer?.backgroundColor = NSColor(srgbRed: 32 / 255, green: 32 / 255, blue: 32 / 255, alpha: 1).cgColor
        slot.appearance = NSAppearance(named: .darkAqua)
        view.setFrameSize(slot.bounds.size); slot.addSubview(view)
        let window = NSWindow(contentRect: slot.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = slot
        let rep = try XCTUnwrap(slot.bitmapImageRepForCachingDisplay(in: slot.bounds))
        slot.cacheDisplay(in: slot.bounds, to: rep)
        let s = CGFloat(rep.pixelsWide) / slot.bounds.width
        func at(_ x: CGFloat, _ y: CGFloat) throws -> NSColor { try XCTUnwrap(rep.colorAt(x: Int(x * s), y: Int(y * s))?.usingColorSpace(.sRGB)) }
        // The title's "C" stem: 1 pt into the title, mid-height.
        var title = try at(ProminentMenuItemView.titleX + 1, 12)
        for dx in stride(from: CGFloat(0.5), through: 3, by: 0.5) where title.brightnessComponent < 0.5 { title = try at(ProminentMenuItemView.titleX + dx, 12) }
        return (try at(300, 12), try at(2, 12), title)
    }
    func testRestsSlightlyLighterAndHighlightsInTheAccentWithWhiteText() throws {
        let rest = try sample(highlighted: false)
        let lift = rest.row.brightnessComponent - rest.menu.brightnessComponent
        XCTAssertGreaterThan(lift, 0.03, "visibly lighter at rest")
        XCTAssertLessThan(lift, 0.12, "but only slightly")
        XCTAssertGreaterThan(rest.title.brightnessComponent, 0.75, "the title in the label colour")
        let lit = try sample(highlighted: true)
        // The accent (blue by default; the bitmap's colour space shifts it a little).
        XCTAssertGreaterThan(lit.row.blueComponent, 0.8); XCTAssertGreaterThan(lit.row.blueComponent - lit.row.redComponent, 0.4)
        XCTAssertGreaterThan(lit.title.brightnessComponent, 0.9, "white title on the highlight")
    }

    func testAClickAndAnAccessibilityPressSendTheItemsAction() throws {
        let spy = ActionSpy()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Last Transcript", action: #selector(ActionSpy.fire(_:)), keyEquivalent: "")
        item.target = spy
        menu.addItem(item)
        let view = ProminentMenuItemView(item: item)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(spy.fired, 1)
        // A click through the window: down and up on the row.
        let slot = NSView(frame: NSRect(x: 0, y: 0, width: 374, height: ProminentMenuItemView.height))
        view.setFrameSize(slot.bounds.size); slot.addSubview(view)
        let window = NSWindow(contentRect: slot.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = slot
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000)); window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 120, y: 12), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        XCTAssertEqual(spy.fired, 2)
        item.isEnabled = false
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(spy.fired, 2, "a disabled item does nothing")
    }
}
