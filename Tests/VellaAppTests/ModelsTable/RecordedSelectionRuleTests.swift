import XCTest
@testable import Vella
@testable import VellaCore

/// One rule for what a recorded selection runs (QA 30 Sep): the table, the runtime's on-demand loads and the API agree,
/// and a recorded cell that is not measured or a precision no longer offered never runs. A loaded model keeps its cell.
@MainActor final class RecordedSelectionRuleTests: XCTestCase {
    private var root: URL!
    private var runtime: Runtime!
    private var controller: ModelsController!
    private var bridge: RuntimeBridge!
    private var source: ControllerModelSource!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-rule-\(UUID().uuidString)")
        runtime = try Runtime.isolated(root)
        let resources = ModelLibrary.resourceDirectory()
        let registry = runtime.support.appendingPathComponent("models-installed.json")
        let dictation = ModelLibrary(
            mode: .dictation, resources: resources, registryURL: registry,
            calibration: CalibrationStore(directory: root.appendingPathComponent("Cal"), resources: resources))
        controller = ModelsController(
            dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry), configURL: runtime.configURL)
        bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: DictationController(configurationURL: runtime.configURL, backend: Backend(runtime: runtime)))
        source = ControllerModelSource(controller: controller, runtime: runtime)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func family(_ id: String) throws -> ModelFamily { try XCTUnwrap(controller.catalog.family(id)) }
    /// A registered download (a folder with a config.json).
    @discardableResult private func install(_ variant: String) throws -> String {
        let folder = root.appendingPathComponent("Models/\(variant)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        controller.dictation.installed[variant] = InstalledModel(path: folder.path)
        return folder.path
    }
    private func derived(_ f: ModelFamily, _ precision: String, from sourcePath: String) throws -> String {
        try prepareDerivedModel(family: f, precision: precision, sourcePath: sourcePath, modelsDirectory: controller.dictation.modelsDirectory)
    }
    private func record(model: String = "", family: String, precision: String, _ selection: ModelSelection) throws {
        var config = Configuration(model: model)
        config.lastLoaded[family] = precision; config.selections[family] = selection
        try JSONEncoder().encode(config).write(to: runtime.configURL)
        controller.reloadConfig()
    }

    func testShippedWhisperStandardAndExactAreGreyedButLoadedStandardStaysSelectable() throws {
        for id in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            let whisper = try family(id)
            let standard = ModelSelection(tier: .t16, path: .standard, mode: .fast)
            XCTAssertFalse(controller.measured(whisper, standard))
            XCTAssertFalse(controller.exactAvailable(whisper))
            XCTAssertTrue(controller.rules(whisper).cellRefusal(standard, loaded: controller.loadedSelection(whisper))?.hasPrefix("Not measured yet: Standard") == true)
            let path = try install(try XCTUnwrap(whisper.variants["FP16"]?.id))
            let loaded = bridge.ref(whisper, "FP16", path: path, selection: standard)
            runtime.register(loaded, residency: .manual) {}
            XCTAssertNil(controller.rules(whisper).cellRefusal(standard, loaded: controller.loadedSelection(whisper)))
            controller.select(whisper, tier: .t16, path: .standard)
            XCTAssertEqual(controller.currentSelection(whisper).path, .standard)
            let api = try XCTUnwrap(source.models().first { $0.id == id })
            XCTAssertEqual(api.selection?.path, .standard)
        }
    }

    /// Qwen3-ASR 0.6B recorded at Standard 8, a cell with no measurement ("Not measured yet" in the table): the table,
    /// the API and a request for its files all run Optimized 8 Exact.
    func testUnmeasuredRecordedCellRunsTheTablesCellEverywhere() throws {
        let qwen = try family("qwen3-asr-0.6b")
        let bf16 = try install("Qwen3-ASR-0.6B-bf16")
        let eight = try derived(qwen, "8b", from: bf16)
        let stored = ModelSelection(tier: .t8, path: .standard, mode: .exact)
        // Keep the regression fixture unmeasured even after the release file measures this cell.
        controller.benchmarks.models[qwen.id]?.tiers[.t8]?.cells[.standard]?.measured = nil
        XCTAssertFalse(controller.measured(qwen, stored), "fixture: Standard 8 is not measured")
        let expected = ModelSelection(tier: .t8, path: .optimized, mode: .exact)
        for model in ["", eight] { // not the dictation model, then the dictation model
            try record(model: model, family: qwen.id, precision: "8b", stored)
            XCTAssertEqual(controller.committedSelection(qwen), expected)
            XCTAssertEqual(controller.committed(qwen), "8b")
            let api = try XCTUnwrap(source.models().first { $0.id == qwen.id })
            XCTAssertEqual(api.selection, expected); XCTAssertNil(api.requested); XCTAssertEqual(api.precision, "8b")
            XCTAssertEqual(api.current, !model.isEmpty)
            let request = try XCTUnwrap(bridge.ref(path: eight, mode: .dictation))
            XCTAssertEqual(request.selection, expected); XCTAssertEqual(request.path, eight)
        }
    }

    /// An upgrade whose last load was Parakeet v3 8 (no longer offered: tiers_offered is 16): the row, the API's current
    /// model, a dictation of it and the header all use 16; the 8-bit files never load. Loaded (the launch set of the
    /// earlier version, say), the 8-bit cell stays and is used as loaded.
    func testWithdrawnRecordedPrecisionRunsAnOfferedOneUntilItIsLoaded() throws {
        var parakeet = try family("parakeet-v3")
        // Exercise the upgrade rule independently of today's offered tiers.
        parakeet.tiersOffered = ["16"]
        controller.catalog.families[try XCTUnwrap(controller.catalog.families.firstIndex { $0.id == parakeet.id })] = parakeet
        XCTAssertFalse(precisionOptions(parakeet).contains("8b"), "fixture: Parakeet v3 8 is withdrawn")
        try install("parakeet-tdt-0.6b-v3-mlx-fp32")
        let bf16 = try install("parakeet-tdt-0.6b-v3-mlx-bf16-local")
        let eight = try derived(parakeet, "8b", from: bf16)
        let recorded = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        try record(model: eight, family: parakeet.id, precision: "8b", recorded)
        let expected = controller.valid(parakeet, ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        XCTAssertEqual(expected.tier, .t16)

        XCTAssertEqual(controller.committed(parakeet), "BF16")
        XCTAssertEqual(controller.committedSelection(parakeet), expected)
        let api = try XCTUnwrap(source.models().first { $0.id == parakeet.id })
        XCTAssertEqual(api.precision, "BF16"); XCTAssertEqual(api.path, bf16); XCTAssertTrue(api.current)
        XCTAssertEqual(api.selection, expected)
        let request = try XCTUnwrap(bridge.ref(path: eight, mode: .dictation), "a dictation recorded with the 8-bit files")
        XCTAssertEqual(request.precision, "BF16"); XCTAssertEqual(request.path, bf16); XCTAssertEqual(request.selection, expected)
        controller.dictation.activeModelPath = eight
        XCTAssertEqual(controller.activeLabel(.dictation), "\(parakeet.name) bf16")

        // Loaded at 8 (an earlier version's launch set): that cell is what runs and what everyone reports.
        let loaded = bridge.ref(parakeet, "8b", path: eight, selection: recorded)
        runtime.register(loaded, residency: .manual) {}
        XCTAssertEqual(bridge.ref(path: eight, mode: .dictation)?.precision, "8b")
        XCTAssertEqual(controller.committed(parakeet), "8b")
        let apiLoaded = try XCTUnwrap(source.models().first { $0.id == parakeet.id })
        XCTAssertEqual(apiLoaded.precision, "8b"); XCTAssertTrue(apiLoaded.loaded)
    }

    /// Legacy published quants remain files, never measured tier identities. Without the high-precision root,
    /// table and API offer Get; with it, requests resolve through the offered local recipe.
    func testLegacyPublishedQuantWithoutOfferedWeightsNeedsGetAndNeverRunsAsAMeasuredTier() throws {
        let parakeet = try family("whisper-large-v3-turbo")
        let four = try install("whisper-large-v3-turbo-asr-4bit")
        try record(model: four, family: parakeet.id, precision: "4b", ModelSelection(tier: .t4, path: .optimized, mode: .fast))
        XCTAssertEqual(controller.committed(parakeet), "FP16")
        XCTAssertEqual(controller.committedSelection(parakeet).tier, .t16)
        XCTAssertNil(source.models().first { $0.id == parakeet.id })
        XCTAssertNil(bridge.ref(path: four, mode: .dictation))
        XCTAssertTrue(FileManager.default.fileExists(atPath: four + "/config.json"))
        // Once the offered 16 is downloaded, the 4-bit files stop being used.
        let bf16 = try install("whisper-large-v3-turbo-asr-fp16")
        XCTAssertEqual(controller.committed(parakeet), "FP16")
        XCTAssertEqual(bridge.ref(path: four, mode: .dictation)?.path, bf16)
        XCTAssertEqual(source.models().first { $0.id == parakeet.id }?.path, bf16)
    }
}
