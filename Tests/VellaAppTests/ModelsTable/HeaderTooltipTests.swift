import AppKit
import XCTest

@testable import Vella
@testable import VellaCore

/// Every column header carries an AppKit tooltip on the real menu item view (inside an NSMenu only AppKit's tooltip
/// manager runs; SwiftUI `.help` and accessibility hints never show there), and a click on a sortable header sorts.
@MainActor final class HeaderTooltipTests: XCTestCase {
    private func headerViews(_ root: NSView) -> [(title: String, tip: String?, frame: NSRect)] {
        var found: [(String, String?, NSRect)] = []
        func walk(_ v: NSView) {
            if let h = v as? SortHeaderView { found.append((h.title, h.toolTip, h.convert(h.bounds, to: root))) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
    private func tooltipViews(_ root: NSView) -> [(tip: String, frame: NSRect)] {
        var found: [(String, NSRect)] = []
        func walk(_ v: NSView) {
            if v is TooltipCell.TooltipView, let tip = v.toolTip, !tip.isEmpty { found.append((tip, v.convert(v.bounds, to: root))) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    func testEveryColumnHeaderHasATooltipOnTheRealView() throws {
        let state = try XCTUnwrap(TableRenderDelegate.states().first)
        let c = TableRenderDelegate.controller(state)
        let root = ModelsMenu(controller: c).modelItem()
        let item = try XCTUnwrap(root.submenu?.items.first?.view)
        let window = NSWindow(contentRect: item.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = item
        item.layoutSubtreeIfNeeded()
        // Sortable headers: their own view, with the tooltip on it.
        let sortable = headerViews(item)
        let expected: [String: String] = [
            "Model": ModelTable.modelHeaderHelp, "WER": ModelTable.werHeaderHelp, "Format": ModelTable.formatHeaderHelp,
            "Speed": ModelTable.speedHeaderHelp, "J / min": ModelTable.energyHeaderHelp, ModelTable.memoryTitle: ModelTable.memoryHeaderHelp
        ]
        XCTAssertEqual(Set(sortable.map(\.title)), Set(expected.keys))
        for header in sortable {
            XCTAssertEqual(header.tip, expected[header.title], header.title)
            XCTAssertFalse(header.tip?.isEmpty ?? true, "\(header.title) has a tooltip")
            XCTAssertGreaterThan(header.frame.width, 0, "\(header.title) laid out")
        }
        // The plain headers (Params, Precision): a TooltipCell in the header band with their text.
        let band = sortable.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        let plain = tooltipViews(item).filter { $0.frame.intersects(band) }.map(\.tip)
        XCTAssertTrue(plain.contains(ModelTable.paramsHeaderHelp), "Params")
        XCTAssertTrue(plain.contains(TierControl.headerHelp), "Precision")
        // AppKit finds the header's tooltip under the pointer: the header view itself is the hit view at its centre.
        for header in headerViews(item) {
            let centre = NSPoint(x: header.frame.midX, y: header.frame.midY)
            let hit = item.hitTest(item.convert(centre, to: item.superview))
            XCTAssertTrue(hit is SortHeaderView, "\(header.title): pointer over the header reaches its tooltip view, got \(String(describing: hit))")
        }
    }

    func testAClickOnAHeaderSorts() throws {
        let state = try XCTUnwrap(TableRenderDelegate.states().first { !$0.name.contains("pending") } ?? TableRenderDelegate.states().first)
        let c = TableRenderDelegate.controller(state)
        c.benchmarks.figuresPending = false
        let root = ModelsMenu(controller: c).modelItem()
        let item = try XCTUnwrap(root.submenu?.items.first?.view)
        let window = NSWindow(contentRect: item.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = item
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000)); window.orderFrontRegardless()
        item.layoutSubtreeIfNeeded()
        func header(_ title: String) throws -> SortHeaderView {
            var found: SortHeaderView?
            func walk(_ v: NSView) { if let h = v as? SortHeaderView, h.title == title { found = h }; v.subviews.forEach(walk) }
            walk(item)
            return try XCTUnwrap(found, title)
        }
        XCTAssertFalse(try header("Speed").active)
        let speed = try header("Speed")
        let point = speed.convert(NSPoint(x: speed.bounds.midX, y: speed.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        for mode in [RunLoop.Mode.default, .eventTracking] { RunLoop.current.run(mode: mode, before: Date().addingTimeInterval(0.15)) }
        item.layoutSubtreeIfNeeded()
        XCTAssertTrue(try header("Speed").active, "a real click on Speed sorts by it")
        XCTAssertFalse(try header("WER").active)
    }
}
