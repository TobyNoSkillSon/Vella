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

/// Clicks on the Models table's Precision row, the Exact/Fast switch and the action button reach the controller and change the
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
        // Fixed hardware, whatever Mac runs the tests: the measured M5 Max with its tensor units.
        c.benchmarkHardware = .measured
        c.gpu = GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)
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

    /// Each model's Precision row (one segment control per model, no Standard row), in row order.
    private func segmentRows(_ c: ModelsController, _ view: NSView) throws -> [String: NSSegmentedControl] {
        let controls = topDown(all(NSSegmentedControl.self, in: view))
        let order = familiesInRowOrder(c)
        XCTAssertEqual(controls.count, order.count, "one Precision row per model")
        var rows: [String: NSSegmentedControl] = [:]
        for (i, family) in order.enumerated() where i < controls.count { rows[family.id] = controls[i] }
        return rows
    }
    /// A real click on segment `index` of a control.
    private func click(_ window: NSWindow, segment index: Int, of control: NSSegmentedControl) {
        let r = control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: nil)
        click(window, at: NSPoint(x: r.minX + (TierControl.cellWidth - 1) * (CGFloat(index) + 0.5), y: r.midY))
    }

    /// Every cell of the row is directly clickable and shows its own numbers: int8 (deltas vs 16-bit), then bf16 (the
    /// reference: its own figures, no deltas), then int8 again.
    func testEveryCellIsClickableAndShowsItsNumbers() throws {
        let c = try controller()
        let (window, view) = host(c)
        let rows = try segmentRows(c, view)
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let row = try XCTUnwrap(rows[ultra.id])
        XCTAssertEqual(row.segmentCount, 3, "Ultra offers 16, 8 and 4")
        XCTAssertEqual((0..<3).map { row.label(forSegment: $0) }, ["bf16", "int8", "int4"], "the dtype that runs")
        XCTAssertNil(c.previews[ultra.id])
        click(window, segment: 1, of: row)
        XCTAssertEqual(c.previews[ultra.id], ModelSelection(tier: .t8, mode: .fast), "8, Fast kept, the optimized request")
        XCTAssertEqual(row.selectedSegment, 1, "the row re-rendered with 8 selected")
        let int8 = try XCTUnwrap(c.shownResult(ultra)?.speed_x)
        XCTAssertTrue(c.showsDeltas(ultra))
        click(window, segment: 0, of: row)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t16, mode: .fast))
        XCTAssertNil(c.previews[ultra.id], "the committed cell ends the preview")
        XCTAssertEqual(row.selectedSegment, 0)
        let bf16 = try XCTUnwrap(c.shownResult(ultra)?.speed_x)
        XCTAssertNotEqual(bf16, int8, "bf16 shows its own numbers")
        XCTAssertEqual(bf16, c.baseResult(ultra)?.speed_x)
        XCTAssertFalse(c.showsDeltas(ultra), "16-bit is the deltas' base: none under its figures")
        click(window, segment: 1, of: row)
        XCTAssertEqual(c.shownResult(ultra)?.speed_x, int8, "back on int8: its numbers")
        XCTAssertEqual(c.action(ultra), .get)
    }

    /// The row follows the switch: Exact lists only the precisions with an exact recipe, Fast every measured one.
    func testThePrecisionRowUnderEachSwitchPosition() throws {
        let c = try controller()
        measureExact(c, "whisper-large-v3-turbo")
        c.benchmarks.models["whisper-large-v3-turbo"]?.tiers[.t8]?.cells[.optimized_exact] = nil
        let (window, view) = host(c)
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        let order = familiesInRowOrder(c)
        let index = try XCTUnwrap(order.firstIndex { $0.id == turbo.id })
        var row = try XCTUnwrap(try segmentRows(c, view)[turbo.id])
        XCTAssertEqual(row.segmentCount, 3, "the row keeps its three cells")
        XCTAssertEqual((0..<3).map { row.label(forSegment: $0) }, ["fp16", "int8", "int4"], "Whisper's 16 is fp16")
        XCTAssertEqual((0..<3).map { row.isEnabled(forSegment: $0) }, [true, true, true], "Fast: fp16, int8 and int4, each measured")
        click(window, segment: 1, of: row)
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, mode: .fast))
        let s = topDown(all(SwitchView.self, in: view))[index]
        let r = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t16, mode: .exact), "Exact moved 8 to 16")
        XCTAssertEqual(c.couplingNote(turbo), "Exact: fp16 and int4, was int8")
        row = try XCTUnwrap(try segmentRows(c, view)[turbo.id])
        XCTAssertEqual(row.segmentCount, 3, "the grid never shifts")
        XCTAssertEqual((0..<3).map { row.isEnabled(forSegment: $0) }, [true, false, true], "Exact: fp16 and int4, not int8 (no Exact recipe)")
        XCTAssertEqual(row.toolTip(forSegment: 1), "No Exact recipe at int8; Fast offers it")
        let exact16 = c.currentSelection(turbo)
        click(window, segment: 1, of: row)
        XCTAssertEqual(c.currentSelection(turbo), exact16, "a real click on the greyed int8 changes nothing")
        click(window, segment: 2, of: row)
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t4, mode: .exact), "int4 stays reachable under Exact")
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
        XCTAssertEqual(switches.count, order.count, "one switch per model")
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
        // The switch keeps its full height (unchanged since the two-row control): its top and bottom edges and the
        // middle all flip it.
        XCTAssertEqual(r.height, ExactFastSwitch.height, accuracy: 0.5, "full height")
        for (point, expected) in [
            (NSPoint(x: r.minX + 2, y: r.maxY - 2), OptimizedMode.fast), (NSPoint(x: r.minX + 2, y: r.minY + 2), .exact),
            (NSPoint(x: r.midX, y: r.midY), .fast), (NSPoint(x: r.maxX - 2, y: r.minY + 2), .exact)
        ] {
            click(window, at: point)
            XCTAssertEqual(c.currentSelection(turbo).mode, expected, "a click at \(point) flipped it")
        }
        // From int8 the switch keeps int8 where Exact has it.
        c.select(turbo, tier: .t8)
        click(window, at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(c.currentSelection(turbo), ModelSelection(tier: .t8, mode: .fast))
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

    /// The action button: always visible with one word; a click performs it; another switch position or cell on a
    /// loaded model turns it into the green Reload, which reloads that request (always optimized); a click on the trash
    /// glyph asks to delete.
    func testTheActionButtonPerformsReloadsAndDeletes() throws {
        let c = try controller()
        measureExact(c, "whisper-large-v3-turbo")
        let spy = ClickSpy(); c.actions = spy
        c.dictation.installed["Qwen3-ASR-1.7B-bf16"] = InstalledModel(path: "/fixture/q16")
        c.dictation.installed["whisper-large-v3-turbo-asr-fp16"] = InstalledModel(path: "/fixture/t16")
        var deleted: [String] = []
        let (window, view) = host(c, requestDelete: { deleted.append($0.id) })
        let order = familiesInRowOrder(c)
        let actions = topDown(all(RowActionView.self, in: view))
        XCTAssertEqual(actions.count, order.count)
        XCTAssertTrue(actions.allSatisfy { $0.frame.size == NSSize(width: RowAction.width, height: RowAction.height) }, "fixed size")
        let index = try XCTUnwrap(order.firstIndex { $0.id == "qwen3-asr-1.7b" })
        let a = actions[index]
        XCTAssertEqual(a.spec?.title, "Load")
        XCTAssertTrue(a.spec?.deletable ?? false)
        let r = a.convert(a.bounds, to: nil)
        click(window, at: NSPoint(x: r.minX + a.buttonRect.midX, y: r.midY))
        XCTAssertEqual(spy.calls, ["load qwen3-asr-1.7b BF16"], "a click on the button performed Load")
        XCTAssertEqual(spy.selections.last, ModelSelection(tier: .t16, mode: .fast))
        click(window, at: NSPoint(x: r.minX + a.trashRect.midX, y: r.midY))
        XCTAssertEqual(deleted, ["qwen3-asr-1.7b"], "a click on the trash glyph asked to delete")
        XCTAssertEqual(spy.calls.count, 1, "and did not also load")
        // Turbo loaded at 16 · Fast: Unload; the switch flipped to Exact: the green Reload of 16 · Exact.
        let turboIndex = try XCTUnwrap(order.firstIndex { $0.id == "whisper-large-v3-turbo" })
        c.runtime = TableRuntime(loaded: [
            "whisper-large-v3-turbo": LoadedFamily(precision: "FP16", engine: "optimized", selection: ModelSelection(tier: .t16, mode: .fast))
        ])
        spin()
        func button() -> RowActionView { topDown(all(RowActionView.self, in: view))[turboIndex] }
        XCTAssertEqual(button().spec?.title, "Unload")
        let s = topDown(all(SwitchView.self, in: view))[turboIndex]
        let sr = s.convert(s.bounds, to: nil)
        click(window, at: NSPoint(x: sr.midX, y: sr.midY))
        XCTAssertEqual(button().spec?.title, "Reload")
        XCTAssertEqual(button().spec?.emphasized, true, "green")
        let b = button().convert(button().bounds, to: nil)
        click(window, at: NSPoint(x: b.minX + button().buttonRect.midX, y: b.midY))
        XCTAssertEqual(spy.calls.last, "reload whisper-large-v3-turbo FP16")
        XCTAssertEqual(spy.selections.last, ModelSelection(tier: .t16, mode: .exact), "VELLA_RECIPE=optimized_exact, never standard")
        XCTAssertEqual(workerRecipe(spy.selections.last), .optimized_exact)
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

    /// A tier that fails the presence gate is offered where it is measured (Toby, 6 Oct): its measured cells are
    /// selectable by a real click; an unmeasured cell stays greyed in place with its reason, and a click on it selects
    /// nothing. The grid never shifts.
    func testFormerlyGateRemovedTiersAreSelectableWhereMeasured() throws {
        let c = try controller()
        let (window, view) = host(c)
        let rows = try segmentRows(c, view)
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        let row = try XCTUnwrap(rows[qwen.id])
        XCTAssertEqual(row.segmentCount, 3, "all three cells shown")
        XCTAssertEqual((0..<3).map { row.label(forSegment: $0) }, ["bf16", "int8", "int4"])
        XCTAssertEqual((0..<3).map { row.isEnabled(forSegment: $0) }, [true, true, true], "measured: selectable")
        click(window, segment: 1, of: row)
        XCTAssertEqual(c.currentSelection(qwen), ModelSelection(tier: .t8, mode: .fast), "a real click selects int8")
        // Ultra under Exact: its 16 has no Exact measurement, greyed with the reason; a click does nothing.
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        c.setMode(ultra, .exact)
        spin()
        let ultraRow = try XCTUnwrap(try segmentRows(c, view)[ultra.id])
        XCTAssertFalse(ultraRow.isEnabled(forSegment: 0))
        XCTAssertTrue(ultraRow.toolTip(forSegment: 0)?.hasPrefix(unmeasuredCellHelp) == true)
        let before = c.currentSelection(ultra)
        click(window, segment: 0, of: ultraRow)
        XCTAssertEqual(c.currentSelection(ultra), before, "a click on the greyed segment changes nothing")
        // Every model's row keeps the same three columns, so the grid never shifts from row to row.
        let frames = try segmentRows(c, view).values.map { $0.convert($0.bounds, to: nil) }
        XCTAssertEqual(Set(frames.map { Int($0.minX.rounded()) }).count, 1, "one left edge")
        XCTAssertEqual(Set(frames.map { Int($0.width.rounded()) }).count, 1, "one width")
        // The API path refuses a greyed cell too.
        c.select(ultra, tier: .t16)
        XCTAssertEqual(c.currentSelection(ultra), before)
    }

    /// benchmarks.json `figures_pending` (the fixture's state until the final build is measured): every figure and
    /// delta shows `—`, no cell is recommended or warned, the rows keep the catalog order, and selection works exactly
    /// as without it.
    func testPendingFiguresHideFiguresButNotSelection() throws {
        let c = try controller()
        XCTAssertTrue(c.benchmarks.figuresPending, "the fixture predates the final build")
        let (window, view) = host(c)
        let table = ModelTable(controller: c)
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let row = try XCTUnwrap(try segmentRows(c, view)[ultra.id])
        click(window, segment: 1, of: row)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t8, mode: .fast), "a measured cell is selectable")
        XCTAssertNotNil(c.shownResult(ultra), "the controller still has the numbers")
        XCTAssertEqual(c.advice(ultra), PrecisionAdvice(), "no gold and no triangle on figures that are pending")
        let tips = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        for column in ["WER", "Format", "Speed", "J / min", "Peak RAM"] { XCTAssertEqual(tips[column], figuresPendingHelp, column) }
        XCTAssertEqual(tips["Precision int8"], "8-bit weights throughout (affine-8 g64)", "no delta and no loss while pending")
        c.setMode(ultra, .exact)
        let exact = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(exact["Precision bf16"]?.hasPrefix(unmeasuredCellHelp) == true, "an unmeasured cell stays refused")
        c.setMode(ultra, .fast)
        XCTAssertEqual(
            ModelTable.rows(c, .dictation, sort: .wer, ascending: true).map(\.id),
            c.families(.dictation).map(\.id) + c.references(.dictation).map { "reference:" + $0.id },
            "no hidden figure shows through the order")
        // Cleared (as the measurement writer rewrites the file): the figures are back.
        c.benchmarks.figuresPending = false
        let measured = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNotEqual(measured["WER"], figuresPendingHelp)
        XCTAssertTrue(measured["Precision int8"]?.contains("vs bf16: ") == true)
        XCTAssertNotNil(c.advice(ultra).recommended)
    }

    /// Family rule (29 Sep): a cell or switch position without a measurement is unavailable: greyed with "Not measured
    /// yet", and a click on it changes nothing. It becomes selectable once the data has its numbers.
    func testUnmeasuredCellsAndExactAreUnavailable() throws {
        let c = try controller()
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let fast16 = ModelSelection(tier: .t16, mode: .fast)
        XCTAssertEqual(c.currentSelection(ultra), fast16)
        // Ultra's Exact recipes: 16 unmeasured, 8/4 measured (Exact = Fast there), so Exact is available and moves to 8.
        XCTAssertFalse(c.measured(ultra, ModelSelection(tier: .t16, mode: .exact)))
        c.setMode(ultra, .exact)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t8, mode: .exact))
        c.select(ultra, tier: .t16)
        XCTAssertEqual(c.currentSelection(ultra), ModelSelection(tier: .t8, mode: .exact), "an unmeasured cell is never selected")
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
        spin()
        let ultraRow = try XCTUnwrap(try segmentRows(c, view)[ultra.id])
        XCTAssertFalse(ultraRow.isEnabled(forSegment: 0), "Ultra Exact 16 greyed")
        XCTAssertTrue(ultraRow.toolTip(forSegment: 0)?.hasPrefix(unmeasuredCellHelp) == true)
        XCTAssertTrue(ultraRow.isEnabled(forSegment: 1), "Exact 8 is measured")
    }
}
