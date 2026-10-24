import AppKit
import XCTest
@testable import Vella

@MainActor private final class ActionSpy: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

/// Copy Last Transcript rests on a slightly lighter row (Toby, 15 Oct: "without hovering over it, it is slightly,
/// slightly lighter ... so that when I'm just skimming ... this is the thing that you click"), and so does Support the
/// Developer (Toby, 24 Oct: "not highlighted white like the one in Heimdall"), while both keep the native highlight, the
/// action, the titles and the icon. Only those two items carry a view, so a row that goes missing fails by name.
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

    func testCopyLastTranscriptAndSupportCarryTheRowWithTheirTitleIconAndAction() throws {
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
        XCTAssertEqual(app.menu.items.filter { $0.view is ProminentMenuItemView }.map(\.title), ["Copy Last Transcript", "Support the Developer…"])
        let support = try XCTUnwrap(app.menu.item(withTitle: "Support the Developer…"))
        let supportView = try XCTUnwrap(support.view as? ProminentMenuItemView)
        XCTAssertTrue(supportView.item === support)
        XCTAssertEqual(support.action.map(NSStringFromSelector), "supportDeveloper")
        XCTAssertTrue(support.target === app)
        XCTAssertNotNil(support.image, "heart, kept on the item for MenuImages and the view")
        XCTAssertEqual(supportView.accessibilityLabel(), "Support the Developer…")
        app.model.lastTranscriptIncomplete = true
        app.rebuildMenu()
        let incomplete = try XCTUnwrap(app.menu.item(withTitle: "Copy Recognized Text (Incomplete)"))
        XCTAssertEqual((incomplete.view as? ProminentMenuItemView)?.accessibilityLabel(), "Copy Recognized Text (Incomplete)")
        app.model.lastText = ""
        app.rebuildMenu()
        XCTAssertNil(app.menu.item(withTitle: "Copy Last Transcript"), "no Copy item without a transcript to copy")
        XCTAssertEqual(app.menu.items.filter { $0.view is ProminentMenuItemView }.map(\.title), ["Support the Developer…"], "Support is always there")
    }

    /// Native icons and titles shift right by the state column while any item shows a checkmark (Toby's screenshot,
    /// 15 Oct: Launch at Login on, the row sat 14 pt left of its neighbours).
    func testFollowsTheStateColumnOfItsMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Last Transcript", action: nil, keyEquivalent: "")
        let view = ProminentMenuItemView(item: item)
        let login = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
        menu.addItem(item); menu.addItem(login)
        XCTAssertEqual(view.leading, 0)
        login.state = .on
        XCTAssertEqual(view.leading, ProminentMenuItemView.stateColumn)
    }

    /// Draws the view at the menu's width over the dark menu colour and samples a point of the row away from the text.
    private func sample(_ title: String = "Copy Last Transcript", icon: String = "doc.on.doc", highlighted: Bool) throws -> (row: NSColor, menu: NSColor, title: NSColor) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
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
        // The ink: the glyph pixel with the highest lowest channel. Brightness is no measure here: the blue highlight has
        // brightness 1.0, so the brightest pixel of the box would be the background, not the text.
        var title = try at(ProminentMenuItemView.titleX, 12)
        for dx in stride(from: CGFloat(0), through: 9, by: 0.5) {
            for y in stride(from: CGFloat(6), through: 18, by: 0.5) {
                let pixel = try at(ProminentMenuItemView.titleX + dx, y)
                if ink(pixel) > ink(title) { title = pixel }
            }
        }
        return (try at(300, 12), try at(2, 12), title)
    }
    /// How neutral and light a colour is: a white or grey ink has a high lowest channel, the blue highlight does not.
    private func ink(_ color: NSColor) -> CGFloat { min(color.redComponent, color.greenComponent, color.blueComponent) }
    func testRestsSlightlyLighterAndHighlightsInTheAccentWithWhiteText() throws {
        let rest = try sample(highlighted: false)
        let lift = rest.row.brightnessComponent - rest.menu.brightnessComponent
        XCTAssertGreaterThan(lift, 0.03, "visibly lighter at rest")
        XCTAssertLessThan(lift, 0.16, "but only slightly (Toby, 15 Oct: \"even lighter than it is right now\")")
        XCTAssertGreaterThan(ink(rest.title), 0.75, "the title in the label colour")
        let lit = try sample(highlighted: true)
        // The accent (blue by default; the bitmap's colour space shifts it a little).
        XCTAssertGreaterThan(lit.row.blueComponent, 0.8); XCTAssertGreaterThan(lit.row.blueComponent - lit.row.redComponent, 0.4)
        XCTAssertLessThan(ink(lit.row), 0.5, "the highlight is blue, not neutral")
        XCTAssertGreaterThan(ink(lit.title), 0.9, "white title on the highlight")
        XCTAssertGreaterThan(ink(lit.title) - ink(lit.row), 0.5, "the title stands out from the highlight, so the measure is not the background")
    }

    /// Support the Developer rests and highlights exactly as Copy Last Transcript does. Heimdall's Support row is the
    /// reference (its ProminentRow uses the same 13 % label fill; `RESTING_ALPHA` there is 0.13 too).
    func testSupportRestsAndHighlightsLikeCopyLastTranscript() throws {
        XCTAssertEqual(ProminentMenuItemView.restingAlpha, 0.13, accuracy: 0.0001)
        for lit in [false, true] {
            let copy = try sample(highlighted: lit)
            let support = try sample("Support the Developer…", icon: "heart", highlighted: lit)
            XCTAssertEqual(support.row.brightnessComponent, copy.row.brightnessComponent, accuracy: 0.01, lit ? "highlight" : "rest")
            XCTAssertEqual(support.row.redComponent, copy.row.redComponent, accuracy: 0.01, lit ? "highlight" : "rest")
            XCTAssertEqual(ink(support.title), ink(copy.title), accuracy: 0.05, lit ? "highlight title" : "rest title")
        }
        let rest = try sample("Support the Developer…", icon: "heart", highlighted: false)
        XCTAssertGreaterThan(rest.row.brightnessComponent - rest.menu.brightnessComponent, 0.03, "visibly lighter at rest")
        XCTAssertGreaterThan(ink(rest.title), 0.75, "Support's title in the label colour at rest")
        let lit = try sample("Support the Developer…", icon: "heart", highlighted: true)
        XCTAssertGreaterThan(ink(lit.title), 0.9, "Support's title white on the highlight")
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
