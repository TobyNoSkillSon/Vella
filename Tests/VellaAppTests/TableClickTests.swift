import XCTest
import AppKit
import SwiftUI
@testable import Vella
@testable import VellaCore

@MainActor private final class ClickSpy: ModelRuntimeActions {
    var calls: [String] = []
    var selections: [ModelSelection] = []
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) { calls.append("load \(family.id) \(precision)"); selections.append(selection) }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) { calls.append("reload \(family.id) \(precision)"); selections.append(selection) }
    func unload(family: ModelFamily) { calls.append("unload \(family.id)") }
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool { false }
}

/// Clicks on the Models table's two Precision rows, the Exact/Fast switch and the action button reach the controller and change the
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

    /// Each model's two segment controls, Optimized then Standard, in row order (every shipped model has both rows).
    private func segmentRows(_ c: ModelsController, _ view: NSView) throws -> [String: (optimized: NSSegmentedControl, standard: NSSegmentedControl)] {
        let controls = topDown(all(NSSegmentedControl.self, in: view))
        let order = familiesInRowOrder(c)
        XCTAssertEqual(controls.count, 2 * order.count, "two Precision rows per model: Optimized above Standard")
        var rows: [String: (NSSegmentedControl, NSSegmentedControl)] = [:]
        for (i, family) in order.enumerated() where 2 * i + 1 < controls.count { rows[family.id] = (controls[2 * i], controls[2 * i + 1]) }
        return rows
    }
    /// A real click on segment `index` of a control.
    private func click(_ window: NSWindow, segment index: Int, of control: NSSegmentedControl) {
        let r = control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: nil)
        click(window, at: NSPoint(x: r.minX + (TierControl.cellWidth - 1) * (CGFloat(index) + 0.5), y: r.midY))
    }

    /// Both rows are directly clickable, and each cell shows its own numbers: Optimized 8, then Standard 16 (the
    /// reference: its own figures, no deltas), then Optimized 16 again.
    func testEveryCellOfBothRowsIsClickableAndShowsItsNumbers() throws {
        let c = try controller()
        let (window, view) = host(c)
        let rows = try segmentRows(c, view)
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let (optimized, standard) = try XCTUnwrap(rows[ultra.id])
        XCTAssertEqual(optimized.segmentCount, 3, "Ultra offers 16, 8 and 4 on Optimized")
        XCTAssertEqual(standard.segmentCount, 3, "and on Standard")
        XCTAssertNil(c.previews[ultra.id])
        click(window, segment: 1, of: optimized)
        XCTAssertEqual(c.previews[ultra.id], ModelSelection(tier: .t8, path: .optimized, mode: .fast), "Optimized 8, Fast kept")
        XCTAssertEqual(optimized.selectedSegment, 1, "the row re-rendered with 8 selected")
        XCTAssertEqual(standard.selectedSegment, -1, "one cell selected across both rows")
        let optimized8 = try XCTUnwrap(c.shownResult(ultra)?.speed_x)
        click(window, segment: 0, of: standard)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t16, path: .standard, mode: .fast), "a Standard cell, the switch position kept")
        XCTAssertEqual(standard.selectedSegment, 0)
        XCTAssertEqual(optimized.selectedSegment, -1)
        let standard16 = try XCTUnwrap(c.shownResult(ultra)?.speed_x)
        XCTAssertNotEqual(standard16, optimized8, "Standard 16 shows its own numbers")
        XCTAssertEqual(standard16, c.baseResult(ultra)?.speed_x)
        XCTAssertFalse(c.showsDeltas(ultra), "Standard 16 is the deltas' base: none under its figures")
        click(window, segment: 0, of: optimized)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        XCTAssertNotEqual(c.shownResult(ultra)?.speed_x, standard16, "back on Optimized: its numbers")
        XCTAssertTrue(c.showsDeltas(ultra))
        XCTAssertEqual(c.action(ultra), .get)
    }

    /// The Optimized row follows the switch (Exact lists only the precisions with an exact recipe); the Standard row
    /// keeps every precision Standard has.
    func testThePrecisionRowsUnderEachSwitchPosition() throws {
        let c = try controller()
        c.benchmarks.models["whisper-large-v3-turbo"]?.tiers[.t8]?.cells[.optimized_exact] = nil
        let (window, view) = host(c)
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        let order = familiesInRowOrder(c)
        let index = try XCTUnwrap(order.firstIndex { $0.id == turbo.id })
        var (optimized, standard) = try XCTUnwrap(try segmentRows(c, view)[turbo.id])
        XCTAssertEqual([optimized.segmentCount, standard.segmentCount], [2, 2], "Fast: 16 and 8 on both rows")
        click(window, segment: 1, of: optimized)
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, path: .optimized, mode: .fast))
        let s = topDown(all(SwitchView.self, in: view))[index]
        let r = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t16, path: .optimized, mode: .exact), "Exact moved 8 to 16")
        XCTAssertEqual(c.couplingNote(turbo), "Exact: 16 only, was 8")
        (optimized, standard) = try XCTUnwrap(try segmentRows(c, view)[turbo.id])
        XCTAssertEqual(optimized.segmentCount, 1, "Exact: the Optimized row offers 16 only")
        XCTAssertEqual(standard.segmentCount, 2, "the Standard row is not restricted by the switch")
        click(window, segment: 1, of: standard)
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, path: .standard, mode: .exact), "Standard 8 stays reachable under Exact")
        XCTAssertNil(c.couplingNote(turbo), "a cell click ends the note")
    }

    /// The whole switch is the hit target: a click on its right part (the words, when shown), on the pill or anywhere
    /// else flips it.
    func testAClickAnywhereOnTheSwitchFlipsIt() throws {
        let c = try controller()
        let (window, view) = host(c)
        let order = familiesInRowOrder(c)
        let switches = topDown(all(SwitchView.self, in: view))
        XCTAssertEqual(switches.count, order.count, "one switch per model (every Vella model has an Optimized path)")
        let turboIndex = try XCTUnwrap(order.firstIndex { $0.id == "whisper-large-v3-turbo" })
        let turbo = order[turboIndex], s = switches[turboIndex]
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast)
        // The lower right corner (the word "Exact" when the words show).
        let r = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: r.maxX - 3, y: r.minY + 6))
        XCTAssertEqual(c.currentSelection(turbo).mode, .exact, "a click on the lower right flipped it")
        XCTAssertEqual(s.position, .exact)
        // On the pill's upper end, then the upper right corner: each click flips, wherever it lands.
        click(window, at: NSPoint(x: r.minX + s.track.midX, y: r.maxY - 4))
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast, "a click on the pill flipped it back")
        click(window, at: NSPoint(x: r.maxX - 3, y: r.maxY - 6))
        XCTAssertEqual(c.currentSelection(turbo).mode, .exact, "the upper right flips too: the whole area toggles")
        // From a Standard cell, the switch moves the row to that precision's Optimized cell.
        c.select(turbo, tier: .t8, path: .standard)
        click(window, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, path: .optimized, mode: .fast))
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

    /// The action button: always visible with one word; a click performs it; a Standard cell on a loaded model turns it
    /// into the green Reload, which reloads on Standard; a click on the trash glyph asks to delete.
    func testTheActionButtonPerformsReloadsAndDeletes() throws {
        let c = try controller()
        let spy = ClickSpy(); c.actions = spy
        c.dictation.installed["Qwen3-ASR-1.7B-bf16"] = InstalledModel(path: "/fixture/q16")
        var deleted: [String] = []
        let (window, view) = host(c, requestDelete: { deleted.append($0.id) })
        let order = familiesInRowOrder(c)
        let actions = topDown(all(RowActionView.self, in: view))
        XCTAssertEqual(actions.count, order.count)
        XCTAssertTrue(actions.allSatisfy { $0.frame.size == NSSize(width: RowAction.width, height: RowAction.height) }, "fixed size")
        let index = try XCTUnwrap(order.firstIndex { $0.id == "qwen3-asr-1.7b" })
        let qwen = order[index], a = actions[index]
        XCTAssertEqual(a.spec?.title, "Load")
        XCTAssertTrue(a.spec?.deletable ?? false)
        let r = a.convert(a.bounds, to: nil)
        click(window, at: NSPoint(x: r.minX + a.buttonRect.midX, y: r.midY))
        XCTAssertEqual(spy.calls, ["load qwen3-asr-1.7b BF16"], "a click on the button performed Load")
        click(window, at: NSPoint(x: r.minX + a.trashRect.midX, y: r.midY))
        XCTAssertEqual(deleted, ["qwen3-asr-1.7b"], "a click on the trash glyph asked to delete")
        XCTAssertEqual(spy.calls.count, 1, "and did not also load")
        // Loaded on Optimized 16: Unload; its Standard 16 cell previewed: the green Reload, which reloads on Standard.
        c.runtime = TableRuntime(loaded: ["qwen3-asr-1.7b": LoadedFamily(precision: "BF16", engine: "optimized",
                                                                          selection: ModelSelection(tier: .t16, path: .optimized, mode: .fast))])
        spin()
        func button() -> RowActionView { topDown(all(RowActionView.self, in: view))[index] }
        XCTAssertEqual(button().spec?.title, "Unload")
        let standard = try XCTUnwrap(try segmentRows(c, view)[qwen.id]?.standard)
        click(window, segment: 0, of: standard)
        XCTAssertEqual(button().spec?.title, "Reload")
        XCTAssertEqual(button().spec?.emphasized, true, "green")
        let b = button().convert(button().bounds, to: nil)
        click(window, at: NSPoint(x: b.minX + button().buttonRect.midX, y: b.midY))
        XCTAssertEqual(spy.calls.last, "reload qwen3-asr-1.7b BF16")
        XCTAssertEqual(spy.selections.last, ModelSelection(tier: .t16, path: .standard, mode: .fast), "Standard, as VELLA_RECIPE=standard")
        // Not downloaded: Get, nothing to delete.
        let ultraIndex = try XCTUnwrap(order.firstIndex { $0.id == "parakeet-v3-ultra" })
        XCTAssertEqual(actions[ultraIndex].spec?.title, "Get")
        XCTAssertFalse(actions[ultraIndex].spec?.deletable ?? true)
    }

    /// Hover inside a menu: the cell tracks the pointer with an `.activeAlways` tracking area (a menu's window is never
    /// key), and entering it shows the trash glyph. A test cannot move the real pointer, so the tracking
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
