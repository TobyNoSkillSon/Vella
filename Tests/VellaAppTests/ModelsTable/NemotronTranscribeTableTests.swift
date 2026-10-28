import XCTest
@testable import Vella
@testable import VellaCore

/// Nemotron 3.5 Transcribe in the Models table on Macs of different memory (the controller over the shipped catalog,
/// an empty registry, no worker): which tiers it offers, what Get asks for, and that nothing happens without the user.
@MainActor final class NemotronTranscribeTableTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-nt-table-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func controller(memoryGB: Double) throws -> (ModelsController, ModelFamily) {
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("models-installed.json")
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: root.appendingPathComponent("config.json"))
        c.gpu = RecommendedDefaultTests.m5; c.benchmarkHardware = .measured
        c.runtime = TableRuntime()
        c.physicalMemoryBytes = UInt64(memoryGB * 1_073_741_824)
        return (c, try XCTUnwrap(c.catalog.family("nemotron-3.5-transcribe")))
    }

    func testUnderFortyEightGBTheRowIsGreyedAndGetAsksNothing() throws {
        for memory in [16.0, 32, 36, 47.9] {
            let (c, f) = try controller(memoryGB: memory)
            XCTAssertTrue(c.families(.dictation).contains(f), "the row stays, greyed")
            XCTAssertEqual(c.memoryRefusal(f), "Needs 48 GB of memory", "\(memory) GB")
            var asked = false
            c.confirmDownload = { _, answer in asked = true; answer(nil) }
            c.perform(f)
            XCTAssertFalse(asked, "\(memory) GB: no download prompt")
            XCTAssertEqual(c.lastError, "Nemotron 3.5 Transcribe: Needs 48 GB of memory.")
            XCTAssertNil(c.dictation.downloadingID)
            XCTAssertEqual(c.firstOffered(.dictation)?.family.id, "parakeet-v3-ultra")
            // The greyed row keeps the layout of the others: its switch, and its smallest tier (int4's 24.7 GB peak).
            XCTAssertTrue(c.hasOptimizedPath(f))
            XCTAssertEqual(c.selected(f), "4b")
        }
    }

    func testEachTierAppearsAtItsFloorAndGetAsksForThatTiersDownload() throws {
        let floors: [(Double, [String: String])] = [
            (48, ["16": "Needs 96 GB of memory", "8": "Needs 64 GB of memory"]), (64, ["16": "Needs 96 GB of memory"]), (96, [:]), (128, [:])
        ]
        for (memory, greyed) in floors {
            let (c, f) = try controller(memoryGB: memory)
            XCTAssertNil(c.memoryRefusal(f), "\(memory) GB")
            XCTAssertEqual(ModelTable(controller: c).unavailableCells(f), greyed, "\(memory) GB")
            // Nothing chosen yet: int4, the catalog default, and Get.
            XCTAssertEqual(c.selected(f), "4b", "\(memory) GB")
            XCTAssertEqual(c.action(f), .get)
            var asked: DownloadPrompt?
            c.confirmDownload = { prompt, answer in asked = prompt; answer(nil) }
            c.perform(f)
            XCTAssertEqual(asked?.variantID, "nemotron-3.5-transcribe-30b-a4b-mlx-q4mix")
            XCTAssertEqual(asked?.downloadBytes, 21_815_377_547)
            XCTAssertNil(c.dictation.downloadingID, "Cancel downloads nothing")
            XCTAssertNil(c.config?.selections[f.id], "nothing written")
        }
        // On 128 GB the user can pick bf16; Get then asks for NVIDIA's 67.5 GB download.
        let (c, f) = try controller(memoryGB: 128)
        c.select(f, tier: .t16)
        XCTAssertEqual(c.selected(f), "BF16")
        var asked: DownloadPrompt?
        c.confirmDownload = { prompt, answer in asked = prompt; answer(nil) }
        c.perform(f)
        XCTAssertEqual(asked?.variantID, "nemotron-3.5-transcribe-30b-a4b-bf16")
        XCTAssertEqual(asked?.downloadBytes, 67_513_686_219)
        // On 64 GB bf16 cannot be chosen at all.
        let (small, g) = try controller(memoryGB: 64)
        small.select(g, tier: .t16)
        XCTAssertEqual(small.selected(g), "4b")
    }

    func testNeverTheFirstRunModelAndNeverFetchedOrLoadedByItself() throws {
        for memory in [32.0, 64, 128] {
            let (c, f) = try controller(memoryGB: memory)
            XCTAssertEqual(c.firstOffered(.dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3-ultra BF16", "\(memory) GB")
            XCTAssertEqual(c.firstOffer(.dictation)?.id, "parakeet-ultra-mlx-bf16")
            XCTAssertNil(c.dictation.downloadingID)
            XCTAssertNil(c.loaded(f))
            XCTAssertFalse(c.available(f, "4b"))
            XCTAssertNil(c.recommended(f), "no benchmark, no gold cell")
        }
        // Even with every other family removed, a Mac too small for it gets no first-run offer of it.
        let (c, f) = try controller(memoryGB: 32)
        c.catalog.families = [f]
        XCTAssertNil(c.firstOffered(.dictation))
    }

    /// No separately qualified fast path (the worker's `hasFastPath` is false): the switch is greyed and pinned to Fast,
    /// the table, the API (`fast_equals_exact`) and a mode request (409) say so, as for any model where Fast = Exact.
    func testFastEqualsExactSoTheSwitchIsPinned() throws {
        let (c, f) = try controller(memoryGB: 64)
        XCTAssertFalse(NemotronTranscribeDescriptor.descriptor.hasFastPath)
        XCTAssertTrue(ModelRegistry.all.filter { $0.architecture != .nemotronTranscribe }.allSatisfy(\.hasFastPath))
        XCTAssertFalse(c.switchAvailable(f))
        XCTAssertTrue(c.hasOptimizedPath(f), "the switch is drawn, greyed")
        XCTAssertEqual(c.currentSelection(f).mode, .fast)
        XCTAssertEqual(c.precisions(f, .exact), c.precisions(f, .fast), "both positions offer the same tiers")
        XCTAssertThrowsError(try c.setModeForControl(f, mode: .exact)) { XCTAssertEqual(($0 as? APIError)?.message, ExactFastSwitch.sameHelp) }
        let tips = Dictionary(ModelTable(controller: c).tooltips(f).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tips["Exact/Fast"], ExactFastSwitch.tooltip(available: false, enabled: true))
        let runtime = try Runtime.isolated(root.appendingPathComponent("api"))
        let o = ModelControls(controller: c, runtime: runtime).object(f)
        XCTAssertEqual(o["fast_equals_exact"] as? Bool, true)
        XCTAssertEqual((o["selection"] as? [String: Any])?["mode"] as? String, "fast")
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        XCTAssertEqual(ModelControls(controller: c, runtime: runtime).object(parakeet)["fast_equals_exact"] as? Bool, !c.switchAvailable(parakeet))
    }

    /// Weights already on disk never start a worker over their floor: every load path passes `recipeRefusal`.
    func testWeightsOnDiskNeverLoadOverTheirFloor() throws {
        let (c, f) = try controller(memoryGB: 64)
        let runtime = try Runtime.isolated(root.appendingPathComponent("runtime"))
        let model = DictationController(configurationURL: runtime.configURL, monitorDefaultInput: false); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime); bridge.attach(controller: c, model: model)
        func install(_ label: String) throws -> String {
            let folder = root.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"model_type": "nemotron_transcribe"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
            c.dictation.installed[f.variants[label]!.id] = InstalledModel(path: folder.path)
            return folder.path
        }
        let bf16 = try install("BF16"), int8 = try install("8b")
        XCTAssertEqual(
            bridge.recipeRefusal(path: bf16, mode: .dictation),
            "Nemotron 3.5 Transcribe at bf16 needs 96 GB of memory; this Mac has 64 GB. Pick a smaller precision in Vella → Models…")
        XCTAssertNil(bridge.recipeRefusal(path: int8, mode: .dictation))
        c.physicalMemoryBytes = 32 * 1_073_741_824
        XCTAssertNotNil(bridge.recipeRefusal(path: int8, mode: .dictation))
        c.physicalMemoryBytes = 128 * 1_073_741_824
        XCTAssertNil(bridge.recipeRefusal(path: bf16, mode: .dictation))
    }
}
