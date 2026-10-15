import AppKit
import Combine
import XCTest
@testable import Vella
import VellaCore

/// The Transcripts window (2.1): newest first, ten at a time, text read only for the rows shown.
@MainActor final class TranscriptsTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-transcripts-\(UUID())").appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TranscriptsWindow.keepOffscreen = true
        TranscriptsWindowController.autosaves = false
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private let base = Date(timeIntervalSinceReferenceDate: 813_000_000)
    /// A recording folder created `minutes` after `base`, with a finished or partial transcript (or none).
    @discardableResult
    private func recording(_ name: String, minutes: Double, text: String? = nil, partial: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("session.json"))
        if let text { try Data(text.utf8).write(to: folder.appendingPathComponent("transcript.txt")) }
        if let partial { try Data(partial.utf8).write(to: folder.appendingPathComponent("partial-transcript.txt")) }
        try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(minutes * 60)], ofItemAtPath: folder.path)
        return folder
    }
    private func recordings(_ count: Int) throws {
        for i in 0..<count { try recording(String(format: "R%05d", i), minutes: Double(i), text: "text \(i)") }
    }

    func testFirstPageIsTenNewestThenShowMoreAddsTwentyUntilTheEnd() throws {
        try recordings(35)
        let model = TranscriptsModel(root: root)
        model.reload()
        XCTAssertEqual(model.entries.map(\.text), (25..<35).reversed().map { "text \($0)" })
        XCTAssertTrue(model.hasMore)
        model.showMore()
        XCTAssertEqual(model.entries.count, 30)
        XCTAssertEqual(model.entries.last?.text, "text 5")
        XCTAssertTrue(model.hasMore)
        model.showMore()
        XCTAssertEqual(model.entries.count, 35)
        XCTAssertEqual(model.entries.last?.text, "text 0")
        XCTAssertFalse(model.hasMore, "no Show more once everything is shown")
    }

    func testOpeningReadsTextOnlyForTheFirstPage() throws {
        // Toby's Mac holds thousands of recordings: opening lists the folder and reads ten transcripts, not all of them.
        try recordings(2_000)
        let model = TranscriptsModel(root: root)
        TranscriptStore.reads = 0
        let started = Date()
        model.reload()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(model.entries.count, 10)
        XCTAssertEqual(TranscriptStore.reads, 10)
        XCTAssertLessThan(elapsed, 1.0, "opening stays immediate (measured \(elapsed) s, busy machine)")
        TranscriptStore.reads = 0
        model.showMore()
        XCTAssertEqual(TranscriptStore.reads, 20, "Show more reads only the next twenty")
    }

    func testOrderIsNewestFirstByRecordingStartNotFolderName() throws {
        try recording("ZZZ", minutes: 1, text: "oldest")
        try recording("AAA", minutes: 3, text: "newest")
        try recording("MMM", minutes: 2, text: "middle")
        let model = TranscriptsModel(root: root)
        model.reload()
        XCTAssertEqual(model.entries.map(\.text), ["newest", "middle", "oldest"])
        XCTAssertEqual(model.entries.first?.created, base.addingTimeInterval(180))
    }

    func testPartialTranscriptIsMarkedIncompleteWithoutItsClipboardHeader() throws {
        try recording("dictation", minutes: 1, partial: "[Incomplete transcript — retry missing audio segments]\nfirst part\n[Pending transcription — segment 2]")
        try recording("streaming", minutes: 2, partial: "[Incomplete streaming transcript — retry saved audio]\nlive words")
        try recording("retried", minutes: 3, text: "finished text", partial: "[Incomplete transcript — retry missing audio segments]\nold")
        let model = TranscriptsModel(root: root)
        model.reload()
        XCTAssertEqual(model.entries.map(\.text), ["finished text", "live words", "first part\n[Pending transcription — segment 2]"])
        XCTAssertEqual(model.entries.map(\.incomplete), [false, true, true], "a retried recording's finished transcript wins")
    }

    /// Crash state as the app leaves it, through the real writers: a streaming session that died with its journal
    /// open, and a dictation that died after some segments were recognized. Neither has a transcript file.
    func testTextLeftByACrashShowsAsIncompleteWithoutTouchingTheRecording() throws {
        let streaming = try RecordingSession(root: root, config: Configuration(model: "/qa/stream", mode: .streaming, streamingModel: "/qa/stream"))
        let journal = try StreamingJournal(directory: streaming.directory)
        try journal.append(committed: "hello there", partial: "", frames: 16_000)
        try journal.append(committed: "general", partial: "kenobi you are", frames: 32_000)
        // Process death: no finish, no partial file, no archive. (Closing the descriptor writes nothing.)
        journal.close()
        let dictation = try RecordingSession(root: root, config: Configuration(model: "/qa/dictation"))
        dictation.manifest.segments = [
            RecordingSession.Segment(index: 0, frames: 16_000, finalized: true, text: "first part of the note"),
            RecordingSession.Segment(index: 1, frames: 16_000, overlapFrames: 8_000, finalized: true),
            RecordingSession.Segment(index: 2, frames: 16_000, overlapFrames: 8_000, finalized: true, text: "the last part")
        ]
        try dictation.save()
        let nothingYet = try RecordingSession(root: root, config: Configuration(model: "/qa/dictation"))
        nothingYet.manifest.segments = [RecordingSession.Segment(index: 0, frames: 16_000, finalized: true)]
        try nothingYet.save()
        for (session, minutes) in [(streaming, 1.0), (dictation, 2.0), (nothingYet, 3.0)] {
            try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(minutes * 60)], ofItemAtPath: session.directory.path)
        }
        func snapshot(_ directory: URL) throws -> [String: Data] {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            return Dictionary(uniqueKeysWithValues: try names.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
        }
        let before = try [streaming, dictation, nothingYet].map { try snapshot($0.directory) }

        let model = TranscriptsModel(root: root)
        model.reload()
        XCTAssertEqual(model.entries.map(\.text), ["first part of the note the last part", "hello there general kenobi you are"])
        XCTAssertEqual(model.entries.map(\.incomplete), [true, true])
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(try [streaming, dictation, nothingYet].map { try snapshot($0.directory) }, before, "the window only reads")
    }

    func testRecordingsWithoutTextAreSkippedAndPagesStillFill() throws {
        try recordings(12)
        try recording("in-progress", minutes: 100)
        try recording("empty", minutes: 99, text: "  \n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-recording"), withIntermediateDirectories: true)
        let model = TranscriptsModel(root: root)
        model.reload()
        XCTAssertEqual(model.entries.count, 10)
        XCTAssertEqual(model.entries.first?.text, "text 11")
        model.showMore()
        XCTAssertEqual(model.entries.count, 12)
        XCTAssertFalse(model.hasMore)
    }

    func testEmptyStates() throws {
        let missing = TranscriptsModel(root: root.appendingPathComponent("missing"))
        missing.reload()
        XCTAssertTrue(missing.entries.isEmpty); XCTAssertFalse(missing.hasMore)
        try recording("in-progress", minutes: 1)
        let onlyRecording = TranscriptsModel(root: root)
        onlyRecording.reload()
        XCTAssertTrue(onlyRecording.entries.isEmpty); XCTAssertFalse(onlyRecording.hasMore)
        // The first frame draws the empty state (the lavender mark in the middle), not a blank canvas.
        let empty = try firstFrame(TranscriptsWindowController(root: root))
        XCTAssertGreaterThan(empty.count(in: 0.35..<0.65, lavender: true), 20)
        XCTAssertEqual(empty.count(in: 0.08..<0.30, lavender: false), 0, "nothing listed")
        try recordings(3)
        let listed = try firstFrame(TranscriptsWindowController(root: root))
        XCTAssertEqual(listed.count(in: 0.35..<0.65, lavender: true), 0)
        XCTAssertGreaterThan(listed.count(in: 0.08..<0.30, lavender: false), 50, "rows of bright text at the top")
    }

    /// The window's content as first drawn (reload, then one display pass, offscreen).
    private func firstFrame(_ controller: TranscriptsWindowController) throws -> Frame {
        controller.model.reload()
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return Frame(rep: rep)
    }
    struct Frame {
        let rep: NSBitmapImageRep
        /// Pixels in the vertical band `rows` (fractions of the height from the top) that are lavender or near-white.
        func count(in rows: Range<Double>, lavender: Bool) -> Int {
            var n = 0
            let h = rep.pixelsHigh, w = rep.pixelsWide
            for y in stride(from: Int(rows.lowerBound * Double(h)), to: Int(rows.upperBound * Double(h)), by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if lavender
                        ? (c.blueComponent > 0.75 && c.redComponent > 0.55 && c.greenComponent < c.blueComponent - 0.15)
                        : (c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85)
                    {
                        n += 1
                    }
                }
            }
            return n
        }
    }

    func testReloadKeepsTheShownCountAndPicksUpNewTranscripts() throws {
        try recordings(40)
        let model = TranscriptsModel(root: root)
        model.reload(); model.showMore()
        XCTAssertEqual(model.entries.count, 30)
        model.expanded = [model.entries[3].id]
        try recording("new", minutes: 500, text: "just dictated")
        model.reload()
        XCTAssertEqual(model.entries.count, 30)
        XCTAssertEqual(model.entries.first?.text, "just dictated")
        XCTAssertEqual(model.expanded.count, 1, "expansion survives a reload")
    }

    func testDaySectionsReadTodayYesterdayThenDates() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        calendar.locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        func entry(_ day: Int, _ year: Int = 2026) -> TranscriptEntry {
            TranscriptEntry(
                directory: URL(fileURLWithPath: "/\(year)-\(day)"), created: calendar.date(from: DateComponents(year: year, month: 10, day: day, hour: 9))!,
                text: "t", incomplete: false)
        }
        let days = TranscriptDay.group([entry(15), entry(15), entry(14), entry(12), entry(12, 2025)], now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.entries.count), [2, 1, 1, 1])
        XCTAssertEqual(Array(days.map(\.title).prefix(2)), ["Today", "Yesterday"])
        XCTAssertTrue(days[2].title.contains("12") && days[2].title.contains("October") && !days[2].title.contains("2026"), days[2].title)
        XCTAssertTrue(days[3].title.contains("2025"), days[3].title)
    }

    func testMenuItemFollowsCopyLastTranscriptAndOpensTheWindow() throws {
        _ = NSApplication.shared
        let support = root.deletingLastPathComponent()
        let model = DictationController(configurationURL: support.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let delegate = AppDelegate(model: model)
        delegate.rebuildMenu()
        let titles = delegate.menu.items.map(\.title)
        let item = try XCTUnwrap(delegate.menu.item(withTitle: "Transcripts…"), "present before any dictation too")
        XCTAssertEqual(titles[titles.firstIndex(of: "Transcripts…")! - 1], "Shortcuts")
        model.lastText = "text"
        delegate.rebuildMenu()
        let after = delegate.menu.items.map(\.title)
        XCTAssertEqual(after[after.firstIndex(of: "Copy Last Transcript")! + 1], "Transcripts…")
        XCTAssertEqual(item.action.map(NSStringFromSelector), "showTranscripts")
        XCTAssertNotNil(delegate.menu.item(withTitle: "Transcripts…")?.image)
        XCTAssertNil(delegate.menu.item(withTitle: "Transcripts…")?.toolTip)
    }

    func testWindowShowsReadRowsActivatesFirstAndReloadsOnNewText() throws {
        try recordings(3)
        let changes = PassthroughSubject<Void, Never>()
        let controller = TranscriptsWindowController(root: root, changes: changes.eraseToAnyPublisher())
        var activations = 0
        let previous = TranscriptsWindowController.activateApp
        TranscriptsWindowController.activateApp = { activations += 1 }
        defer { TranscriptsWindowController.activateApp = previous; controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "Transcripts")
        XCTAssertTrue(window.styleMask.contains(.resizable) && window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertFalse(window.isReleasedWhenClosed, "one instance, reopened")
        controller.show()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(controller.model.entries.count, 3, "rows are read before the first frame")
        try recording("new", minutes: 50, text: "fresh")
        changes.send()
        let reloaded = expectation(description: "reload")
        DispatchQueue.main.async { reloaded.fulfill() }
        wait(for: [reloaded], timeout: 2)
        XCTAssertEqual(controller.model.entries.first?.text, "fresh")
        controller.model.showMore()
        controller.close()
        XCTAssertTrue(controller.model.entries.isEmpty, "closing forgets the shown rows")
        try recordings(20)
        controller.show()
        XCTAssertEqual(controller.model.entries.count, 10, "reopening starts at the newest ten")
    }

    func testCopyPutsTheTranscriptOnThePasteboard() throws {
        try recording("one", minutes: 1, text: "copy me")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controller = TranscriptsWindowController(root: root)
        controller.copy = {
            pasteboard.clearContents(); pasteboard.setString($0, forType: .string)
        }
        controller.model.reload()
        controller.copy(try XCTUnwrap(controller.model.entries.first).text)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy me")
    }
}

/// Pop-up buttons follow the system layout (first added = right = the action; Cancel left with Escape); a download
/// that cannot fit is refused with OK only and approves nothing.
@MainActor final class AlertButtonTests: XCTestCase {
    func testConfirmationsPutTheActionFirstAndCancelSecond() {
        let prompt = DownloadPrompt(title: "Download Alpha?", body: "4 kB download, then it loads.", variantID: "a", downloadBytes: 4_000, family: "alpha", precision: "BF16")
        let download = DownloadGate.alert(prompt)
        XCTAssertEqual(download.buttons.map(\.title), ["Download", "Cancel"])
        XCTAssertEqual(download.buttons[0].keyEquivalent, "", "Return never starts a download")
        XCTAssertEqual(download.buttons[1].keyEquivalent, "\u{1b}", "Escape cancels")
        let delete = AppDelegate.deleteSavedAlert()
        XCTAssertEqual(delete.buttons.map(\.title), ["Delete", "Cancel"])
        XCTAssertEqual(delete.buttons[0].keyEquivalent, "")
        let recover = AppDelegate.savedRecordingAlert([SavedRecordingChoice(directory: URL(fileURLWithPath: "/r"), title: "r")])
        XCTAssertEqual(recover.buttons.map(\.title), ["Transcribe", "Cancel"])
        XCTAssertEqual(recover.buttons[0].keyEquivalent, "\r", "transcribing a saved recording is safe on Return")
        for alert in [download, delete, recover] {
            alert.layout()
            XCTAssertGreaterThan(alert.buttons[0].frame.minX, alert.buttons[1].frame.minX, "\(alert.messageText): action on the right")
        }
    }

    func testNotEnoughDiskSpaceIsARefusalThatApprovesNothing() {
        let refusal = DownloadPrompt(
            title: "Not enough disk space", body: "Alpha needs 4 kB; 1 kB free.", variantID: "a", downloadBytes: 4_000, family: "alpha", precision: "BF16", refusal: true)
        XCTAssertEqual(DownloadGate.alert(refusal).buttons.map(\.title), ["OK"])
        var shown = 0
        XCTAssertNil(
            DownloadGate.ask(refusal) { _ in
                shown += 1; return true
            })
        XCTAssertEqual(shown, 1, "the refusal is still shown")
    }
}
