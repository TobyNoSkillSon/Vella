import XCTest
@testable import VellaCore

final class CatalogTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources") }
    private func r(_ wer: Double?, j: Double? = nil, x: Double? = nil, format: Double? = nil) -> PrecisionResult { PrecisionResult(wer: wer, format: format, speed_x: x, j_per_min: j) }
    private func family(native: String = "BF16", _ labels: [String]) -> ModelFamily {
        ModelFamily(id: "f", name: "F", mode: .dictation, languages: ["en"], params: "1B", license: "mit", native: native,
                    variants: Dictionary(uniqueKeysWithValues: labels.map { ($0, CatalogVariant(id: "f-\($0)", repository: "o/r", revision: "x", downloadBytes: 1, architecture: "parakeet")) }))
    }

    // MARK: Catalog

    func testShippedCatalogIsV2WithBothModesAndStableInstallIDs() throws {
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        XCTAssertEqual(catalog.schema, 2)
        XCTAssertFalse(catalog.offered(.dictation).isEmpty)
        XCTAssertFalse(catalog.offered(.streaming).isEmpty)
        XCTAssertEqual(Set(catalog.families.map(\.id)).count, catalog.families.count)
        let variants = catalogVariants(catalog)
        XCTAssertEqual(Set(variants.map(\.id)).count, variants.count, "install ids must stay unique")
        // Install ids of existing downloads (models-installed.json keys) are unchanged by the v2 migration.
        for id in ["parakeet-tdt-0.6b-v3-mlx-4bit", "Qwen3-ASR-1.7B-bf16", "whisper-large-v3-8bit", "nemotron-3.5-asr-streaming-0.6b-8bit"] {
            XCTAssertNotNil(catalog.locate(variant: id), id)
        }
        XCTAssertEqual(catalog.locate(variant: "parakeet-tdt-0.6b-v3-mlx-4bit")?.precision, "4b")
        // The downloader's legacy quantization spelling: validate() parses bits from "4-bit".
        XCTAssertEqual(variants.first { $0.id == "parakeet-tdt-0.6b-v3-mlx-4bit" }?.quantization, "4-bit")
        XCTAssertEqual(variants.first { $0.id == "Qwen3-ASR-1.7B-bf16" }?.quantization, "BF16")
        XCTAssertNotNil(try processorSource(variant: "whisper-large-v3-8bit", catalogURL: resources.appendingPathComponent("models.json")))
        for f in catalog.families {
            XCTAssertFalse(f.variants.isEmpty, f.id)
            XCTAssertTrue(f.variants.values.allSatisfy { $0.revision.count == 40 }, "pinned revisions: \(f.id)")
            XCTAssertTrue(f.variants.keys.allSatisfy { labelBits($0) != nil }, "exact precision labels: \(f.id)")
        }
        XCTAssertEqual(catalog.family("granite-4.0-1b-speech")?.offered, false, "weak models are not offered in the app")
    }

    func testLegacyFlatCatalogGroupsIntoFamilies() throws {
        let legacy = #"""
        [{"id":"a-8","name":"A","quantization":"8-bit","repository":"o/a8","revision":"r","downloadBytes":2,"architecture":"parakeet","license":"l","recommendation":"x","recommended":false},
         {"id":"a-4","name":"A","quantization":"4-bit","repository":"o/a4","revision":"r","downloadBytes":1,"architecture":"parakeet","license":"l","recommendation":"x","recommended":true},
         {"id":"s","name":"S","quantization":"BF16","repository":"o/s","revision":"r","downloadBytes":3,"architecture":"nemotron_asr","license":"l","recommendation":"x"}]
        """#
        let catalog = try decodeCatalog(Data(legacy.utf8))
        XCTAssertEqual(catalog.families.count, 2)
        XCTAssertEqual(Set(catalog.families[0].variants.keys), ["8b", "4b"])
        XCTAssertTrue(catalog.families[0].offered)
        XCTAssertEqual(catalog.families[1].mode, .streaming)
        XCTAssertEqual(catalogVariants(catalog).map(\.id).sorted(), ["a-4", "a-8", "s"])
    }

    func testPrecisionOptionsOrderAndFourBitFloor() {
        XCTAssertEqual(precisionOptions(family(["4b", "BF16", "8b"])), ["BF16", "8b", "4b"])
        XCTAssertEqual(precisionOptions(family(native: "FP32", ["4b", "FP32"])), ["FP32", "4b"])
        // Never below 4 bits by quantization; a natively ternary model is its own option.
        XCTAssertEqual(precisionOptions(family(["BF16", "4b", "3b", "2b"])), ["BF16", "4b"])
        XCTAssertEqual(precisionOptions(family(native: "ternary", ["ternary"])), ["ternary"])
        XCTAssertEqual(labelBits("BF16"), 16); XCTAssertEqual(labelBits("FP16"), 16); XCTAssertEqual(labelBits("8b"), 8)
        XCTAssertEqual(precisionLabel(legacyQuantization: "4-bit"), "4b")
        XCTAssertEqual(legacyQuantization("8b"), "8-bit"); XCTAssertEqual(legacyQuantization("BF16"), "BF16")
    }

    // MARK: Recommended precision

    func testRecommendedMarginIsAgainstNativeAndInclusive() {
        // 8b is exactly +0.5 pt: inside. 4b is +0.51: outside, although it uses the least energy.
        let b = FamilyBenchmark(precisions: ["BF16": r(5.12, j: 3), "8b": r(5.62, j: 2), "4b": r(5.63, j: 1)])
        XCTAssertEqual(recommendedPrecision(b, native: "BF16"), "8b")
        // Noise at a lossy precision (4b better than native) does not move the bar: the margin is native's.
        let noisy = FamilyBenchmark(precisions: ["BF16": r(5.0, j: 3), "8b": r(5.45, j: 2), "4b": r(4.0, j: 2.5)])
        XCTAssertEqual(recommendedPrecision(noisy, native: "BF16"), "8b")
    }

    func testRecommendedTiesMissingEnergyAndOptions() {
        // Energy tie → faster.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 2, x: 100), "8b": r(5, j: 2, x: 300)]), native: "BF16"), "8b")
        // Energy and speed tie → more bits.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 2, x: 100), "8b": r(5, j: 2, x: 100)]), native: "BF16"), "BF16")
        // Missing energy ranks after measured energy, even if it would be faster.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 9, x: 10), "4b": r(5, x: 900)]), native: "BF16"), "BF16")
        // No energy anywhere: speed decides.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, x: 10), "4b": r(5.2, x: 90)]), native: "BF16"), "4b")
        // Native WER not measured → no recommendation.
        XCTAssertNil(recommendedPrecision(FamilyBenchmark(precisions: ["4b": r(5, j: 1)]), native: "BF16"))
        XCTAssertNil(recommendedPrecision(nil, native: "BF16"))
        // Candidates are limited to offered precisions.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 3), "2b": r(5, j: 1)]), native: "BF16", options: ["BF16"]), "BF16")
        XCTAssertEqual(recommendationHelp(FamilyBenchmark(precisions: ["8b": r(5, j: 2)]), recommended: "8b", native: "BF16"),
                       "Recommended: lowest energy per audio minute within 0.5 pt WER of the native precision (BF16).")
        XCTAssertTrue(recommendationHelp(FamilyBenchmark(precisions: ["8b": r(5)]), recommended: "8b", native: "BF16").hasSuffix("energy not measured."))
    }

    /// The catalog script (lab/fixtures/recommended_precision.py, used by measure_catalog.py) writes `recommended` per
    /// family; Core must agree on every family in the shipped benchmarks.json.
    func testShippedRecommendationsMatchCore() throws {
        let url = resources.appendingPathComponent("benchmarks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Resources/benchmarks.json not measured yet") }
        let file = decodeBenchmarks(try Data(contentsOf: url))
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        for (id, bench) in file.models {
            guard let family = catalog.family(id) else { continue }
            XCTAssertEqual(recommendedPrecision(for: family, in: file), bench.recommended, id)
        }
        // Every measured result names its hardware and date.
        for (id, bench) in file.models { for (p, result) in bench.precisions {
            XCTAssertNotNil(result.hardware, "\(id) \(p)"); XCTAssertNotNil(result.date, "\(id) \(p)")
        } }
    }

    // MARK: Selection and load action

    func testSelectedPrecision() {
        let f = family(["BF16", "8b", "4b"])
        XCTAssertEqual(selectedPrecision(stored: nil, recommended: "8b", family: f), "8b")
        XCTAssertEqual(selectedPrecision(stored: "4b", recommended: "8b", family: f), "4b")
        XCTAssertEqual(selectedPrecision(stored: nativeSelection, recommended: "8b", family: f), "BF16")
        XCTAssertEqual(storedPrecision("BF16", native: "BF16"), nativeSelection)
        XCTAssertEqual(storedPrecision("8b", native: "BF16"), "8b")
        // A loaded model without a stored choice is not a pending change.
        XCTAssertEqual(selectedPrecision(stored: nil, loaded: "4b", recommended: "8b", family: f), "4b")
        // A stored choice that is no longer offered falls back.
        XCTAssertEqual(selectedPrecision(stored: "6b", recommended: nil, family: f), "BF16")
        XCTAssertEqual(selectedPrecision(stored: nil, recommended: nil, family: family(["8b", "4b"])), "8b")
    }

    func testLoadAction() {
        XCTAssertEqual(loadAction(selected: "8b", loaded: nil, native: "BF16", downloaded: false), .get)
        XCTAssertEqual(loadAction(selected: "8b", loaded: nil, native: "BF16", downloaded: true), .load)
        XCTAssertEqual(loadAction(selected: "8b", loaded: "8b", native: "BF16", downloaded: true), .unload)
        XCTAssertEqual(loadAction(selected: "BF16", loaded: nativeSelection, native: "BF16", downloaded: true), .unload)
        XCTAssertEqual(loadAction(selected: "4b", loaded: "BF16", native: "BF16", downloaded: true), .reload)
        // Reload stays Reload when the selected precision still has to be downloaded.
        XCTAssertEqual(loadAction(selected: "4b", loaded: "BF16", native: "BF16", downloaded: false), .reload)
    }

    // MARK: Deltas and formatters

    func testErrorRateDelta() {
        XCTAssertEqual(errorRateDelta(5.5, base: 5.1), Delta("+0.4 pt", .worse))
        XCTAssertEqual(errorRateDelta(4.7, base: 5.1), Delta("\u{2212}0.4 pt", .better))
        XCTAssertEqual(errorRateDelta(5.14, base: 5.1), Delta("±0.0 pt", .neutral))
        XCTAssertNil(errorRateDelta(nil, base: 5.1)); XCTAssertNil(errorRateDelta(5, base: nil))
    }
    func testSpeedDelta() {
        XCTAssertEqual(speedDelta(135, base: 100), Delta("35% faster", .better))
        XCTAssertEqual(speedDelta(80, base: 100), Delta("25% slower", .worse))
        XCTAssertEqual(speedDelta(240, base: 100), Delta("2.4× faster", .better))
        XCTAssertEqual(speedDelta(40, base: 100), Delta("2.5× slower", .worse))
        XCTAssertEqual(speedDelta(100.5, base: 100), Delta("same", .neutral))
        XCTAssertNil(speedDelta(0, base: 100)); XCTAssertNil(speedDelta(10, base: nil))
    }
    func testEnergyDelta() {
        XCTAssertEqual(energyDelta(0.8, base: 1), Delta("20% less", .better))
        XCTAssertEqual(energyDelta(1.15, base: 1), Delta("15% more", .worse))
        XCTAssertEqual(energyDelta(2.9, base: 1), Delta("2.9× more", .worse))
        XCTAssertEqual(energyDelta(1.004, base: 1), Delta("same", .neutral))
        XCTAssertNil(energyDelta(1, base: 0)); XCTAssertNil(energyDelta(nil, base: 1))
        XCTAssertEqual(memoryDelta(600, base: 1000), Delta("40% less", .better))
    }
    func testFormatters() {
        XCTAssertEqual(formatErrorRate(5.12), "5.1%")
        XCTAssertEqual(formatSpeed(512.3), "512×"); XCTAssertEqual(formatSpeed(18.44), "18.4×")
        XCTAssertEqual(formatEnergy(1.94), "1.9 J"); XCTAssertEqual(formatEnergy(42.4), "42 J")
        XCTAssertEqual(formatMemory(1340), "1.34 GB"); XCTAssertEqual(formatMemory(782), "782 MB")
        XCTAssertEqual(formatLanguages(["en"]), "en"); XCTAssertEqual(formatLanguages(["en", "pl"]), "en, pl")
        XCTAssertEqual(formatLanguages(["en", "pl", "de"]), "3"); XCTAssertEqual(formatLanguages([]), "—")
        XCTAssertNil(formatErrorRate(nil)); XCTAssertNil(formatSpeed(nil)); XCTAssertNil(formatEnergy(nil))
    }

    // MARK: Benchmarks file, hardware note, engine label, footer

    func testBenchmarksDecodeToleratesMissingAndMalformedFields() {
        let json = #"""
        {"schema":1,"hardware":"Apple M5 Max, macOS 26.6","models":{
          "a":{"precisions":{"8b":{"wer":5.1,"j_per_min":"oops","hardware":"Apple M5 Max, macOS 26.6","date":"2026-09-27"},"4b":"broken"},"recommended":"8b"},
          "b":"broken"}}
        """#
        let file = decodeBenchmarks(Data(json.utf8))
        XCTAssertEqual(file.models["a"]?.result("8b")?.wer, 5.1)
        XCTAssertNil(file.models["a"]?.result("8b")?.j_per_min, "a malformed figure is not measured, not a failure")
        XCTAssertNil(file.models["a"]?.result("4b"))
        XCTAssertEqual(file.models["a"]?.recommended, "8b")
        XCTAssertNil(file.models["b"])
        XCTAssertEqual(decodeBenchmarks(nil), BenchmarkFile())
        XCTAssertEqual(measurementChip(file), "M5 Max")
    }
    func testHardwareNote() {
        XCTAssertNil(hardwareNote(thisChip: "Apple M5 Pro", measuredOn: "M5 Max"), "same generation")
        XCTAssertEqual(hardwareNote(thisChip: "Apple M3 Pro", measuredOn: "Apple M5 Max")?.text, "Benchmarks measured on M5 Max")
        XCTAssertNil(hardwareNote(thisChip: nil, measuredOn: "M5 Max"))
        XCTAssertEqual(chipGeneration("Apple M5 Pro"), "M5"); XCTAssertEqual(displayChip("Apple M5 Max"), "M5 Max")
    }
    func testEngineLabelAndHelp() {
        XCTAssertEqual(engineLabel(engine: "optimized", chip: "Apple M5 Max"), "Optimized \u{00b7} M5 Max")
        XCTAssertEqual(engineLabel(engine: "optimized", chip: nil), "Optimized")
        XCTAssertEqual(engineLabel(engine: "mlx", chip: "M5 Max"), "MLX")
        XCTAssertEqual(engineLabel(engine: nil, chip: "M5 Max"), "MLX")
        let partly = engineHelp(engine: "mlx", reason: "self-test failed", optimizations: ["decoder": true, "prefill": false], chip: "M5 Max", precision: "8b")
        XCTAssertTrue(partly.hasPrefix("Partly optimized"))
        XCTAssertTrue(partly.contains("stock: prefill")); XCTAssertTrue(partly.contains("Why: self-test failed."))
        let stock = engineHelp(engine: "mlx", reason: nil, optimizations: nil, chip: nil, precision: "4b")
        XCTAssertTrue(stock.hasPrefix("Stock MLX path")); XCTAssertFalse(stock.contains("Why"), "never invents a cause")
    }
    func testFooterNoticePriority() {
        let refusal = TableRefusal(message: "needs ~4.2 GB", at: 1000)
        XCTAssertEqual(footerNotice(lastError: "app", workerError: "worker", refusal: refusal, now: 1001), "app")
        XCTAssertEqual(footerNotice(lastError: nil, workerError: "worker", refusal: refusal, now: 1001), "worker")
        XCTAssertEqual(footerNotice(lastError: nil, workerError: nil, refusal: refusal, now: 1599), "needs ~4.2 GB")
        XCTAssertNil(footerNotice(lastError: nil, workerError: nil, refusal: refusal, now: 1600), "refusals show for 10 minutes")
    }

    // MARK: Keep Hot and Memory menus

    func testKeepHotMenuDefaultsAndChoices() {
        let entries = keepHotEntries(manualIdle: defaultManualIdleMinutes, onDemandIdle: defaultOnDemandIdleMinutes)
        let checked = entries.compactMap { e -> SettingsAction? in if case .choice(_, true, let a, _) = e { return a }; return nil }
        XCTAssertEqual(checked, [.keepHot(.manual, minutes: 0), .keepHot(.onDemand, minutes: 15)], "manual Always, on demand 15 min")
        let titles = entries.compactMap { e -> String? in if case .choice(let t, _, _, _) = e { return t }; return nil }
        XCTAssertEqual(titles, ["5 min idle", "15 min idle", "30 min idle", "60 min idle", "Always", "5 min idle", "15 min idle", "30 min idle", "60 min idle", "Always"])
        XCTAssertEqual(entries.first, .header("Manually loaded", help: manualLoadHelp))
    }
    func testMemoryMenuCaptions() {
        let plain = memoryEntries(allowSwap: false, availableMB: nil, lastEvicted: nil)
        XCTAssertEqual(plain.count, 2)
        guard case .choice(fitInFreeMemoryTitle, true, .memory(allowSwap: false), _) = plain[0] else { return XCTFail() }
        let tight = memoryEntries(allowSwap: true, availableMB: 900, lastEvicted: "Parakeet v3")
        XCTAssertEqual(Array(tight.suffix(2)), [.caption("~0.9 GB free now"), .caption("Unloaded Parakeet v3 to make room")])
        guard case .choice(allowSwapTitle, true, .memory(allowSwap: true), _) = tight[1] else { return XCTFail() }
    }
    /// Docs describe the same table, menu and rule the code implements (CHECKLIST 13 string check).
    func testDocsMatchTheTableMenuAndRule() throws {
        let root = resources.deletingLastPathComponent()
        let docs = try ["README.md", "docs/USAGE.md", "Resources/AGENT_GUIDE.md"].map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        let all = docs.joined(separator: "\n")
        XCTAssertEqual(recommendationMarginPoints, 0.5)
        XCTAssertTrue(all.contains("within 0.5 points"), "recommended-precision margin")
        XCTAssertTrue(docs[0].contains("Mode · Microphone · Shortcuts") && docs[0].contains("Models… · Keep Hot · Memory"), "menu order")
        XCTAssertEqual(keepHotChoices.map(\.minutes), [5, 15, 30, 60, 0])
        XCTAssertTrue(all.contains("Always (default), 5, 15, 30 or 60 min"), "manual Keep Hot choices and default")
        for stale in ["In use", "one row per variant", "Install/Use", "inline bit-width picker"] {
            XCTAssertFalse(all.contains(stale), stale)
        }
        for column in ["WER", "Format", "Speed", "J / min", "Memory"] { XCTAssertTrue(docs[1].contains(column), column) }
    }

    /// Wording rule: no tooltip claims what the code does not guarantee.
    func testTooltipsMakeNoStaleClaims() {
        for text in [fitInFreeMemoryHelp, allowSwapHelp, keepHotAlwaysHelp, manualLoadHelp, onDemandLoadHelp, openFilesHelp, restartWorkerHelp] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("never pushes"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("guarantee"), text)
        }
        XCTAssertTrue(fitInFreeMemoryHelp.contains("Best effort"))
    }
}
