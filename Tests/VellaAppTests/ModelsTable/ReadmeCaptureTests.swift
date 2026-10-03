import XCTest
import AppKit
import VellaTestSupport
import VellaUpdate
@testable import Vella
@testable import VellaCore

/// Opt-in documentation capture using the existing native table's offscreen first-frame renderer.
/// No menu tracking, screen capture, activation, cursor movement, synthetic hover or runtime/model load.
final class ReadmeCaptureTests: XCTestCase {
    @MainActor func testPrivacyHelpStatesTheNetworkBoundary() {
        XCTAssertTrue(AppDelegate.privacyHelp.contains("audio and transcripts never leave your Mac"))
        XCTAssertTrue(AppDelegate.privacyHelp.contains("GitHub releases API at most once a day (at launch when due)"))
        XCTAssertTrue(AppDelegate.privacyHelp.contains("only when you ask"))
        XCTAssertTrue(AppDelegate.privacyHelp.contains("No telemetry"))
    }

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

extension ReadmeCaptureTests {
    @MainActor func testCaptureEveryFinalTableAndMenuStateOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["VELLA_FINAL_REVIEW"] else { throw XCTSkip("Opt-in final UI review") }
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var files: [String] = []
        func capture(_ view: NSView, name: String) throws {
            view.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
            defer { window.contentView = nil }
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
            files.append(name + ".png")
        }
        var states = TableRenderDelegate.states()
        let reference = TableRenderDelegate.controller(.init(name: "reference", installed: []))
        for family in reference.catalog.families {
            for tier in ModelTier.allCases {
                for path in EnginePath.allCases {
                    for mode in path == .standard ? [OptimizedMode.fast] : OptimizedMode.allCases {
                        let selection = ModelSelection(tier: tier, path: path, mode: mode)
                        guard reference.rules(family).cellRefusal(selection, loaded: nil) == nil else { continue }
                        states.append(.init(name: "cell-\(family.id)-\(tier.rawValue)-\(selection.segmentKey.rawValue)", selections: [family.id: selection]))
                    }
                }
            }
        }
        for state in states {
            let controller = TableRenderDelegate.controller(state)
            let name = "models-" + state.name
            TableRenderDelegate.renderFirstFrame(controller, to: out.appendingPathComponent(name + ".png"), check: out.appendingPathComponent(name + ".layout.txt"))
            XCTAssertNotNil(NSImage(contentsOf: out.appendingPathComponent(name + ".png")))
            files.append(name + ".png")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VellaFinalReview.\(UUID())"))
        let model = DictationController(
            insertionPermission: InsertionPermission(isTrusted: { true }, prompt: {}), configurationURL: out.appendingPathComponent("unused-config.json"))
        defer { model.shutdown() }
        let updates = UpdateController(current: nil, defaults: defaults, enabled: false)
        let app = AppDelegate(model: model, updates: updates)
        app.modelsMenu = ModelsMenu(controller: reference)
        app.runtimeLoading = { nil }; app.modelsLoaded = { false }; app.workersRunning = { false }
        app.pendingModelRow = { nil }; app.factLine = { nil }
        let menuStates: [(String, DictationController.Phase)] = [
            ("ready", .idle), ("preparing", .preparing), ("recording", .recording), ("transcribing", .transcribing), ("success", .success), ("failed", .failed)
        ]
        for (name, phase) in menuStates {
            model.update(phase, phase == .failed ? "Fixture error; recording kept" : "")
            app.rebuildMenu()
            try capture(MenuMock(items: app.menu.items, width: 340), name: "menu-" + name)
        }
        model.update(.idle, "")
        for (name, settings) in [
            ("default", DefaultMenuSettings(availableMB: 86_900)),
            ("tight", DefaultMenuSettings(availableMB: 900, lastEvicted: "Nemotron 3.5 Streaming")),
            ("custom", DefaultMenuSettings(manualIdleMinutes: 60, onDemandIdleMinutes: 5, allowSwap: true, availableMB: 42_100))
        ] {
            app.menuSettings = settings; app.rebuildMenu()
            try capture(MenuMock(items: app.menu.items, width: 340), name: "menu-settings-" + name)
            func captureSubmenus(_ menu: NSMenu, prefix: String) throws {
                for item in menu.items {
                    guard let submenu = item.submenu, item.title != "Models…" else { continue }
                    let key = item.title.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "…", with: "")
                    let child = prefix + "-" + key
                    try capture(MenuMock(items: submenu.items, width: 340), name: child)
                    try captureSubmenus(submenu, prefix: child)
                }
            }
            try captureSubmenus(app.menu, prefix: "menu-" + name)
        }
        app.workersRunning = { true }
        app.factLine = { "1 model loaded · 1.3 GB in memory" }
        app.rebuildMenu()
        try capture(MenuMock(items: app.menu.items, width: 340), name: "menu-worker-loaded")
        app.workersRunning = { false }; app.factLine = { nil }
        app.pendingModelRow = { reference.firstOffer(.dictation).map { ($0.title, $0.help) } }
        app.rebuildMenu()
        try capture(MenuMock(items: app.menu.items, width: 340), name: "menu-first-dictation-get")
        app.pendingModelRow = { nil }
        let release = MenuRenderDelegate.sampleRelease
        let updateStates: [(String, UpdatePhase)] = [
            ("available", .available(release)), ("downloading", .downloading(release)),
            ("waiting-for-idle", .waitingForIdle(release)), ("installing", .installing(release))
        ]
        for (name, phase) in updateStates {
            updates.preview(phase); app.rebuildMenu()
            try capture(MenuMock(items: app.menu.items, width: 340), name: "menu-update-" + name)
        }
        let tips = app.menu.items.compactMap { item in item.toolTip.map { (item.title, $0) } }
        try capture(TooltipSheet(pairs: tips, width: 520), name: "menu-tooltips")
        let switchTips = [("Exact / Fast", ExactFastSwitch.help)]
        try capture(TooltipSheet(pairs: switchTips, width: 520), name: "models-exact-fast-tooltip")
        try
            ("Offscreen native table + NSMenu item drawing (MenuMock), no screen/cursor/activation, no inference, downloads or live support writes.\n"
            + files.sorted().joined(separator: "\n") + "\n")
            .write(to: out.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(files.count, 50)
    }
}
