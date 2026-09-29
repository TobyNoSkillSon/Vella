import XCTest
import AppKit
import SwiftUI
@testable import Vella
@testable import VellaCore

/// Clicks on the Models table's tier segments and Exact/Fast switch reach the controller and change the row, through
/// real mouse events on the hosted table (as in the menu), not only through the controller's API (29 Sep: Toby's
/// installed table ignored clicks).
@MainActor final class TableClickTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }

    private func controller() throws -> ModelsController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-click-\(UUID())")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("models-installed.json")
        let c = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                 streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                 benchmarksURL: resources.appendingPathComponent("benchmarks.json"))
        c.runtime = TableRuntime()
        return c
    }
    private func host(_ c: ModelsController) -> (NSWindow, NSView) {
        let view = MenuTableHostingView(rootView: ModelTable(controller: c))
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(c))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000)); window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        spin()
        return (window, view)
    }
    private func spin(_ seconds: TimeInterval = 0.2) {
        for mode in [RunLoop.Mode.default, .eventTracking] { RunLoop.current.run(mode: mode, before: Date().addingTimeInterval(seconds / 2)) }
    }
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ v: NSView) { if let t = v as? T { found.append(t) }; v.subviews.forEach(walk) }
        walk(view); return found
    }
    private func views(named name: String, in view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ v: NSView) { if String(describing: type(of: v)).contains(name) { found.append(v) }; v.subviews.forEach(walk) }
        walk(view); return found
    }
    /// A real click (down, then up queued for the control's tracking loop) at `point` in window coordinates.
    private func click(_ window: NSWindow, at point: NSPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        spin()
    }

    func testASegmentClickPreviewsThatCell() throws {
        let c = try controller()
        let (window, view) = host(c)
        let controls = all(NSSegmentedControl.self, in: view)
        XCTAssertGreaterThan(controls.count, 4, "tier rows hosted")
        // The Ultra row's Standard control: the family with a Standard 8. Click its "8".
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        XCTAssertNil(c.previews[ultra.id])
        let eights = controls.filter { $0.segmentCount == 3 }
        XCTAssertEqual(eights.count, 2, "Ultra's two 16/8/4 rows")
        let standard = try XCTUnwrap(eights.max { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY },
                                     "the lower row (window coordinates grow upward)")
        let r = standard.convert(standard.bounds, to: nil)
        let segment = r.width / 3
        click(window, at: NSPoint(x: r.minX + segment * 1.5, y: r.midY))
        XCTAssertEqual(c.previews[ultra.id]?.tier, .t8, "the click reached the controller")
        XCTAssertEqual(c.previews[ultra.id]?.path, .standard)
        XCTAssertEqual(standard.selectedSegment, 1, "the row re-rendered with Standard 8 selected")
        let optimized = try XCTUnwrap(eights.first { $0 !== standard })
        XCTAssertEqual(optimized.selectedSegment, -1, "the Optimized row lost its selection")
    }

    func testASwitchClickFlipsTheMode() throws {
        let c = try controller()
        let (window, view) = host(c)
        let switches = views(named: "SwitchView", in: view)
        XCTAssertFalse(switches.isEmpty)
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast)
        // Turbo's switch: live ones only (Qwen's are greyed); pick the one whose row is turbo by clicking each live
        // switch's lower half until turbo flips.
        for s in switches {
            let r = s.convert(s.bounds, to: nil)
            click(window, at: NSPoint(x: r.midX, y: r.minY + 4))   // lower half = Exact (window y grows upward)
        }
        XCTAssertEqual(c.currentSelection(turbo).mode, .exact, "a switch click reached the controller")
    }
}
