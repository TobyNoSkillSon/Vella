import XCTest
@testable import Vella
@testable import VellaCore

/// A family nothing was chosen for (no saved selection, no recorded precision, no launch-set load) previews, offers and
/// loads the precision recommended for this Mac at Fast (Toby, 15 Oct: "we want to suggest them the most efficient
/// model ... they just may not know"); 16 · Fast without a recommendation. A saved choice is never overridden.
@MainActor final class RecommendedDefaultTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-recommended-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static let m5 = GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)
    static let m4 = GPUCapability(appleFamily: 9, architecture: "applegpu_g16s", osMajor: 26, osMinor: 6)

    private var configURL: URL { root.appendingPathComponent("config.json") }

    /// The shipped catalog and benchmarks, an empty registry (a fresh install), and `config` as config.json.
    private func controller(gpu: GPUCapability, hardware: BenchmarkHardware, config: Configuration? = nil) throws -> ModelsController {
        if let config { try JSONEncoder().encode(config).write(to: configURL) }
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("models-installed.json")
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: configURL)
        c.gpu = gpu; c.benchmarkHardware = hardware
        c.runtime = TableRuntime()
        return c
    }

    func testFreshInstallOnAnM5PreviewsAndOffersParakeetV3Int8() throws {
        let c = try controller(gpu: Self.m5, hardware: .measured)
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertEqual(c.recommendedTier(parakeet), .t8)
        XCTAssertEqual(c.currentSelection(parakeet), ModelSelection(tier: .t8, mode: .fast), "the gold cell, Fast")
        XCTAssertEqual(c.selected(parakeet), "8b")
        XCTAssertNil(c.config?.selections[parakeet.id], "a default, nothing written")
        XCTAssertEqual(c.action(parakeet), .get)
        // Get asks for what that precision needs: its source's download, then loads int8 (made on this Mac).
        var asked: DownloadPrompt?
        c.confirmDownload = { prompt, answer in
            asked = prompt; answer(nil)
        }
        c.perform(parakeet)
        XCTAssertEqual(asked?.precision, "8b")
        XCTAssertEqual(asked?.variantID, parakeet.downloadSource(of: "8b")?.variant.id)
        XCTAssertEqual(c.selectionToCommit(parakeet, "8b"), ModelSelection(tier: .t8, mode: .fast))
        // The other families' gold cells: Whisper turbo int8; 16-bit where int8 loses accuracy.
        XCTAssertEqual(c.selected(try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))), "8b")
        for id in ["parakeet-v3-ultra", "qwen3-asr-1.7b", "whisper-large-v3", "nemotron-3.5-streaming-0.6b"] {
            let family = try XCTUnwrap(c.catalog.family(id))
            XCTAssertEqual(c.currentSelection(family), ModelSelection(tier: .t16, mode: .fast), id)
            XCTAssertEqual(c.currentSelection(family).tier, c.advice(family).recommended, "\(id): the default is the gold cell")
        }
        // The first-dictation Get row offers the first family at its recommended precision.
        XCTAssertEqual(c.firstOffered(.dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3-ultra BF16", "Ultra's int8 fails the gate")
        let ultra = c.catalog.families.removeFirst()
        c.catalog.families.insert(ultra, at: 1) // Parakeet v3 first
        XCTAssertEqual(c.firstOffered(.dictation).map { "\($0.family.id) \($0.precision)" }, "parakeet-v3 8b")
        XCTAssertEqual(c.firstOffer(.dictation)?.id, parakeet.downloadSource(of: "8b")?.variant.id, "the Get row downloads int8's source")
    }

    func testFreshInstallOnAnM4StaysOn16Bit() throws {
        let c = try controller(gpu: Self.m4, hardware: BenchmarkHardware(chip: "Apple M4 Pro", gpuCores: 20))
        for family in c.families(.dictation) + c.families(.streaming) {
            XCTAssertEqual(c.recommendedTier(family), .t16, family.id)
            XCTAssertEqual(c.currentSelection(family), .fallback, "\(family.id): no matrix hardware for int8/int4 here")
        }
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertEqual(c.selected(parakeet), "BF16")
        XCTAssertEqual(c.firstOffered(.dictation)?.precision, "BF16")
    }

    func testPendingFiguresFallBackTo16() throws {
        let c = try controller(gpu: Self.m5, hardware: .measured)
        c.benchmarks.figuresPending = true
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertNil(c.recommendedTier(parakeet))
        XCTAssertEqual(c.currentSelection(parakeet), .fallback)
    }

    /// A saved choice wins on the M5 too: a recorded selection, a recorded precision alone, and the mode's model.
    func testSavedChoicesAreNeverOverridden() throws {
        var config = Configuration(model: "")
        config.selections["parakeet-v3"] = ModelSelection(tier: .t16, mode: .exact)
        config.lastLoaded["whisper-large-v3-turbo"] = "FP16"
        config.selections["qwen3-asr-0.6b"] = ModelSelection(tier: .t16, mode: .fast)
        let c = try controller(gpu: Self.m5, hardware: .measured, config: config)
        XCTAssertEqual(c.currentSelection(try XCTUnwrap(c.catalog.family("parakeet-v3"))), ModelSelection(tier: .t16, mode: .exact))
        XCTAssertEqual(c.currentSelection(try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))), ModelSelection(tier: .t16, mode: .fast))
        XCTAssertEqual(c.selected(try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))), "FP16")
        XCTAssertEqual(c.currentSelection(try XCTUnwrap(c.catalog.family("qwen3-asr-0.6b"))), ModelSelection(tier: .t16, mode: .fast))
        // The first-dictation offer keeps the saved choice too.
        let ultra = c.catalog.families.removeFirst()
        c.catalog.families.insert(ultra, at: 1)
        XCTAssertEqual(c.firstOffered(.dictation)?.precision, "BF16", "Parakeet v3's saved 16 · Exact, not the gold int8")
        // A loaded model shows what it is loaded at.
        c.runtime = TableRuntime(loaded: ["whisper-large-v3-turbo": LoadedFamily(precision: "FP16", engine: "optimized")])
        XCTAssertEqual(c.selected(try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))), "FP16")
        // The rule itself: recorded first, then a recorded precision, then the recommendation, then 16 · Fast.
        let rules = c.rules(try XCTUnwrap(c.catalog.family("parakeet-v3")))
        XCTAssertEqual(rules.runnable(recorded: nil, precision: nil, recommended: .t8), ModelSelection(tier: .t8, mode: .fast))
        XCTAssertEqual(rules.runnable(recorded: nil, precision: nil), .fallback)
        XCTAssertEqual(rules.runnable(recorded: ModelSelection(tier: .t16, mode: .exact), precision: nil, recommended: .t8), ModelSelection(tier: .t16, mode: .exact))
        XCTAssertEqual(rules.runnable(recorded: nil, precision: "BF16", recommended: .t8), ModelSelection(tier: .t16, mode: .fast))
    }
}

/// This Mac's qualification result decides the hardware facts once it exists (review, 15 Oct): a loaded precision on
/// stock MLX, or a persisted verdict that left `int8_gemm` off, takes int8 off the matrix hardware: software, the
/// triangle, never recommended, and the tooltip claims no matrix hardware.
@MainActor final class QualificationAdviceTests: XCTestCase {
    private func controller() throws -> ModelsController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-qualification-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("models-installed.json")
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"))
        c.gpu = RecommendedDefaultTests.m5; c.benchmarkHardware = .measured; c.osBuild = "25G72"; c.gateVersion = "native-kernels-10"
        c.runtime = TableRuntime()
        return c
    }

    func testALoadedStockRunTakesInt8OffTheMatrixHardware() throws {
        let c = try controller()
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        XCTAssertEqual(c.advice(parakeet).hardware[.t8], true, "no verdict yet: the derivation")
        c.runtime = TableRuntime(loaded: ["parakeet-v3": LoadedFamily(precision: "8b", engine: "mlx", selection: ModelSelection(tier: .t8, mode: .fast))])
        XCTAssertEqual(c.qualification(parakeet, tier: .t8, mode: .fast), .stock)
        let advice = c.advice(parakeet)
        XCTAssertEqual(advice.hardware[.t8], false)
        XCTAssertEqual(advice.recommended, .t16)
        XCTAssertNotNil(advice.warnings[.t8])
        let tips = Dictionary(ModelTable(controller: c).tooltips(parakeet).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(tips["Precision int8"]?.hasPrefix("Runs int8 without the matrix hardware on this Mac") == true, tips["Precision int8"] ?? "")
        XCTAssertFalse(tips["Precision int8"]?.contains("runs on this Mac's matrix hardware") == true)
        // The worker reports the component it left off: the same.
        c.runtime = TableRuntime(loaded: [
            "parakeet-v3": LoadedFamily(
                precision: "8b", engine: "optimized", optimizations: ["encoder": true, "decoder": true, "int8_gemm": false],
                selection: ModelSelection(tier: .t8, mode: .fast))
        ])
        XCTAssertEqual(c.qualification(parakeet, tier: .t8, mode: .fast), .optimized(disabled: ["int8_gemm"]))
        XCTAssertEqual(c.advice(parakeet).hardware[.t8], false)
    }

    func testAPersistedVerdictForThisMacCounts() throws {
        let c = try controller()
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        let folder = try XCTUnwrap(parakeet.variants["8b"]?.id)
        c.previewVerdicts([
            QualificationVerdict(
                status: "fast", model: folder, disabled: ["int8_gemm"], workerVersion: "native-kernels-10", gpuArchitecture: "applegpu_g17s", osBuild: "25G72")
        ])
        XCTAssertEqual(c.advice(parakeet).hardware[.t8], false)
        XCTAssertEqual(c.recommendedTier(parakeet), .t16, "the default follows the verdict too")
        XCTAssertEqual(c.currentSelection(parakeet), .fallback)
        // A verdict from another GPU (or worker version) is not this Mac's.
        c.previewVerdicts([
            QualificationVerdict(
                status: "stock", model: folder, workerVersion: "native-kernels-10", gpuArchitecture: "applegpu_g16s", osBuild: "25G72")
        ])
        XCTAssertEqual(c.advice(parakeet).hardware[.t8], true)
        XCTAssertEqual(c.recommendedTier(parakeet), .t8)
    }
}
