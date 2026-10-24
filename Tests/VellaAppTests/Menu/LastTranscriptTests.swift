import AppKit
import XCTest
@testable import Vella

/// Copy Last Transcript outside a dictation (24 Oct: "where is the Copy Last Transcript button? I think it was deleted in
/// the update"). A relaunch copies the newest saved transcript; the copy is exact and plain text; with no transcript there
/// is no item and Copy leaves the clipboard alone. Real DictationController and AppDelegate.rebuildMenu over a temporary
/// Recordings folder; the clipboard is a private pasteboard.
@MainActor final class LastTranscriptTests: XCTestCase {
    private var root: URL!
    private var recordings: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-last-\(UUID().uuidString)")
        recordings = root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: .init("vella-last-\(UUID().uuidString)"))
    }
    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private let base = Date(timeIntervalSinceReferenceDate: 813_000_000)
    /// A recording folder created `minutes` after `base`, with a finished or partial transcript (or none).
    @discardableResult
    private func recording(_ name: String, minutes: Double, text: String? = nil, partial: String? = nil) throws -> URL {
        let folder = recordings.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("session.json"))
        if let text { try Data(text.utf8).write(to: folder.appendingPathComponent("transcript.txt")) }
        if let partial { try Data(partial.utf8).write(to: folder.appendingPathComponent("partial-transcript.txt")) }
        try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(minutes * 60)], ofItemAtPath: folder.path)
        return folder
    }

    /// A controller as a fresh launch makes one: nothing in memory, this temporary profile, the test clipboard.
    private func launchedModel() throws -> DictationController {
        DictationController(
            pasteboard: pasteboard, configurationURL: root.appendingPathComponent("config.json"),
            backend: Backend(runtime: try Runtime.isolated(root)), monitorDefaultInput: false)
    }
    /// The menu the app builds for `model` now (real rebuildMenu, no status item).
    private func menu(_ model: DictationController) -> AppDelegate {
        _ = NSApplication.shared
        let app = AppDelegate(model: model)
        app.rebuildMenu()
        return app
    }

    /// The relaunch path: the newest saved transcript by creation date (not by folder name) is copied and its item is back.
    func testRelaunchCopiesTheNewestSavedTranscript() throws {
        try recording("A-newer", minutes: 5, text: "Zażółć gęślą jaźń. Newest dictation.")
        try recording("Z-older", minutes: 0, text: "Older dictation.")
        let model = try launchedModel(); defer { model.shutdown() }
        XCTAssertEqual(model.lastText, "", "in memory only until a launch reads Recordings")
        model.restoreLastTranscript(from: recordings)
        XCTAssertEqual(model.lastText, "Zażółć gęślą jaźń. Newest dictation.")
        XCTAssertFalse(model.lastTranscriptIncomplete)
        let app = menu(model)
        let item = try XCTUnwrap(app.menu.item(withTitle: "Copy Last Transcript"), "back in the menu after a relaunch")
        XCTAssertNotNil(item.view as? ProminentMenuItemView)
        model.copyLast()
        XCTAssertEqual(pasteboard.string(forType: .string), "Zażółć gęślą jaźń. Newest dictation.")
    }

    /// A folder with only session.json has no text yet and is not a transcript: the newest one with text is copied.
    func testRestoreSkipsRecordingsWithoutText() throws {
        try recording("R0", minutes: 0, text: "Kept.")
        try recording("R1", minutes: 5)
        try recording("R2", minutes: 9)
        let model = try launchedModel(); defer { model.shutdown() }
        model.restoreLastTranscript(from: recordings)
        XCTAssertEqual(model.lastText, "Kept.")
    }

    /// An unfinished transcript (a partial file after a failed dictation) copies as Incomplete, without the bracketed note
    /// its file starts with.
    func testAnIncompleteTranscriptCopiesAsIncomplete() throws {
        try recording("R0", minutes: 0, text: "Finished.")
        try recording("R1", minutes: 5, partial: "[Incomplete transcript — retry missing audio segments]\nPart of the words")
        let model = try launchedModel(); defer { model.shutdown() }
        model.restoreLastTranscript(from: recordings)
        XCTAssertEqual(model.lastText, "Part of the words")
        XCTAssertTrue(model.lastTranscriptIncomplete)
        let app = menu(model)
        XCTAssertNotNil(app.menu.item(withTitle: "Copy Recognized Text (Incomplete)"))
        XCTAssertNil(app.menu.item(withTitle: "Copy Last Transcript"))
        model.copyLast()
        XCTAssertEqual(pasteboard.string(forType: .string), "Part of the words")
    }

    /// No saved transcript (a fresh install, or a Recordings folder with only audio): no Copy item, and Copy keeps the
    /// clipboard as it was. A missing folder counts the same.
    func testWithNoTranscriptThereIsNoCopyItemAndTheClipboardIsLeftAlone() throws {
        try recording("R0", minutes: 0)
        pasteboard.clearContents(); pasteboard.setString("Kept on the clipboard.", forType: .string)
        let model = try launchedModel(); defer { model.shutdown() }
        model.restoreLastTranscript(from: recordings)
        XCTAssertEqual(model.lastText, "")
        XCTAssertNil(menu(model).menu.item(withTitle: "Copy Last Transcript"))
        model.copyLast()
        XCTAssertEqual(pasteboard.string(forType: .string), "Kept on the clipboard.")
        model.restoreLastTranscript(from: root.appendingPathComponent("NoRecordingsYet"))
        XCTAssertEqual(model.lastText, "")
    }

    /// A very long transcript (about 170,000 characters, two hours of talk) is copied whole, as one plain-text item: no
    /// rich text, file, image or PDF alongside it.
    func testCopyOfAVeryLongTranscriptIsExactAndPlainTextOnly() throws {
        let long = String(repeating: "A long dictated sentence with ąęłńóśźż and more words to follow. ", count: 3_000)
        XCTAssertGreaterThan(long.utf8.count, 150_000)
        let model = try launchedModel(); defer { model.shutdown() }
        model.lastText = long
        model.copyLast()
        XCTAssertEqual(pasteboard.string(forType: .string), long)
        let types = Set(pasteboard.types ?? [])
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.isDisjoint(with: [.rtf, .rtfd, .html, .tiff, .png, .pdf, .fileURL]), "plain text only: \(types)")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    /// Unicode and Polish survive the file, the restore and the clipboard with the same scalars: composed and decomposed
    /// letters, typographic quotes, CJK, an emoji flag and line breaks. Equality is compared per scalar, because String
    /// equality treats canonically equivalent forms as equal.
    func testUnicodeAndPolishTextSurviveSavingRestoringAndCopying() throws {
        let text = "Zażółć gęślą jaźń. ĄĆĘŁŃÓŚŹŻ, «cudzysłów» „Polski” — 你好 🎙️ 🇵🇱. Decomposed e\u{301} and ß.\nLine two."
        try recording("R0", minutes: 0, text: text)
        let model = try launchedModel(); defer { model.shutdown() }
        model.restoreLastTranscript(from: recordings)
        XCTAssertEqual(Array(model.lastText.unicodeScalars), Array(text.unicodeScalars), "read back from the file unchanged")
        model.copyLast()
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(Array(copied.unicodeScalars), Array(text.unicodeScalars), "the same scalars on the clipboard, not normalized")
    }
}
