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
                                benchmarksURL: benchmarksURL, selectionsURL: root.appendingPathComponent("model-precision.json"))
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
        c.setPrecision(qwen, "BF16")
        XCTAssertEqual(c.selected(qwen), "BF16")
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: c.selectionsURL))
        XCTAssertEqual(saved["qwen3-asr-1.7b"], nativeSelection, "native is stored as a sentinel")
        let reopened = ModelsController(dictation: c.dictation, streaming: c.streaming, selectionsURL: c.selectionsURL)
        XCTAssertEqual(reopened.selected(qwen), "BF16")
    }

    @MainActor func testPreviewNeverWritesSelections() throws {
        let c = try controller()
        c.previewing = true
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        c.setPrecision(qwen, "8b")
        XCTAssertEqual(c.selected(qwen), "8b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.selectionsURL.path))
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
        c.setPrecision(qwen, "BF16")
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
                    XCTAssertEqual(Set(before), Set(c.families(mode).map(\.id)), "sections keep their own rows")
                    for family in c.families(mode) {
                        for precision in c.options(family) {
                            c.setPrecision(family, precision)
                            XCTAssertEqual(ModelTable.rows(c, mode, sort: column, ascending: ascending).map(\.id), before,
                                           "\(column) \(ascending): selecting \(family.id) \(precision) moved a row")
                        }
                    }
                }
            }
        }
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
        XCTAssertTrue(bf16.hasPrefix("BF16 (bfloat16), the model's native precision. Published: mlx-community/Qwen3-ASR-1.7B-bf16."), bf16)
        XCTAssertTrue(c.segmentHelp(qwen, "4b").hasPrefix("4-bit quantized. Published:"))
        XCTAssertTrue(c.segmentHelp(qwen, "4b").contains("Recommended"), "the recommended segment says so")
        XCTAssertTrue(c.segmentHelp(parakeet, "FP32").contains("Not measured yet."), "fixture has no Parakeet figures")
        c.runtime = TableRuntime(loaded: ["qwen3-asr-1.7b": LoadedFamily(precision: "BF16")])
        XCTAssertTrue(c.segmentHelp(qwen, "8b").hasSuffix("Loaded at BF16 (bfloat16); Reload applies the selection."))
    }

    @MainActor func testWithoutRuntimeTheModeSelectionReadsAsLoaded() throws {
        let c = try controller()
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        c.dictation.installed["parakeet-tdt-0.6b-v3-mlx-4bit"] = InstalledModel(path: "/fixture/p4")
        c.dictation.activeModelPath = "/fixture/p4"
        XCTAssertEqual(c.loaded(parakeet)?.precision, "4b")
        XCTAssertEqual(c.activeLabel(.dictation), "Parakeet v3 4b")
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
        model.lastText = "text"
        delegate.rebuildMenu()
        let titles = delegate.menu.items.filter { !$0.isSeparatorItem }.map(\.title).dropFirst()   // header text varies
        XCTAssertEqual(Array(titles), ["1 model loaded · 1.3 GB in memory", "Start Dictation", "Mode", "Microphone", "Shortcuts",
                                       "Models…", "Keep Hot", "Memory",
                                       "Copy Last Transcript", "Open Saved Recordings", "Open Vella Files", "Restart Worker", "Launch at Login",
                                       "Support the developer…", "Quit Vella"])
        for title in ["Mode", "Microphone", "Shortcuts", "Models…", "Keep Hot", "Memory", "Open Vella Files", "Restart Worker"] {
            XCTAssertNotNil(delegate.menu.item(withTitle: title)?.toolTip, title)
        }
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
