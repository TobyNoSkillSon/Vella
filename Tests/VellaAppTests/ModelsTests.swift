import XCTest
import Foundation
import AppKit
@testable import Vella
@testable import VellaCore

@MainActor private final class RuntimeSpy: ModelRuntimeActions {
    var calls: [String] = []
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) { calls.append("load \(family.id) \(precision) \(path)") }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) { calls.append("reload \(family.id) \(precision) \(path)") }
    func unload(family: ModelFamily) { calls.append("unload \(family.id)") }
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool {
        calls.append("delete \(family.id)"); return delete()
    }
}

final class ModelsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }

    /// A controller over the shipped catalog with an isolated registry, selections file and benchmark fixture.
    @MainActor private func controller(benchmarks: String? = nil) throws -> ModelsController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-models-\(UUID())")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("models-installed.json")
        let resources = ModelLibrary.resourceDirectory()
        var benchmarksURL = root.appendingPathComponent("missing-benchmarks.json")
        if let benchmarks {
            benchmarksURL = root.appendingPathComponent("benchmarks.json")
            try Data(benchmarks.utf8).write(to: benchmarksURL)
        }
        return ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                benchmarksURL: benchmarksURL)
    }
    private let qwenFixture = #"""
    {"schema":1,"models":{"qwen3-asr-1.7b":{"precisions":{
      "BF16":{"wer":1.41,"speed_x":30.5,"j_per_min":6.0,"hardware":"Apple M5 Max","date":"2026-09-27"},
      "8b":{"wer":1.57,"speed_x":44.5,"j_per_min":4.0,"hardware":"Apple M5 Max","date":"2026-09-27"},
      "4b":{"wer":1.51,"speed_x":59.5,"j_per_min":3.0,"hardware":"Apple M5 Max","date":"2026-09-27"}}}}}
    """#

    @MainActor func testModelsOpensOneTableWithBothModesAndNoNestedMenus() throws {
        _ = NSApplication.shared
        let menus = ModelsMenu(controller: try controller())
        let root = menus.modelItem()
        XCTAssertEqual(root.submenu?.items.count, 1)
        let view = try XCTUnwrap(root.submenu?.items.first?.view)
        XCTAssertTrue(view.allowsVibrancy)
        XCTAssertEqual(view.frame.width, ModelTable.width)
        XCTAssertEqual(view.frame.height, ModelTable.height(menus.controller), "every row fits without scrolling")
        XCTAssertEqual(view.layer?.backgroundColor?.alpha, 0)
        XCTAssertNil(root.submenu?.items.first?.submenu)
        XCTAssertFalse(menus.controller.families(.dictation).isEmpty)
        XCTAssertFalse(menus.controller.families(.streaming).isEmpty)
        XCTAssertFalse(menus.controller.families(.dictation).contains { $0.id == "granite-4.0-1b-speech" }, "not offered")
    }

    @MainActor func testNonOfferedFamilyStaysManageableWhenDownloaded() throws {
        let c = try controller()
        c.dictation.installed["granite-4.0-1b-speech-4bit"] = InstalledModel(path: "/fixture/granite")
        XCTAssertTrue(c.families(.dictation).contains { $0.id == "granite-4.0-1b-speech" })
    }

    @MainActor func testRecommendedSelectionDeltasBaseAndPersistence() throws {
        let c = try controller(benchmarks: qwenFixture)
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        // 4b and 8b are within 0.5 pt of BF16; 4b uses the least energy.
        XCTAssertEqual(c.recommended(qwen), "4b")
        XCTAssertEqual(c.selected(qwen), "4b")
        XCTAssertEqual(c.base(qwen), "4b")
        XCTAssertEqual(errorRateDelta(c.result(qwen, "8b")?.wer, base: c.result(qwen, c.base(qwen))?.wer), Delta("+0.1 pt", .worse))
        c.preview(qwen, "BF16")
        XCTAssertEqual(c.selected(qwen), "BF16")
        // A preview is not persisted: a new controller shows the recommended precision again.
        let reopened = ModelsController(dictation: c.dictation, streaming: c.streaming, benchmarksURL: c.dictation.resources.appendingPathComponent("missing.json"))
        reopened.benchmarks = c.benchmarks
        XCTAssertEqual(reopened.selected(qwen), "4b")
    }

    @MainActor func testPreviewNeverWritesSelections() throws {
        let c = try controller()
        c.previewing = true
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        c.preview(qwen, "8b")
        XCTAssertEqual(c.selected(qwen), "8b")
        XCTAssertNil(c.configURL, "isolated: no config.json to write")
    }

    @MainActor func testRowActionsGoToTheRuntime() throws {
        let c = try controller(benchmarks: qwenFixture)
        let spy = RuntimeSpy(); c.actions = spy
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        c.dictation.installed["Qwen3-ASR-1.7B-4bit"] = InstalledModel(path: "/fixture/q4")
        c.dictation.installed["Qwen3-ASR-1.7B-bf16"] = InstalledModel(path: "/fixture/q16")
        c.runtime = TableRuntime()
        XCTAssertEqual(c.action(qwen), .load)
        c.perform(qwen)
        XCTAssertEqual(spy.calls.last, "load qwen3-asr-1.7b 4b /fixture/q4")
        c.runtime = TableRuntime(loaded: ["qwen3-asr-1.7b": LoadedFamily(precision: "4b", engine: "optimized")])
        XCTAssertEqual(c.action(qwen), .unload)
        c.perform(qwen)
        XCTAssertEqual(spy.calls.last, "unload qwen3-asr-1.7b")
        // Another precision selected for the loaded model: green Reload.
        c.preview(qwen, "BF16")
        XCTAssertEqual(c.action(qwen), .reload)
        c.perform(qwen)
        XCTAssertEqual(spy.calls.last, "reload qwen3-asr-1.7b BF16 /fixture/q16")
        // A model a dictation loaded on demand is not a pending change.
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        c.dictation.installed["parakeet-tdt-0.6b-v3-mlx-8bit"] = InstalledModel(path: "/fixture/p8")
        c.runtime = TableRuntime(loaded: ["parakeet-v3": LoadedFamily(precision: "8b", residency: "on_demand")])
        XCTAssertEqual(c.action(parakeet), .unload)
        // Not downloaded: Get.
        c.runtime = TableRuntime()
        XCTAssertEqual(c.action(try XCTUnwrap(c.catalog.family("whisper-large-v3"))), .get)
    }

    /// Rows never move when a precision is selected: every column sorts by the model's best value across precisions.
    @MainActor func testRowOrderIsStableAcrossPrecisionSelections() throws {
        let c = try controller(benchmarks: String(contentsOf: ModelLibrary.resourceDirectory().appendingPathComponent("benchmarks.json"), encoding: .utf8))
        c.previewing = true
        for mode in [RecognitionMode.dictation, .streaming] {
            for column in TableSortColumn.allCases {
                for ascending in [true, false] {
                    let before = ModelTable.rows(c, mode, sort: column, ascending: ascending).map(\.id)
                    XCTAssertEqual(Set(before), Set(c.families(mode).map(\.id) + c.references(mode).map { "reference:" + $0.id }), "sections keep their own rows")
                    for family in c.families(mode) {
                        for precision in c.options(family) {
                            c.preview(family, precision)
                            XCTAssertEqual(ModelTable.rows(c, mode, sort: column, ascending: ascending).map(\.id), before,
                                           "\(column) \(ascending): selecting \(family.id) \(precision) moved a row")
                        }
                    }
                }
            }
        }
    }

    /// Cloud reference rows: Dictation only, counted in the table height, sorted with the models by estimated WER.
    @MainActor func testCloudReferenceRowsInDictation() throws {
        let fixture = #"""
        {"schema":1,"models":{"qwen3-asr-1.7b":{"precisions":{"BF16":{"wer":15.06},"8b":{"wer":15.16}}}},
         "references":{"api":{"reference":true,"estimated":true,"name":"Cloud","mode":"dictation","wer":12.9,"range":[11.3,13.3],"source":"S"}}}
        """#
        let c = try controller(benchmarks: fixture)
        XCTAssertEqual(c.references(.dictation).map(\.id), ["api"])
        XCTAssertTrue(c.references(.streaming).isEmpty)
        XCTAssertEqual(c.rowCount, c.families(.dictation).count + c.families(.streaming).count + 1)
        let rows = ModelTable.rows(c, .dictation, sort: .wer, ascending: true)
        XCTAssertEqual(rows.first?.id, "reference:api", "12.9 estimated sorts before 15.06 measured")
        let tips = ModelTable(controller: c).tooltips(c.references(.dictation)[0])
        XCTAssertTrue(tips.contains { $0.0 == "WER" && $0.1.hasPrefix("Estimated English word error rate") && $0.1.hasSuffix("Estimate scaled from the S") })
        XCTAssertTrue(tips.contains { $0.0 == "On disk" && $0.1.contains("never sends audio") })
        XCTAssertTrue(ModelTable.werHeaderHelp.contains("Hugging Face Open ASR Leaderboard") && ModelTable.werHeaderHelp.contains("substituted, missed or added"))
        XCTAssertTrue(ModelTable.formatHeaderHelp.contains("No industry standard"))
        XCTAssertEqual(ModelTable.speedHeaderHelp, "Real-time factor (RTFx): audio seconds per processing second. Higher is faster.")
    }

    /// The Q control shows bare widths; the tooltips keep exact formats and say where each precision comes from.
    @MainActor func testQLabelsAndSegmentTooltips() throws {
        let c = try controller(benchmarks: qwenFixture)
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        XCTAssertEqual(Array(c.segmentLabels(qwen).prefix(1)), ["16"])
        XCTAssertTrue(c.segmentLabels(qwen).allSatisfy { Int($0) != nil }, "bare widths only")
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertEqual(c.segmentLabels(parakeet).first, "32")
        let bf16 = c.segmentHelp(qwen, "BF16")
        XCTAssertTrue(bf16.hasPrefix("BF16 (bfloat16) · native precision\nPublished on Hugging Face"), bf16)
        XCTAssertFalse(bf16.contains("/"), "no repository id: \(bf16)")
        XCTAssertTrue(c.segmentHelp(qwen, "4b").hasPrefix("4-bit quantized\nPublished on Hugging Face"))
        XCTAssertTrue(c.segmentHelp(qwen, "4b").contains("\nRecommended"), "the recommended segment says so")
        XCTAssertTrue(c.segmentHelp(parakeet, "FP32").contains("\nNot measured yet"), "fixture has no Parakeet figures")
        c.runtime = TableRuntime(loaded: ["qwen3-asr-1.7b": LoadedFamily(precision: "BF16")])
        XCTAssertTrue(c.segmentHelp(qwen, "8b").hasSuffix("\nLoaded at BF16 (bfloat16); Reload loads this precision instead, closing the menu keeps BF16 (bfloat16)"))
    }

    /// A precision made on this Mac: selectable, `\u{2014}` until measured, Get fetches its source, Load hands the worker
    /// the derived directory (never the source path, which is the source precision's identity).
    @MainActor func testDerivedPrecisionDisplayGetAndLoad() throws {
        let c = try controller(benchmarks: qwenFixture)   // no Ultra figures: its derived precisions are unmeasured
        let spy = RuntimeSpy(); c.actions = spy
        c.runtime = TableRuntime()
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        XCTAssertEqual(c.options(ultra), ["BF16", "8b", "4b"])
        XCTAssertEqual(c.segmentLabels(ultra), ["16", "8", "4"])
        c.preview(ultra, "4b")
        XCTAssertEqual(c.selected(ultra), "4b", "derived precisions are selectable")
        // Not measured: every figure is absent, including On disk (never the source's size, never an estimate).
        XCTAssertNil(c.result(ultra, "4b"))
        XCTAssertNil(c.disk(ultra, "4b"))
        XCTAssertNotNil(c.disk(ultra, "BF16"))
        let help = c.segmentHelp(ultra, "4b")
        XCTAssertTrue(help.hasPrefix("4-bit quantized\nMade on this Mac from the BF16 (bfloat16) weights; loading downloads those first ("), help)
        XCTAssertTrue(help.contains("\nNot measured yet"), help)
        XCTAssertFalse(help.contains("Published"), help)
        // Get downloads the source.
        XCTAssertEqual(c.action(ultra), .get)
        XCTAssertEqual(c.downloadRoot(ultra, "4b"), "BF16")
        // Source downloaded: the derived precision loads from a manifest directory of its own.
        let source = c.dictation.modelsDirectory.appendingPathComponent("parakeet-ultra-mlx-bf16")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        c.dictation.installed["parakeet-ultra-mlx-bf16"] = InstalledModel(path: source.path)
        XCTAssertEqual(c.action(ultra), .load)
        XCTAssertFalse(c.segmentHelp(ultra, "4b").contains("downloads those"), "source already downloaded")
        c.perform(ultra)
        let derivedDir = c.dictation.modelsDirectory.appendingPathComponent("parakeet-ultra-mlx-4bit-local").standardizedFileURL.path
        XCTAssertEqual(spy.calls.last, "load parakeet-v3-ultra 4b \(derivedDir)")
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: derivedDir))?.source, source.standardizedFileURL.path)
        XCTAssertNil(c.lastError)
        // Loaded at 4b, 8b selected: Reload, again through its own directory.
        c.runtime = TableRuntime(loaded: ["parakeet-v3-ultra": LoadedFamily(precision: "4b")])
        c.preview(ultra, "8b")
        XCTAssertEqual(c.action(ultra), .reload)
        c.perform(ultra)
        XCTAssertEqual(spy.calls.last, "reload parakeet-v3-ultra 8b \(c.dictation.modelsDirectory.appendingPathComponent("parakeet-ultra-mlx-8bit-local").standardizedFileURL.path)")
        // No trash for a derived precision: it holds no weights of its own.
        XCTAssertNil(c.localPath(ultra, "8b"))
    }

    @MainActor func testWithoutRuntimeTheModeSelectionReadsAsLoaded() throws {
        let c = try controller()
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        c.dictation.installed["parakeet-tdt-0.6b-v3-mlx-4bit"] = InstalledModel(path: "/fixture/p4")
        c.dictation.activeModelPath = "/fixture/p4"
        XCTAssertEqual(c.loaded(parakeet)?.precision, "4b")
        XCTAssertEqual(c.activeLabel(.dictation), "Parakeet v3 4-bit", "no 4b wording in the menu header")
        XCTAssertEqual(c.action(parakeet), .unload)
    }

    @MainActor func testMenuOrderAndTooltips() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-menu-order-\(UUID())")
        roots.append(root)
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let delegate = AppDelegate(model: model)
        delegate.modelsMenu = ModelsMenu(controller: try controller())
        delegate.factLine = { "1 model loaded · 1.3 GB in memory" }
        delegate.workersRunning = { true }
        model.lastText = "text"
        delegate.rebuildMenu()
        // The family block order (VFamily menu alignment, 28 Sep 2026), block by block between separators.
        var blocks: [[String]] = [[]]
        for item in delegate.menu.items { if item.isSeparatorItem { blocks.append([]) } else { blocks[blocks.count - 1].append(item.title) } }
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(Array(blocks[0].dropFirst()), ["1 model loaded · 1.3 GB in memory"], "header (text varies), then the fact line")
        XCTAssertEqual(Array(blocks.dropFirst()), [
            ["Models…", "Keep Hot", "Memory"],
            ["Start Dictation", "Mode", "Microphone", "Shortcuts", "Copy Last Transcript", "Open Saved Recordings"],
            ["Copy Skill for Your Agent", "Copy Diagnostics", "Open Vella Files", "Restart Worker", "Launch at Login"],
            ["Support the developer…", "Quit Vella"],
        ])
        for title in ["Mode", "Microphone", "Shortcuts", "Models…", "Keep Hot", "Memory", "Copy Skill for Your Agent", "Copy Diagnostics", "Open Vella Files", "Restart Worker"] {
            XCTAssertNotNil(delegate.menu.item(withTitle: title)?.toolTip, title)
        }
        XCTAssertEqual(delegate.menu.item(withTitle: "Restart Worker")?.toolTip, restartWorkerHelp)
        // No worker running: the same item reads Start Worker, in the same place, and starts one.
        var started = 0
        delegate.workersRunning = { false }; delegate.startWorkers = { started += 1 }
        delegate.rebuildMenu()
        XCTAssertNil(delegate.menu.item(withTitle: "Restart Worker"))
        let start = try XCTUnwrap(delegate.menu.item(withTitle: "Start Worker"))
        XCTAssertEqual(start.toolTip, startWorkerHelp)
        XCTAssertEqual(delegate.menu.items[delegate.menu.index(of: start) + 1].title, "Launch at Login")
        _ = start.target?.perform(start.action, with: start)
        XCTAssertEqual(started, 1)
        // The header keeps the loaded model and has a tooltip only when it adds something.
        XCTAssertNil(menuHeaderToolTip(failed: false, message: "Your voice, right where you need it.", needsPermission: false, idle: true, pending: nil))
        XCTAssertNil(menuHeaderToolTip(failed: false, message: "Transcribing 2/5", needsPermission: false, idle: false, pending: "why"))
        XCTAssertEqual(menuHeaderToolTip(failed: false, message: "x", needsPermission: true, idle: true, pending: nil), accessibilityHeaderHelp)
        XCTAssertEqual(menuHeaderToolTip(failed: true, message: "The worker stopped.", needsPermission: true, idle: false, pending: nil), "The worker stopped.")
        XCTAssertEqual(menuHeaderToolTip(failed: false, message: "x", needsPermission: false, idle: true, pending: "Recording kept"), "Recording kept")
        XCTAssertEqual(workerItemTitle(running: true), "Restart Worker")
        // Keep Hot choice applies through the settings source.
        let settings = DefaultMenuSettings(); delegate.menuSettings = settings
        delegate.rebuildMenu()
        let keepHot = try XCTUnwrap(delegate.menu.item(withTitle: "Keep Hot")?.submenu)
        let fiveMinutes = try XCTUnwrap(keepHot.items.first { $0.title == "5 min idle" && ($0.representedObject as? SettingsActionBox)?.action == .keepHot(.onDemand, minutes: 5) })
        _ = fiveMinutes.target?.perform(fiveMinutes.action, with: fiveMinutes)
        XCTAssertEqual(settings.onDemandIdleMinutes, 5)
        XCTAssertEqual(settings.manualIdleMinutes, 0)
    }

    @MainActor func testSavedRecordingsIsOneFolderActionWithoutHistorySubmenu() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.rebuildMenu()
        let entries = delegate.menu.items.filter { $0.title.hasPrefix("Open Saved Recordings") || $0.title.hasPrefix("Saved Recordings") }
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertNil(entry.submenu)
        XCTAssertEqual(entry.action.map(NSStringFromSelector), "savedRecordings")
        XCTAssertTrue(entry.isEnabled)
    }

    @MainActor func testAgentRequestCopiesLocalDocumentationLink() {
        let library = ModelLibrary()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(library.copyAgentRequest(to: pasteboard))
        let request = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(request.contains(library.resources.appendingPathComponent("AGENT_GUIDE.md").path))
        XCTAssertTrue(request.contains("transcription model"))
        XCTAssertTrue(request.contains("ask before switching models"))
        XCTAssertLessThan(request.count, 700)
    }
}
