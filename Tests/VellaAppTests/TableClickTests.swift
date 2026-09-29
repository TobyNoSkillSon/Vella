import XCTest
import AppKit
import SwiftUI
@testable import Vella
@testable import VellaCore

@MainActor private final class ClickSpy: ModelRuntimeActions {
    var calls: [String] = []
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) { calls.append("load \(family.id) \(precision)") }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) { calls.append("reload \(family.id) \(precision)") }
    func unload(family: ModelFamily) { calls.append("unload \(family.id)") }
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool { false }
}

/// Clicks on the Models table's Precision segments, Path switch and action cell reach the controller and change the
/// row, through real mouse events on the hosted table (as in the menu), not only through the controller's API
/// (29 Sep: Toby's installed table ignored clicks).
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
    private func host(_ c: ModelsController, requestDelete: @escaping (ModelFamily) -> Void = { _ in }) -> (NSWindow, NSView) {
        let view = MenuTableHostingView(rootView: ModelTable(controller: c, requestDelete: requestDelete))
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
    /// Top to bottom (window coordinates grow upward).
    private func topDown<T: NSView>(_ views: [T]) -> [T] { views.sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY } }
    /// The families in the order their rows are drawn: Dictation, then Streaming, as sorted by default (WER ascending).
    private func familiesInRowOrder(_ c: ModelsController) -> [ModelFamily] {
        [RecognitionMode.dictation, .streaming].flatMap { ModelTable.rows(c, $0, sort: .wer, ascending: true) }.compactMap {
            if case .family(let f) = $0 { return f }; return nil
        }
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
    /// A SwiftUI button's click: down and up both sent to the window (no control tracking loop pulls the up).
    private func buttonClick(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            spin(0.05)
        }
        spin()
    }

    func testASegmentClickPreviewsThatPrecision() throws {
        let c = try controller()
        let (window, view) = host(c)
        let controls = all(NSSegmentedControl.self, in: view)
        XCTAssertEqual(controls.count, familiesInRowOrder(c).count, "one Precision control per model row")
        // Parakeet v3 Ultra: the one model offering 16, 8 and 4. Click its "8".
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        XCTAssertNil(c.previews[ultra.id])
        let three = try XCTUnwrap(controls.first { $0.segmentCount == 3 })
        let r = three.superview!.convert(three.alignmentRect(forFrame: three.frame), to: nil)
        click(window, at: NSPoint(x: r.minX + r.width / 3 * 1.5, y: r.midY))
        XCTAssertEqual(c.previews[ultra.id], ModelSelection(tier: .t8, path: .optimized, mode: .fast), "the click reached the controller: Optimized 8, Fast kept")
        XCTAssertEqual(three.selectedSegment, 1, "the row re-rendered with 8 selected")
        XCTAssertEqual(c.action(ultra), .get)
    }

    /// The whole switch is the hit target: a click on its word flips it, and so does a click on the pill.
    func testAClickAnywhereOnTheSwitchFlipsIt() throws {
        let c = try controller()
        let (window, view) = host(c)
        let order = familiesInRowOrder(c)
        let switches = topDown(all(SwitchView.self, in: view))
        XCTAssertEqual(switches.count, order.count, "one switch per model (every Vella model has an Optimized path)")
        let turboIndex = try XCTUnwrap(order.firstIndex { $0.id == "whisper-large-v3-turbo" })
        let turbo = order[turboIndex], s = switches[turboIndex]
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast)
        // On the word "Exact" (right of the pill, lower half).
        let r = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: r.minX + s.track.maxX + 16, y: r.minY + 6))
        XCTAssertEqual(c.currentSelection(turbo).mode, .exact, "a click on the label flipped it")
        XCTAssertEqual(s.position, .exact)
        // On the pill's upper end, then on the word "Exact" again: each click flips, wherever it lands.
        click(window, at: NSPoint(x: r.minX + s.track.midX, y: r.maxY - 4))
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast, "a click on the pill flipped it back")
        click(window, at: NSPoint(x: r.minX + s.track.maxX + 16, y: r.maxY - 6))
        XCTAssertEqual(c.currentSelection(turbo).mode, .exact, "a click on the word Fast flips too: the whole area toggles")
        // Greyed (Fast = Exact, Qwen): pinned up, a click does nothing.
        let qwenIndex = try XCTUnwrap(order.firstIndex { $0.id == "qwen3-asr-1.7b" })
        let qwen = order[qwenIndex], q = switches[qwenIndex]
        XCTAssertFalse(c.switchAvailable(qwen))
        XCTAssertEqual(q.position, .fast, "pinned up")
        let before = c.currentSelection(qwen)
        let qr = q.convert(q.bounds, to: nil)
        click(window, at: NSPoint(x: qr.midX, y: qr.midY))
        XCTAssertEqual(c.currentSelection(qwen), before)
    }

    /// The action cell: a click performs the row's action; a click on the trash glyph asks to delete.
    func testTheActionCellPerformsAndDeletes() throws {
        let c = try controller()
        let spy = ClickSpy(); c.actions = spy
        c.dictation.installed["Qwen3-ASR-1.7B-bf16"] = InstalledModel(path: "/fixture/q16")
        var deleted: [String] = []
        let (window, view) = host(c, requestDelete: { deleted.append($0.id) })
        let order = familiesInRowOrder(c)
        let actions = topDown(all(RowActionView.self, in: view))
        XCTAssertEqual(actions.count, order.count)
        let index = try XCTUnwrap(order.firstIndex { $0.id == "qwen3-asr-1.7b" })
        let a = actions[index]
        XCTAssertEqual(a.spec?.glyph, .onDisk)
        XCTAssertEqual(a.spec?.title, "Load")
        XCTAssertTrue(a.spec?.deletable ?? false)
        let r = a.convert(a.bounds, to: nil)
        click(window, at: NSPoint(x: r.minX + a.buttonRect.midX, y: r.midY))
        XCTAssertEqual(spy.calls, ["load qwen3-asr-1.7b BF16"], "a click on the cell performed Load")
        click(window, at: NSPoint(x: r.minX + a.trashRect.midX, y: r.midY))
        XCTAssertEqual(deleted, ["qwen3-asr-1.7b"], "a click on the trash glyph asked to delete")
        XCTAssertEqual(spy.calls.count, 1, "and did not also load")
        // Not downloaded: nothing to delete, the glyph is Get.
        let ultraIndex = try XCTUnwrap(order.firstIndex { $0.id == "parakeet-v3-ultra" })
        XCTAssertEqual(actions[ultraIndex].spec?.glyph, .get)
        XCTAssertFalse(actions[ultraIndex].spec?.deletable ?? true)
    }

    /// Hover inside a menu: the cell tracks the pointer with an `.activeAlways` tracking area (a menu's window is never
    /// key), and entering it turns the glyph into the button. A test cannot move the real pointer, so the tracking
    /// area's options are checked and its events are delivered as AppKit would.
    func testTheActionCellHoversWithAnAlwaysActiveTrackingArea() throws {
        let c = try controller()
        let (window, view) = host(c)
        let a = try XCTUnwrap(all(RowActionView.self, in: view).first)
        a.updateTrackingAreas()
        let area = try XCTUnwrap(a.trackingAreas.first { $0.owner === a })
        XCTAssertTrue(area.options.contains(.activeAlways), "active in a window that is not key (a menu's)")
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.inVisibleRect))
        let point = a.convert(NSPoint(x: a.bounds.midX, y: a.bounds.midY), to: nil)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        a.mouseEntered(with: enter)
        XCTAssertTrue(a.hovered)
        a.mouseExited(with: enter)
        XCTAssertFalse(a.hovered)
        XCTAssertEqual(a.toolTipText(at: NSPoint(x: a.buttonRect.midX, y: a.buttonRect.midY)).components(separatedBy: "\n").first, "Not downloaded")
    }

    /// The Capabilities heading opens the filter strip; a filter hides rows without its capability and the table's
    /// height follows (the menu resizes its item view).
    func testTheCapabilitiesHeadingOpensTheFilter() throws {
        let c = try controller()
        var resized = 0
        c.onLayoutChange = { resized += 1 }
        let (window, view) = host(c)
        let height = ModelTable.height(c)
        // The heading's centre: leading padding, row padding, Model column, spacing, then half the Capabilities column.
        let x = 6 + ModelTable.W.rowPadding + ModelTable.W.model + ModelTable.W.spacing + ModelTable.W.capabilities / 2
        buttonClick(window, at: NSPoint(x: x, y: view.frame.height - 6 - ModelTable.headerHeight / 2))
        XCTAssertTrue(c.filterOpen, "a click on the heading opened the strip")
        XCTAssertEqual(resized, 1)
        XCTAssertEqual(ModelTable.height(c), height + ModelTable.stripHeight)
        c.toggleFilter(.cjk)
        XCTAssertEqual(Set(c.visibleFamilies(.dictation).map(\.id)), ["qwen3-asr-1.7b", "qwen3-asr-0.6b", "whisper-large-v3", "whisper-large-v3-turbo"])
        XCTAssertTrue(c.visibleReferences(.dictation).isEmpty, "cloud rows state no capabilities")
        XCTAssertLessThan(ModelTable.height(c), height + ModelTable.stripHeight)
        XCTAssertEqual(c.filterableCapabilities, [.cjk], "every model here is multilingual: only CJK tells them apart")
    }
}
