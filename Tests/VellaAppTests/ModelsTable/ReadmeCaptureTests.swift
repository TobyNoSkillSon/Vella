import XCTest
import AppKit
import VellaTestSupport
@testable import Vella
@testable import VellaCore

/// Opt-in documentation capture using the existing native table's offscreen first-frame renderer.
/// No menu tracking, screen capture, activation, cursor movement, synthetic hover or runtime/model load.
final class ReadmeCaptureTests: XCTestCase {
    @MainActor func testCaptureFinalModelsTableOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["VELLA_README_CAPTURE"] else { throw XCTSkip("Opt-in README capture") }
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let controller = TableRenderDelegate.controller(.init(name: "final-readme", installed: []))
        XCTAssertFalse(controller.benchmarks.figuresPending)
        XCTAssertTrue(controller.catalog.family("parakeet-v3")?.tiersOffered?.contains("8") == true)
        for id in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            let family = try XCTUnwrap(controller.catalog.family(id))
            XCTAssertNil(controller.baseResult(family), "No withdrawn Standard comparison in the capture")
            XCTAssertNotNil(controller.shownResult(family)?.speed_x)
        }
        TableRenderDelegate.renderFirstFrame(controller, to: out.appendingPathComponent("models-current.png"), check: out.appendingPathComponent("layout.txt"))
        let image = try XCTUnwrap(NSImage(contentsOf: out.appendingPathComponent("models-current.png")))
        XCTAssertEqual(image.size.width, ModelTable.width)
        XCTAssertGreaterThan(image.size.height, 400)
    }
}

extension ReadmeCaptureTests {
    @MainActor func testCaptureFinalMenuOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["VELLA_README_CAPTURE"] else { throw XCTSkip("Opt-in README capture") }
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: folder)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VellaReadmeCapture.\(UUID())"))
        let model = DictationController(
            insertionPermission: InsertionPermission(isTrusted: { true }, prompt: {}), configurationURL: out.appendingPathComponent("unused-config.json"))
        defer { model.shutdown() }
        let app = AppDelegate(model: model, updates: UpdateController(current: nil, defaults: defaults, enabled: false))
        app.modelsMenu = ModelsMenu(controller: TableRenderDelegate.controller(.init(name: "fresh-menu", installed: [])))
        app.pendingModelRow = { nil }; app.factLine = { nil }; app.workersRunning = { false }
        model.lastText = "Rendered transcript"
        app.rebuildMenu()
        XCTAssertEqual(app.menu.items.first?.title, "Dictation: ready")
        XCTAssertFalse(app.menu.items.contains { $0.title.contains("4-bit") || $0.title.contains("GB in memory") })
        let view = MenuMock(items: app.menu.items, width: 340)
        view.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("menu-current.png"))
        window.contentView = nil
    }
}
