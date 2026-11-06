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
            // The greyed row keeps the layout of the others: its switch, and its smallest tier (int4's measured peak).
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
            // int4 is made on this Mac from the bf16 download, as every family's lower precisions are.
            XCTAssertEqual(asked?.variantID, "nemotron-3.5-transcribe-30b-a4b-bf16")
            XCTAssertEqual(asked?.precision, "4b")
            XCTAssertEqual(asked?.downloadBytes, 67_513_686_219)
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
        for memory in [32.0, 48, 64, 128] {
            let (c, f) = try controller(memoryGB: memory)
            XCTAssertEqual(c.firstOffered(.dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3-ultra BF16", "\(memory) GB")
            XCTAssertEqual(c.firstOffer(.dictation)?.id, "parakeet-ultra-mlx-bf16")
            XCTAssertNil(c.dictation.downloadingID)
            XCTAssertNil(c.loaded(f))
            XCTAssertFalse(c.available(f, "4b"))
            // Measured 6 Nov: int4 (Fast) passes the gate vs bf16, so it is the gold cell where it fits; the row is still
            // never the first-run model and nothing downloads or loads by itself.
            XCTAssertEqual(c.recommended(f), "4b", "the benchmark's recommendation (int4 Fast passes vs bf16)")
            XCTAssertEqual(c.advice(f, mode: .fast).recommended, memory >= 48 ? .t4 : nil, "\(memory) GB: gold only where int4 fits")
            // Exact: int4 Exact fails vs bf16 (English +0.21), int8 too; bf16 is gold only where it fits (96 GB).
            XCTAssertEqual(c.advice(f, mode: .exact).recommended, memory >= 96 ? .t16 : nil, "\(memory) GB exact")
        }
        // Even with every other family removed, a Mac too small for it gets no first-run offer of it.
        let (c, f) = try controller(memoryGB: 32)
        c.catalog.families = [f]
        XCTAssertNil(c.firstOffered(.dictation))
    }

    /// Fast decodes with the MTP draft head (inexact: it can differ from plain greedy on near ties); Exact turns it off.
    /// The switch is live as on every model whose Fast differs, its tooltip says what the two mean here, and the API,
    /// the table and the worker's recipe follow the switch.
    func testTheSwitchIsLiveAndExactRunsPlainDecoding() throws {
        let (c, f) = try controller(memoryGB: 64)
        XCTAssertTrue(c.switchAvailable(f))
        XCTAssertTrue(c.exactAvailable(f), "an unmeasured family keeps Exact selectable")
        XCTAssertEqual(c.currentSelection(f).mode, .fast, "Fast by default")
        try c.setModeForControl(f, mode: .exact)
        XCTAssertEqual(c.currentSelection(f), ModelSelection(tier: .t4, mode: .exact))
        XCTAssertEqual(workerRecipe(c.selectionToCommit(f, "4b")), .optimized_exact, "Exact reaches the worker as VELLA_RECIPE optimized_exact")
        XCTAssertEqual(c.precisions(f, .exact), [.t8, .t4], "the same tiers in either position")
        let tips = Dictionary(ModelTable(controller: c).tooltips(f).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(
            tips["Exact/Fast"],
            ExactFastSwitch.help + "\nHere Exact decodes one token at a time; Fast drafts and verifies several, about 1.9× faster, differing only on near ties")
        let runtime = try Runtime.isolated(root.appendingPathComponent("api"))
        let o = ModelControls(controller: c, runtime: runtime).object(f)
        XCTAssertEqual(o["fast_equals_exact"] as? Bool, false)
        XCTAssertEqual(o["preview_selection"].flatMap { ($0 as? [String: Any])?["mode"] as? String }, "exact")
        // Only this model adds a line; a greyed row's switch says why it is greyed, not "in use".
        XCTAssertTrue(ModelRegistry.all.filter { $0.architecture != .nemotronTranscribe }.allSatisfy { $0.switchHelp == nil })
        let (small, g) = try controller(memoryGB: 32)
        let blocked = Dictionary(ModelTable(controller: small).tooltips(g).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(blocked["Exact/Fast"]?.components(separatedBy: "\n").last, "Needs 48 GB of memory")
    }

    /// Weights already on disk never start a worker over their floor: every load path passes `recipeRefusal`, the bf16
    /// download itself and the int8/int4 manifests made from it alike.
    func testWeightsOnDiskNeverLoadOverTheirFloor() throws {
        let (c, f) = try controller(memoryGB: 64)
        let runtime = try Runtime.isolated(root.appendingPathComponent("runtime"))
        let model = DictationController(configurationURL: runtime.configURL, monitorDefaultInput: false); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime); bridge.attach(controller: c, model: model)
        let folder = c.dictation.modelsDirectory.appendingPathComponent(f.variants["BF16"]!.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"model_type": "nemo_speechlm", "architectures": ["Nemotron3_5TranscribeForConditionalGeneration"]}"#.utf8)
            .write(to: folder.appendingPathComponent("config.json"))
        c.dictation.installed[f.variants["BF16"]!.id] = InstalledModel(path: folder.path)
        XCTAssertTrue(c.available(f, "4b")); XCTAssertTrue(c.available(f, "8b"))
        let int8 = try XCTUnwrap(
            try precisionLoadPath(f, "8b", installedPath: { c.dictation.installed[$0]?.path }, modelsDirectory: c.dictation.modelsDirectory))
        XCTAssertEqual(
            bridge.recipeRefusal(path: folder.path, mode: .dictation),
            "Nemotron 3.5 Transcribe at bf16 needs 96 GB of memory; this Mac has 64 GB. Pick a smaller precision in Vella → Models…")
        XCTAssertNil(bridge.recipeRefusal(path: int8, mode: .dictation))
        c.physicalMemoryBytes = 32 * 1_073_741_824
        XCTAssertEqual(
            bridge.recipeRefusal(path: int8, mode: .dictation),
            "Nemotron 3.5 Transcribe at int8 needs 64 GB of memory; this Mac has 32 GB. Pick a smaller precision in Vella → Models…")
        c.physicalMemoryBytes = 128 * 1_073_741_824
        XCTAssertNil(bridge.recipeRefusal(path: folder.path, mode: .dictation))
    }

    /// A cell whose energy the macOS 27 meter could not measure says why instead of "Not measured at this precision"
    /// (night 6 Nov: GPU-only meter without administrator rights).
    func testEnergyTooltipStatesWhyItIsMissing() {
        let r = PrecisionResult(wer: 14.6, note: "Energy not measured: on macOS 27 the energy meter reads only the GPU without administrator rights. GPU-only 89.1 J/min.")
        XCTAssertEqual(energyHelp(r, suites: nil), "Energy not measured: on macOS 27 the energy meter reads only the GPU without administrator rights")
        XCTAssertEqual(energyHelp(PrecisionResult(wer: 14.6), suites: nil), notMeasuredHelp)
    }
}
