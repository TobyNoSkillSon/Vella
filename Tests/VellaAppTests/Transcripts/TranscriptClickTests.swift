import AppKit
import XCTest
@testable import Vella

/// A click on a transcript's text copies it (Toby, 15 Oct: "we don't have to click copy we just click on the text or
/// copy to actually copy it"), through real mouse events on the hosted window: a drag selects and never copies, Copy
/// still copies, and a long transcript opens and closes from its chevron, not from a click on the text.
@MainActor final class TranscriptClickTests: XCTestCase {
    private var root: URL!
    private var controller: TranscriptsWindowController!
    private var copied: [String] = []
    private var previousActivate: (() -> Void)!
    static let long = String(repeating: "This sentence is part of a long transcript that runs well past four lines in the window. ", count: 12).trimmingCharacters(in: .whitespaces)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-transcript-clicks-\(UUID())").appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TranscriptsWindow.keepOffscreen = true
        TranscriptsWindowController.autosaves = false
        previousActivate = TranscriptsWindowController.activateApp
        TranscriptsWindowController.activateApp = {}
    }
    override func tearDown() async throws {
        controller?.window?.orderOut(nil)
        controller = nil
        TranscriptsWindowController.activateApp = previousActivate
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// Newest first: `texts[0]` is the top row.
    private func open(_ texts: [String]) throws -> NSWindow {
        let base = Date().addingTimeInterval(-3600)
        for (i, text) in texts.reversed().enumerated() {
            let folder = root.appendingPathComponent(String(format: "R%03d", i))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("session.json"))
            try Data(text.utf8).write(to: folder.appendingPathComponent("transcript.txt"))
            try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: folder.path)
        }
        controller = TranscriptsWindowController(root: root)
        controller.copy = { [unowned self] in copied.append($0) }
        controller.show()
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        // Rows report where their text sits once laid out.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, controller.model.entries.contains(where: { controller.model.textFrames[$0.id] == nil }) { spin(0.05) }
        spin(0.2)
        return window
    }
    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    /// A point on the top row's text, in window coordinates: `dx` into its first line.
    private func topText(_ window: NSWindow, dx: CGFloat = 30) -> NSPoint {
        let text = (try? textFrame(0)) ?? .zero
        XCTAssertEqual(text.minX, TranscriptLayout.textLeading, "the text starts past the time gutter")
        return windowPoint(window, CGPoint(x: text.minX + dx, y: text.minY + 8))
    }
    private func event(_ type: NSEvent.EventType, _ window: NSWindow, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    /// Down, optional drags, up. Events after the down are queued first, so a tracking loop started by the down (text
    /// selection) reads them; whatever it leaves is sent to the window afterwards.
    private func press(_ window: NSWindow, at start: NSPoint, dragTo end: NSPoint? = nil) {
        // Mouse events another suite left queued would otherwise reach this window first.
        while NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) != nil {}
        var later: [NSEvent] = []
        if let end {
            for step in 1...8 {
                let t = CGFloat(step) / 8
                later.append(event(.leftMouseDragged, window, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            }
        }
        later.append(event(.leftMouseUp, window, end ?? start))
        for e in later { NSApp.postEvent(e, atStart: false) }
        window.sendEvent(event(.leftMouseDown, window, start))
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            if e.windowNumber == window.windowNumber { window.sendEvent(e) }
        }
        spin()
    }
    /// A row's text frame as the row reports it (hosting view coordinates, top-left origin).
    private func textFrame(_ index: Int) throws -> CGRect {
        let id = try XCTUnwrap(controller.model.entries[safe: index]?.id)
        return try XCTUnwrap(controller.model.textFrames[id])
    }
    /// Hosting-view (top-left) coordinates to window coordinates.
    private func windowPoint(_ window: NSWindow, _ p: CGPoint) -> NSPoint {
        let view = window.contentView!
        return view.convert(view.isFlipped ? p : NSPoint(x: p.x, y: view.bounds.height - p.y), to: nil)
    }
    /// Copy sits at the row's trailing edge, level with the text's first line.
    private func copyButton(_ window: NSWindow, row: Int) throws -> NSPoint {
        let text = try textFrame(row)
        return windowPoint(window, CGPoint(x: window.contentView!.bounds.width - TranscriptLayout.inset - 12, y: text.minY + 8))
    }
    /// The chevron sits under Copy, level with the row's last line.
    private func chevron(_ window: NSWindow, row: Int) throws -> NSPoint {
        let text = try textFrame(row)
        return windowPoint(window, CGPoint(x: window.contentView!.bounds.width - TranscriptLayout.inset - 9, y: text.maxY - 8))
    }

    func testClickOnTheTextCopiesItAndCopyReadsCopiedForAMoment() throws {
        let window = try open(["copy me by clicking", "an older one"])
        press(window, at: topText(window))
        XCTAssertEqual(copied, ["copy me by clicking"])
        XCTAssertEqual(controller.model.copiedID, controller.model.entries.first?.id, "the row's Copy label reads Copied")
        spin(1.6)
        XCTAssertNil(controller.model.copiedID, "and goes back to Copy")
    }

    func testDragAcrossTheTextSelectsAndNeverCopies() throws {
        let window = try open(["drag across these words to select some of them", "an older one"])
        let start = topText(window, dx: 4)
        press(window, at: start, dragTo: NSPoint(x: start.x + 120, y: start.y))
        XCTAssertEqual(copied, [], "a drag is a selection, not a copy")
        press(window, at: topText(window))
        XCTAssertEqual(copied, ["drag across these words to select some of them"], "a click after it still copies")
    }

    func testCopyButtonStillCopies() throws {
        let window = try open(["press the button", "an older one"])
        press(window, at: try copyButton(window, row: 1))
        XCTAssertEqual(copied, ["an older one"])
        XCTAssertEqual(controller.model.copiedID, controller.model.entries[1].id, "Copied on that row only")
        press(window, at: try copyButton(window, row: 0))
        XCTAssertEqual(copied, ["an older one", "press the button"])
    }

    func testLongTranscriptOpensFromItsChevronNotFromAClickOnTheText() throws {
        let window = try open([Self.long, "short one"])
        let id = try XCTUnwrap(controller.model.entries.first?.id)
        press(window, at: topText(window))
        XCTAssertEqual(copied, [Self.long], "a click on long text copies it whole")
        XCTAssertFalse(controller.model.expanded.contains(id), "and does not open it")
        press(window, at: try chevron(window, row: 0))
        XCTAssertTrue(controller.model.expanded.contains(id), "the chevron opens it")
        XCTAssertEqual(copied.count, 1, "the chevron copies nothing")
        spin(0.3)
        press(window, at: try chevron(window, row: 0))
        XCTAssertFalse(controller.model.expanded.contains(id), "and closes it")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
