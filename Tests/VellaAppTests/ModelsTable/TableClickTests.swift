import XCTest
import AppKit
import SwiftUI
@testable import Vella
@testable import VellaCore

@MainActor private final class ClickSpy: ModelRuntimeActions {
    var calls: [String] = []
    var selections: [ModelSelection] = []
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {
        calls.append("load \(family.id) \(precision)"); selections.append(selection)
    }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {
        calls.append("reload \(family.id) \(precision)"); selections.append(selection)
    }
    func unload(family: ModelFamily) { calls.append("unload \(family.id)") }
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool { false }
}

/// Clicks on the Models table's two Precision rows, the Exact/Fast switch and the action button reach the controller and change the
/// row, through real mouse events on the hosted table (as in the menu), not only through the controller's API
/// (29 Sep: Toby's installed table ignored clicks).
@MainActor final class TableClickTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }

    // A synthetic pre-measurement fixture keeps the selection regressions independent of release numbers.
    private func controller() throws -> ModelsController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-click-\(UUID())")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("models-installed.json")
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SwitchRuleFixture.json"))
        c.runtime = TableRuntime()
        return c
    }
    /// As after a night window: every Exact cell of `id` measured (a copy of its Fast numbers), so Exact is selectable.
    private func measureExact(_ c: ModelsController, _ id: String) {
        guard var m = c.benchmarks.models[id] else { return }
        for (tier, var t) in m.tiers {
            if let fast = t.cells[.optimized_fast], var exact = t.cells[.optimized_exact], exact.isPending {
                exact.result = fast.result; exact.measured = fast.measured; t.cells[.optimized_exact] = exact
            }
            m.tiers[tier] = t
        }
        c.benchmarks.models[id] = m
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
    /// A real click at `point` in window coordinates: down, then up queued for the control's tracking loop (macOS 26,
    /// where the segmented control receives the down). On macOS 27 the hosting view receives the down and no tracking
    /// loop pulls the up, so a still-queued up goes to the window, as the window server delivers a real click.
    private func click(_ window: NSWindow, at point: NSPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { window.sendEvent(up) }
        spin()
    }
    /// A SwiftUI button's click: down and up both sent to the window (no control tracking loop pulls the up).
    private func buttonClick(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
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
        XCTAssertEqual((0..<3).map { optimized.label(forSegment: $0) }, ["bf16", "int8", "int4"], "the dtype that runs")
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
        measureExact(c, "whisper-large-v3-turbo")
        c.benchmarks.models["whisper-large-v3-turbo"]?.tiers[.t8]?.cells[.optimized_exact] = nil
        let (window, view) = host(c)
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        let order = familiesInRowOrder(c)
        let index = try XCTUnwrap(order.firstIndex { $0.id == turbo.id })
        var (optimized, standard) = try XCTUnwrap(try segmentRows(c, view)[turbo.id])
        XCTAssertEqual([optimized.segmentCount, standard.segmentCount], [3, 3], "every row keeps its three cells")
        XCTAssertEqual((0..<3).map { standard.label(forSegment: $0) }, ["fp16", "int8", "int4"], "Whisper's 16 is fp16")
        XCTAssertEqual((0..<3).map { optimized.isEnabled(forSegment: $0) }, [true, true, false], "Fast: fp16 and int8; int4 removed by the gate, greyed")
        click(window, segment: 1, of: optimized)
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, path: .optimized, mode: .fast))
        let s = topDown(all(SwitchView.self, in: view))[index]
        let r = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t16, path: .optimized, mode: .exact), "Exact moved 8 to 16")
        XCTAssertEqual(c.couplingNote(turbo), "Exact: fp16 only, was int8")
        (optimized, standard) = try XCTUnwrap(try segmentRows(c, view)[turbo.id])
        XCTAssertEqual([optimized.segmentCount, standard.segmentCount], [3, 3], "the grid never shifts")
        XCTAssertEqual((0..<3).map { optimized.isEnabled(forSegment: $0) }, [true, false, false], "Exact: the Optimized row offers fp16 only")
        XCTAssertEqual(optimized.toolTip(forSegment: 1), "No Exact recipe at int8; Fast offers it")
        XCTAssertEqual((0..<3).map { standard.isEnabled(forSegment: $0) }, [true, true, false], "the Standard row is not restricted by the switch")
        let exact16 = c.currentSelection(turbo)
        click(window, segment: 1, of: optimized)
        XCTAssertEqual(c.currentSelection(turbo), exact16, "a real click on the greyed Optimized int8 changes nothing")
        click(window, segment: 1, of: standard)
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, path: .standard, mode: .exact), "Standard 8 stays reachable under Exact")
        XCTAssertNil(c.couplingNote(turbo), "a cell click ends the note")
    }

    /// The whole switch is the hit target: a click on its right part (the words, when shown), on the pill or anywhere
    /// else flips it.
    func testAClickAnywhereOnTheSwitchFlipsIt() throws {
        let c = try controller()
        measureExact(c, "whisper-large-v3-turbo")
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
        // The switch is as tall as both rows: its top and bottom edges (level with the Optimized and the Standard row) and
        // the middle between them all flip it.
        XCTAssertEqual(r.height, TierControl.height, accuracy: 0.5, "full two-row height")
        for (point, expected) in [
            (NSPoint(x: r.minX + 2, y: r.maxY - 2), OptimizedMode.fast), (NSPoint(x: r.minX + 2, y: r.minY + 2), .exact),
            (NSPoint(x: r.midX, y: r.midY), .fast), (NSPoint(x: r.maxX - 2, y: r.minY + 2), .exact)
        ] {
            click(window, at: point)
            XCTAssertEqual(c.currentSelection(turbo).mode, expected, "a click at \(point) flipped it")
        }
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
        c.runtime = TableRuntime(loaded: [
            "qwen3-asr-1.7b": LoadedFamily(
                precision: "BF16", engine: "optimized",
                selection: ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        ])
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
        let enter = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        a.mouseEntered(with: enter)
        XCTAssertTrue(a.hovered)
        a.mouseExited(with: enter)
        XCTAssertFalse(a.hovered)
        XCTAssertEqual(a.toolTipText(at: NSPoint(x: a.buttonRect.midX, y: a.buttonRect.midY)).components(separatedBy: "\n").first, "Not downloaded")
    }

    /// A tier the presence gate removed is greyed in place on both rows (never hidden): its tooltip says why in one
    /// line, and a real click on it selects nothing (Toby, 30 Sep).
    func testGateRemovedTiersAreGreyedInPlaceAndRefuseClicks() throws {
        let c = try controller()
        let (window, view) = host(c)
        let rows = try segmentRows(c, view)
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        let (optimized, standard) = try XCTUnwrap(rows[qwen.id])
        for control in [optimized, standard] {
            XCTAssertEqual(control.segmentCount, 3, "all three cells shown")
            XCTAssertEqual((0..<3).map { control.label(forSegment: $0) }, ["bf16", "int8", "int4"])
            XCTAssertEqual((0..<3).map { control.isEnabled(forSegment: $0) }, [true, false, false], "int8 and int4 lose a clip: greyed")
            XCTAssertEqual(control.toolTip(forSegment: 1), "Not offered: 1 clip empty or cut short where 16 had the words")
            XCTAssertEqual(control.toolTip(forSegment: 1)?.contains("\n"), false, "one line")
        }
        let before = c.currentSelection(qwen)
        for control in [optimized, standard] {
            for index in [1, 2] {
                click(window, segment: index, of: control)
                XCTAssertEqual(c.currentSelection(qwen), before, "a click on greyed segment \(index) changes nothing")
                XCTAssertNil(c.previews[qwen.id])
            }
        }
        // Every model's two rows keep the same three columns, so the grid never shifts from row to row.
        let frames = rows.values.flatMap { [$0.optimized, $0.standard] }.map { $0.convert($0.bounds, to: nil) }
        XCTAssertEqual(Set(frames.map { Int($0.minX.rounded()) }).count, 1, "one left edge")
        XCTAssertEqual(Set(frames.map { Int($0.width.rounded()) }).count, 1, "one width")
        // The API path refuses a greyed cell too.
        c.select(qwen, tier: .t8, path: .optimized)
        XCTAssertEqual(c.currentSelection(qwen), before)
    }

    /// benchmarks.json `figures_pending` (the shipped file until the final build is measured): every figure and delta
    /// shows `—`, the rows keep the catalog order, and selection works exactly as without it.
    func testPendingFiguresHideFiguresButNotSelection() throws {
        let c = try controller()
        XCTAssertTrue(c.benchmarks.figuresPending, "the shipped benchmarks.json predates the final build")
        let (window, view) = host(c)
        let table = ModelTable(controller: c)
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let (optimized, _) = try XCTUnwrap(try segmentRows(c, view)[ultra.id])
        click(window, segment: 1, of: optimized)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t8, path: .optimized, mode: .fast), "a measured cell is selectable")
        XCTAssertNotNil(c.shownResult(ultra), "the controller still has the numbers")
        let tips = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        for column in ["WER", "Format", "Speed", "J / min", "Peak RAM"] { XCTAssertEqual(tips[column], figuresPendingHelp, column) }
        XCTAssertEqual(tips["Precision Optimized int8"], "8-bit weights throughout (affine-8 g64)", "no delta and no loss while pending")
        XCTAssertEqual(tips["Precision Standard int8"], TierControl.notMeasuredHelp, "an unmeasured cell stays refused")
        c.select(ultra, tier: .t8, path: .standard)
        XCTAssertEqual(c.currentSelection(ultra).path, .optimized, "'Not measured yet' still refuses")
        XCTAssertEqual(
            ModelTable.rows(c, .dictation, sort: .wer, ascending: true).map(\.id),
            c.families(.dictation).map(\.id) + c.references(.dictation).map { "reference:" + $0.id },
            "no hidden figure shows through the order")
        // Cleared (as the measurement writer rewrites the file): the figures are back.
        c.benchmarks.figuresPending = false
        let measured = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNotEqual(measured["WER"], figuresPendingHelp)
        XCTAssertTrue(measured["Precision Optimized int8"]?.contains("vs Standard bf16: ") == true)
    }

    /// Family rule (29 Sep): a cell or switch position without a measurement is unavailable: greyed with "Not measured
    /// yet", and a click on it changes nothing. It becomes selectable once the data has its numbers.
    func testUnmeasuredCellsAndExactAreUnavailable() throws {
        let c = try controller()
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let fast16 = ModelSelection(tier: .t16, path: .optimized, mode: .fast)
        XCTAssertEqual(c.currentSelection(ultra), fast16)
        // Ultra's Exact recipes: 16 unmeasured, 8/4 measured (Exact = Fast there), so Exact is available and moves to 8.
        XCTAssertFalse(c.measured(ultra, ModelSelection(tier: .t16, path: .optimized, mode: .exact)))
        // Standard 8 of Ultra has no measurement: refused.
        XCTAssertFalse(c.measured(ultra, ModelSelection(tier: .t8, path: .standard, mode: .fast)))
        c.select(ultra, tier: .t8, path: .standard)
        XCTAssertEqual(c.currentSelection(ultra), fast16, "an unmeasured cell is never selected")
        // A model with no measured Exact recipe at all: the Exact position is unavailable.
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        XCTAssertFalse(c.exactAvailable(turbo))
        c.setMode(turbo, .exact)
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast, "Exact is not measured yet: the switch stays on Fast")
        let (window, view) = host(c)
        let order = familiesInRowOrder(c)
        let index = try XCTUnwrap(order.firstIndex { $0.id == turbo.id })
        let s = topDown(all(SwitchView.self, in: view))[index]
        XCTAssertTrue(s.exactUnavailable)
        XCTAssertTrue(s.toolTip?.contains(ExactFastSwitch.exactNotMeasuredHelp) == true)
        let r = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(c.currentSelection(turbo).mode, .fast, "a real click on the unavailable Exact does nothing")
        // Once measured, Exact is selectable.
        measureExact(c, turbo.id)
        XCTAssertTrue(c.exactAvailable(turbo))
        c.setMode(turbo, .exact)
        XCTAssertEqual(c.currentSelection(turbo).mode, .exact)
        // The greyed segment itself: disabled with the tooltip.
        let (_, standardRow) = try XCTUnwrap(try segmentRows(c, view)[ultra.id])
        XCTAssertFalse(standardRow.isEnabled(forSegment: 1), "Ultra Standard 8 greyed")
        XCTAssertEqual(standardRow.toolTip(forSegment: 1), TierControl.notMeasuredHelp)
        XCTAssertTrue(standardRow.isEnabled(forSegment: 0), "Standard 16 is measured")
    }
}
