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
        // Only 16-bit checkpoints download (8 and 4 are made on this Mac); the downloader validates their exact format.
        XCTAssertNil(variants.first { $0.id == "parakeet-tdt-0.6b-v3-mlx-4bit" })
        XCTAssertEqual(variants.first { $0.id == "Qwen3-ASR-1.7B-bf16" }?.quantization, "BF16")
        XCTAssertEqual(variants.first { $0.id == "whisper-large-v3-asr-fp16" }?.quantization, "FP16")
        XCTAssertNil(try processorSource(variant: "whisper-large-v3-8bit", catalogURL: resources.appendingPathComponent("models.json")),
                     "a derived 8 uses its FP16 source's tokenizer files")
        for f in catalog.families {
            XCTAssertFalse(f.variants.isEmpty, f.id)
            XCTAssertTrue(f.variants.values.allSatisfy { $0.isDerived || $0.revision.count == 40 }, "pinned revisions: \(f.id)")
            XCTAssertEqual(f.derivationProblems(), [], f.id)
            XCTAssertTrue(f.variants.keys.allSatisfy { labelBits($0) != nil }, "exact precision labels: \(f.id)")
        }
    }

    func testShippedLineup() throws {
        // A model is offered when it serves a clear purpose (size, languages, family, speed), even if another model has
        // a lower WER (Toby, 27 Sep 2026): Qwen3 ASR 0.6B for Macs with less RAM, Whisper large-v3 and turbo as another
        // family with about 100 languages.
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let offered = Dictionary(uniqueKeysWithValues: catalog.families.filter(\.offered).map { ($0.id, Set($0.variants.keys)) })
        // Every level from native down to 4 bits (Toby, 26 Sep 2026); gaps are derived locally (DerivedModels.swift).
        XCTAssertEqual(offered, ["parakeet-v3": ["FP32", "BF16", "8b", "4b"], "parakeet-v3-ultra": ["BF16", "8b", "4b"],
                                 "qwen3-asr-1.7b": ["BF16", "8b", "4b"], "qwen3-asr-0.6b": ["BF16", "8b", "4b"],
                                 "whisper-large-v3": ["FP16", "8b", "4b"], "whisper-large-v3-turbo": ["FP16", "8b", "4b"],
                                 "nemotron-3.5-streaming-0.6b": ["BF16", "8b", "4b"]])
        XCTAssertEqual(catalog.offered(.dictation).map(\.id), ["parakeet-v3-ultra", "parakeet-v3", "qwen3-asr-1.7b", "qwen3-asr-0.6b",
                                                              "whisper-large-v3", "whisper-large-v3-turbo"])
        XCTAssertEqual(catalog.offered(.streaming).map(\.id), ["nemotron-3.5-streaming-0.6b"])
        XCTAssertEqual(catalog.family("parakeet-v3")?.native, "FP32", "the Parakeet v3 checkpoint is FP32 on disk")
        XCTAssertEqual(catalog.family("whisper-large-v3-turbo")?.license, "mit", "turbo is MIT upstream, unlike large-v3")
        // Every offered family says what it is for (the Model tooltip), except the ones whose purpose is the default.
        for id in ["qwen3-asr-0.6b", "whisper-large-v3", "whisper-large-v3-turbo"] {
            XCTAssertFalse(catalog.family(id)?.notes?.isEmpty ?? true, id)
        }
        XCTAssertFalse(catalog.families.contains { $0.offered && ($0.notes ?? "").contains("Benchmark table only") })
        // The first offered Dictation family is the first-dictation Get offer (RuntimeBridge.offer): Ultra BF16, 1.25 GB.
        XCTAssertEqual(catalog.offered(.dictation).first?.id, "parakeet-v3-ultra")
        // Removed from the catalog (Toby, 29 Sep 2026): Parakeet TDT-CTC 110M, SenseVoice Small, Granite 4.0 1B, Voxtral
        // Realtime 4B. Their registry entries are pruned at launch (`retiredModelIDs`); their files are not touched.
        for id in ["parakeet-tdt-ctc-110m", "sensevoice-small", "granite-4.0-1b-speech", "voxtral-mini-4b-realtime"] {
            XCTAssertNil(catalog.family(id), id)
        }
        XCTAssertTrue(catalog.families.allSatisfy(\.offered))
        // Install ids of the kept models still resolve (installed copies stay usable and deletable).
        for id in ["whisper-large-v3-asr-fp16", "whisper-large-v3-asr-4bit", "nemotron-3.5-asr-streaming-0.6b-bf16",
                   "nemotron-3.5-asr-streaming-0.6b-8bit", "Qwen3-ASR-1.7B-4bit", "Qwen3-ASR-1.7B-8bit", "parakeet-tdt-0.6b-v3-mlx-4bit"] {
            XCTAssertNotNil(catalog.locate(variant: id), id)
        }
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

    // MARK: Q column labels

    func testSegmentLabelsAreBareWidthsWithExactFallback() {
        XCTAssertEqual(precisionSegmentLabels(["FP32", "BF16", "8b", "4b"]), ["32", "16", "8", "4"])
        XCTAssertEqual(precisionSegmentLabels(["BF16", "8b"]), ["16", "8"])
        // A bare 16 is BF16 (the Q heading says so); FP16 keeps its exact label.
        XCTAssertEqual(precisionSegmentLabels(["FP16", "8b", "4b"]), ["FP16", "8", "4"])
        XCTAssertEqual(precisionSegmentLabels(["FP16"]), ["FP16"])
        XCTAssertEqual(precisionSegmentLabels(["ternary"]), ["1.58"])
        // Both 16-bit formats in one family: every segment shows its exact format instead.
        XCTAssertEqual(precisionSegmentLabels(["FP32", "FP16", "BF16", "4b"]), ["FP32", "FP16", "BF16", "4b"])
        for label in precisionSegmentLabels(["FP32", "BF16", "8b", "4b"]) {
            XCTAssertFalse(label.contains("b") || label.contains("BF") || label.contains("FP"), label)
        }
        XCTAssertEqual(precisionInProse("BF16"), "BF16")
        XCTAssertEqual(precisionInProse("FP32"), "FP32")
        XCTAssertEqual(precisionInProse("8b"), "8-bit")
        XCTAssertEqual(precisionInProse("4b"), "4-bit")
        XCTAssertEqual(precisionFormatName("BF16"), "BF16 (bfloat16)")
        XCTAssertEqual(precisionFormatName("FP16"), "FP16 (float16)")
        XCTAssertEqual(precisionFormatName("FP32"), "FP32 (float32)")
        XCTAssertEqual(precisionFormatName("8b"), "8-bit quantized")
        XCTAssertEqual(precisionFormatName("4b"), "4-bit quantized")
    }

    // MARK: Stable sort

    private func named(_ id: String, _ labels: [String], native: String = "BF16") -> ModelFamily {
        var f = family(native: native, labels); f.id = id; f.name = id.uppercased(); return f
    }
    func testSortKeyIsTheBestValueAcrossPrecisions() throws {
        let a = named("a", ["BF16", "8b", "4b"]), b = named("b", ["BF16", "8b"]), c = named("c", ["BF16"]), d = named("d", ["BF16", "4b"])
        let file = BenchmarkFile(models: [
            "a": FamilyBenchmark(precisions: ["BF16": r(5.0, j: 9, x: 100), "8b": r(5.2, j: 4, x: 300), "4b": r(7.0, j: 6, x: 200)]),
            "b": FamilyBenchmark(precisions: ["BF16": r(6.0, j: 5, x: 250), "8b": r(4.9, j: 3, x: 90)]),
            "c": FamilyBenchmark(precisions: [:]),
        ])
        XCTAssertEqual(tableSortKey(.wer, family: a, benchmark: file.models["a"]), 5.0)
        XCTAssertEqual(tableSortKey(.speed, family: a, benchmark: file.models["a"]), -300, "highest speed, negated")
        XCTAssertEqual(tableSortKey(.energy, family: b, benchmark: file.models["b"]), 3)
        XCTAssertNil(tableSortKey(.wer, family: c, benchmark: file.models["c"]))
        let families = [a, b, c, d]
        XCTAssertEqual(sortedFamilies(families, by: .wer, ascending: true, benchmarks: file).map(\.id), ["b", "a", "c", "d"])
        XCTAssertEqual(sortedFamilies(families, by: .wer, ascending: false, benchmarks: file).map(\.id), ["a", "b", "c", "d"], "unmeasured stay last")
        XCTAssertEqual(sortedFamilies(families, by: .speed, ascending: true, benchmarks: file).map(\.id), ["a", "b", "c", "d"], "fastest first")
        XCTAssertEqual(sortedFamilies(families, by: .energy, ascending: true, benchmarks: file).map(\.id), ["b", "a", "c", "d"])
        XCTAssertEqual(sortedFamilies(families, by: nil, ascending: true, benchmarks: file).map(\.id), ["a", "b", "c", "d"])
        // On disk: published download sizes count; an unpublished precision counts only once measured.
        var e = named("e", ["BF16", "4b"]); e.variants["4b"]?.repository = ""; e.variants["4b"]?.downloadBytes = 0
        e.variants["BF16"]?.downloadBytes = 2_000_000
        XCTAssertEqual(tableSortKey(.disk, family: e, benchmark: nil), 2_000_000)
        XCTAssertNil(tableDiskBytes(e, "4b", nil), "never estimated")
        XCTAssertEqual(tableSortKey(.disk, family: e, benchmark: FamilyBenchmark(precisions: ["4b": PrecisionResult(disk_mb: 0.5)])), 500_000)
        // A conversion stored at Get (Parakeet v3's bf16 from the fp32 release) shows its converted size, about half the source.
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let v3 = try XCTUnwrap(catalog.family("parakeet-v3"))
        let stored = try XCTUnwrap(tableDiskBytes(v3, "BF16", nil), "stored bf16 has a size")
        XCTAssertTrue((1_000_000_000...1_400_000_000).contains(stored), "\(stored)")
    }

    func testRecommendedToleranceIsAgainstNativeAndInclusive() {
        // No tolerance_pt: 0.1 pt. 8b is exactly +0.1 pt: inside. 4b is +0.11: outside, although it uses the least energy.
        let b = FamilyBenchmark(precisions: ["BF16": r(5.12, j: 3), "8b": r(5.22, j: 2), "4b": r(5.23, j: 1)])
        XCTAssertEqual(recommendedPrecision(b, native: "BF16"), "8b")
        // Noise at a lossy precision (4b better than native) does not move the bar: the tolerance is native's.
        let noisy = FamilyBenchmark(precisions: ["BF16": r(5.0, j: 3), "8b": r(5.08, j: 2), "4b": r(4.0, j: 2.5)])
        XCTAssertEqual(recommendedPrecision(noisy, native: "BF16"), "8b")
        // A family's measured tolerance widens the band up to its 0.2 pt cap, never beyond.
        var wide = FamilyBenchmark(precisions: ["BF16": r(5.0, j: 3), "8b": r(5.1, j: 2), "4b": r(5.2, j: 1)], tolerance_pt: 0.2)
        XCTAssertEqual(recommendedPrecision(wide, native: "BF16"), "4b")
        wide.tolerance_pt = 0.15
        XCTAssertEqual(recommendedPrecision(wide, native: "BF16"), "8b")
        wide.tolerance_pt = 0.5
        XCTAssertEqual(recommendationTolerance(wide), 0.2, "capped")
        wide.tolerance_pt = 0.0
        XCTAssertEqual(recommendationTolerance(wide), 0.1, "floored")
        XCTAssertEqual(recommendationTolerance(nil), 0.1)
    }

    /// The recommended segment states the trade whenever a more efficient offered precision was rejected, with the
    /// file's numbers (Qwen3-ASR 1.7B, r6: 4b 15.37, 8b 15.07, BF16 15.03).
    func testRecommendationHelpStatesTheRejectedTrade() {
        let qwen = FamilyBenchmark(precisions: ["BF16": r(15.03, j: 75.47), "8b": r(15.07, j: 67.78), "4b": r(15.37, j: 54.51)])
        XCTAssertEqual(recommendedPrecision(qwen, native: "BF16"), "8b")
        XCTAssertEqual(recommendationHelp(qwen, recommended: "8b", native: "BF16"),
                       "Recommended: lowest energy per audio minute within 0.1 pt WER of the native precision (BF16)\n"
                       + "Against BF16: +0.04 pt English word errors, 10% less energy\n"
                       + "4-bit uses 20% less energy (55 J vs 68 J per audio minute) but has 0.30 pt more word errors (0.34 pt over BF16; limit 0.1 pt)")
        var measured = qwen; measured.tolerance_pt = 0.15
        XCTAssertTrue(recommendationHelp(measured, recommended: "8b", native: "BF16").hasSuffix("(0.34 pt over BF16; limit 0.15 pt)"))
        // Not offered → not a trade the user can make.
        XCTAssertFalse(recommendationHelp(qwen, recommended: "8b", native: "BF16", options: ["BF16", "8b"]).contains("4-bit"))
        // A rejected precision that is less efficient is not a trade either.
        let ultra = FamilyBenchmark(precisions: ["BF16": r(15.52, j: 5.18), "8b": r(15.54, j: 9.43), "4b": r(15.78, j: 9.22)])
        XCTAssertEqual(recommendationHelp(ultra, recommended: "BF16", native: "BF16"),
                       "Recommended: lowest energy per audio minute within 0.1 pt WER of the native precision (BF16)")
        // Without energy anywhere the trade is speed.
        let speed = FamilyBenchmark(precisions: ["BF16": r(5, x: 10), "4b": r(5.5, x: 30)])
        XCTAssertEqual(recommendationHelp(speed, recommended: "BF16", native: "BF16"),
                       "Recommended: fastest measured precision within 0.1 pt WER of the native precision (BF16)\nEnergy not measured")
        let partial = FamilyBenchmark(precisions: ["BF16": r(5, j: 2, x: 10), "4b": r(5.5, j: 2, x: 30)])
        XCTAssertTrue(recommendationHelp(partial, recommended: "BF16", native: "BF16").hasSuffix(
            "\n4-bit is 3.0× faster (30.0× vs 10.0× real time) but has 0.50 pt more word errors (0.50 pt over BF16; limit 0.1 pt)"))
    }

    /// With gate verdicts in the file, `gate.pass` decides (thresholds live in the benchmark tools); the native
    /// precision is always a candidate; a precision without a verdict falls back to the English-WER tolerance.
    func testRecommendedFollowsTheGateVerdict() {
        func g(_ wer: Double, j: Double, pass: Bool?, _ reasons: [String] = []) -> PrecisionResult {
            var result = r(wer, j: j); result.gate = pass.map { GateResult(pass: $0, reasons: reasons) }; return result
        }
        // Qwen3-ASR 1.7B under the gate: 8b and 4b fail on the multilingual mean → BF16, the trades stated.
        let qwen = FamilyBenchmark(precisions: [
            "BF16": g(15.03, j: 75.47, pass: nil),
            "8b": g(15.07, j: 67.78, pass: false, ["multilingual mean +0.48 pt (limit 0.10)", "Turkish +2.55 pt (limit 2.0)"]),
            "4b": g(15.37, j: 54.51, pass: false, ["English +0.34 pt (limit 0.10)"])])
        XCTAssertEqual(recommendedPrecision(qwen, native: "BF16"), "BF16")
        XCTAssertEqual(recommendationHelp(qwen, recommended: "BF16", native: "BF16"),
                       "Recommended: lowest energy per audio minute among the precisions that pass the quality gate against the native precision (BF16)\n"
                       + "4-bit uses 28% less energy (55 J vs 75 J per audio minute) but fails the quality gate: English +0.34 pt (limit 0.10)\n"
                       + "8-bit uses 10% less energy (68 J vs 75 J per audio minute) but fails the quality gate: multilingual mean +0.48 pt (limit 0.10); Turkish +2.55 pt (limit 2.0)")
        // A pass beyond the English tolerance (decided by the tools, e.g. on streaming speed) is taken, and said.
        let stream = FamilyBenchmark(precisions: [
            "BF16": g(23.42, j: 78.92, pass: false),
            "8b": g(23.47, j: 47.02, pass: true, ["passes on speed: 1.47x faster than BF16 with English within 0.10 pt; multilingual mean +0.60 pt"]),
            "4b": g(32.97, j: 40.2, pass: false, [])])
        XCTAssertEqual(recommendedPrecision(stream, native: "BF16"), "8b", "native's own gate field is ignored")
        XCTAssertEqual(recommendationHelp(stream, recommended: "8b", native: "BF16"),
                       "Recommended: lowest energy per audio minute among the precisions that pass the quality gate against the native precision (BF16)\n"
                       + "8-bit: passes on speed: 1.47x faster than BF16 with English within 0.10 pt; multilingual mean +0.60 pt\n"
                       + "Against BF16: +0.05 pt English word errors, 40% less energy\n"
                       + "4-bit uses 15% less energy (40 J vs 47 J per audio minute) but fails the quality gate")
        let wide = FamilyBenchmark(precisions: ["BF16": g(5, j: 3, pass: nil), "4b": g(9, j: 1, pass: true)])
        XCTAssertEqual(recommendedPrecision(wide, native: "BF16"), "4b")
        // A failed verdict wins over an English WER inside the tolerance.
        let failed = FamilyBenchmark(precisions: ["BF16": g(5, j: 3, pass: nil), "8b": g(5.0, j: 2, pass: false, ["1 empty segment"])])
        XCTAssertEqual(recommendedPrecision(failed, native: "BF16"), "BF16")
        // Mixed file: a precision without a verdict uses the tolerance.
        let mixed = FamilyBenchmark(precisions: ["BF16": g(5, j: 3, pass: nil), "8b": g(5.05, j: 2, pass: nil), "4b": g(5.3, j: 1, pass: false)])
        XCTAssertEqual(recommendedPrecision(mixed, native: "BF16"), "8b")
    }

    func testRecommendedTiesMissingEnergyAndOptions() {
        // Energy tie → faster.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 2, x: 100), "8b": r(5, j: 2, x: 300)]), native: "BF16"), "8b")
        // Energy and speed tie → more bits.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 2, x: 100), "8b": r(5, j: 2, x: 100)]), native: "BF16"), "BF16")
        // Missing energy ranks after measured energy, even if it would be faster.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 9, x: 10), "4b": r(5, x: 900)]), native: "BF16"), "BF16")
        // No energy anywhere: speed decides.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, x: 10), "4b": r(5.1, x: 90)]), native: "BF16"), "4b")
        // Native WER not measured → no recommendation.
        XCTAssertNil(recommendedPrecision(FamilyBenchmark(precisions: ["4b": r(5, j: 1)]), native: "BF16"))
        XCTAssertNil(recommendedPrecision(nil, native: "BF16"))
        // Candidates are limited to offered precisions.
        XCTAssertEqual(recommendedPrecision(FamilyBenchmark(precisions: ["BF16": r(5, j: 3), "2b": r(5, j: 1)]), native: "BF16", options: ["BF16"]), "BF16")
        XCTAssertEqual(recommendationHelp(FamilyBenchmark(precisions: ["8b": r(5, j: 2)]), recommended: "8b", native: "BF16"),
                       "Recommended: lowest energy per audio minute within 0.1 pt WER of the native precision (BF16)")
        XCTAssertTrue(recommendationHelp(FamilyBenchmark(precisions: ["8b": r(5)]), recommended: "8b", native: "BF16").hasSuffix("\nEnergy not measured"))
    }

    /// The benchmark script writes `recommended` per
    /// family; Core must agree on every family in the shipped benchmarks.json.
    /// The README benchmark table (lab/bench/measure_catalog.py --readme) pins every offered cell: one row per tier and
    /// path in the Models table's order (Standard, then Optimized; one Optimized row where Exact = Fast), its WER and
    /// Format as in benchmarks.json, `measure pending` for a cell not measured; absent tiers only in "Not offered".
    func testReadmeTablePinsEveryCell() throws {
        let root = resources.deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let table = readme.components(separatedBy: "<!-- BENCHMARK_TABLE_START -->")[1].components(separatedBy: "<!-- BENCHMARK_TABLE_END -->")[0]
        let lines = table.components(separatedBy: "\n")
        let file = decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json")))
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
        var rows = 0
        for family in catalog.families {
            let bench = try XCTUnwrap(file.models[family.id], family.id)
            let mode = family.mode == .streaming ? "Streaming" : "Dictation"
            for tier in ModelTier.allCases {
                guard let t = bench.tiers[tier] else { continue }
                let mine = lines.filter { $0.range(of: "^\\| \(NSRegularExpression.escapedPattern(for: family.name))( [⁰¹²³⁴⁵⁶⁷⁸⁹]+)? \\|", options: .regularExpression) != nil }
                    .filter { $0.contains(" | \(mode) | \(tier.rawValue) | ") }
                guard t.presence.offered else {
                    XCTAssertTrue(mine.isEmpty, "\(family.id) \(tier.rawValue): an absent tier has no row")
                    let notOffered = try XCTUnwrap(lines.first { $0.hasPrefix("Not offered: ") })
                    XCTAssertTrue(notOffered.contains("\(family.name) \(tier.rawValue) ("), "\(family.id) \(tier.rawValue) listed as not offered")
                    continue
                }
                var paths: [(String, BenchmarkCell?)] = [("Standard", t.cells[.standard])]
                if t.cells[.optimized_fast]?.recipe.inexact.isEmpty ?? true { paths.append(("Optimized (Exact = Fast)", t.cells[.optimized_fast])) }
                else { paths += [("Optimized · Exact", t.cells[.optimized_exact]), ("Optimized · Fast", t.cells[.optimized_fast])] }
                XCTAssertEqual(mine.count, paths.count, "\(family.id) \(tier.rawValue)")
                for (path, cell) in paths {
                    let c = try XCTUnwrap(cell)
                    let expected = " | \(mode) | \(tier.rawValue) | \(path) | \(fmt(c.result.wer)) | \(fmt(c.result.format)) | "
                    let row = mine.first { $0.contains(expected) }
                    XCTAssertNotNil(row, "\(family.id) \(tier.rawValue) \(path): \(expected)")
                    if c.isPending { XCTAssertTrue(row?.hasSuffix("| measure pending |") ?? false, "\(family.id) \(tier.rawValue) \(path) pending") }
                    rows += 1
                }
            }
        }
        XCTAssertEqual(lines.filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Model") && !$0.contains("(cloud API)") }.count, rows, "no other model rows")
        XCTAssertTrue(table.contains("Segmentation fixed on 2026-09-29; accuracy re-measure pending."), "the re-measure footnote stays")
    }

    /// The shipped benchmarks.json (schema 2): every catalog family, tiers 16/8/4 only (never fp32), all three cells per
    /// tier, every measured cell with hardware, date and suite, and presence as ruled on 29 Sep (lab/notes/models-table-ROUND.md).
    func testShippedBenchmarksAreSchema2WithTheRuledPresence() throws {
        let url = resources.appendingPathComponent("benchmarks.json")
        let file = decodeBenchmarks(try Data(contentsOf: url))
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        XCTAssertEqual(file.schema, 2)
        XCTAssertEqual(Set(file.models.keys), Set(catalog.families.map(\.id)), "a benchmark row for every catalog family, none for removed ones")
        let offered: [String: [ModelTier]] = [
            "parakeet-v3": [.t16], "parakeet-v3-ultra": [.t16, .t8, .t4], "qwen3-asr-1.7b": [.t16], "qwen3-asr-0.6b": [.t16, .t8],
            "nemotron-3.5-streaming-0.6b": [.t16, .t8], "whisper-large-v3": [.t16, .t8], "whisper-large-v3-turbo": [.t16, .t8]]
        for (id, bench) in file.models {
            let family = try XCTUnwrap(catalog.family(id))
            XCTAssertEqual(ModelTier.allCases.filter { cellPresent(bench, tier: $0, segment: .standard) }, offered[id], id)
            XCTAssertEqual(family.tiersOffered, offered[id]?.map(\.rawValue), "\(id): models.json tiers_offered agrees with the presence")
            XCTAssertFalse(bench.precisions.keys.contains("FP32"), "\(id): fp32 is never a tier")
            for (tier, t) in bench.tiers {
                XCTAssertEqual(modelTier(ofPrecision: t.precision), tier, id)
                XCTAssertEqual(Set(t.cells.keys), Set(SegmentKey.allCases), "\(id) \(tier.rawValue)")
                if !t.presence.offered { XCTAssertFalse(t.presence.reasons.isEmpty, "\(id) \(tier.rawValue): absent says why") }
                if t.gate.status == .fail && tier != .t16 {
                    XCTAssertTrue(t.gate.reasons.contains { $0.contains("uniform affine-\(tier.rawValue) g64 recipe") }, "\(id) \(tier.rawValue): the verdict names the uniform recipe")
                }
                for (key, cell) in t.cells where !cell.isPending {
                    XCTAssertNotNil(cell.measured?.hardware, "\(id) \(tier.rawValue) \(key)"); XCTAssertNotNil(cell.measured?.date, "\(id) \(tier.rawValue) \(key)")
                    XCTAssertEqual(cell.measured?.suite, "v2", "\(id) \(tier.rawValue) \(key)")
                }
                XCTAssertTrue(t.cells[.optimized_exact]?.recipe.inexact.isEmpty ?? false, "\(id): Exact runs no inexact kernel")
                XCTAssertEqual(t.cells[.standard]?.recipe.gate_revision, "stock")
            }
        }
        // Mapping of the 28 Sep numbers: Qwen and Ultra 8/4 have no inexact kernel (Exact = Fast, the switch greyed for
        // Qwen); Parakeet's NAX, Nemotron's fused layer and Whisper's half encoder are inexact (Exact pending).
        XCTAssertFalse(fastDiffersFromExact(file.models["qwen3-asr-1.7b"]))
        XCTAssertFalse(fastDiffersFromExact(file.models["qwen3-asr-0.6b"]))
        for id in ["parakeet-v3", "parakeet-v3-ultra", "nemotron-3.5-streaming-0.6b", "whisper-large-v3", "whisper-large-v3-turbo"] {
            XCTAssertTrue(fastDiffersFromExact(file.models[id]), id)
            XCTAssertTrue(file.models[id]?.tiers[.t16]?.cells[.optimized_exact]?.isPending ?? false, "\(id): Exact 16 measure pending")
        }
        XCTAssertEqual(file.models["parakeet-v3"]?.tiers[.t16]?.cells[.optimized_fast]?.recipe.inexact, ["nax_gemm"])
        XCTAssertEqual(file.models["parakeet-v3"]?.tiers[.t16]?.cells[.standard]?.recipe.converted_from, "fp32")
        XCTAssertEqual(file.models["parakeet-v3-ultra"]?.tiers[.t8]?.cells[.optimized_exact]?.result.speed_x,
                       file.models["parakeet-v3-ultra"]?.tiers[.t8]?.cells[.optimized_fast]?.result.speed_x)
    }

    // MARK: Selection and load action

    /// ONE state (the 1.0.0 bug: a stored FP32 choice outranked the loaded 4-bit and turned Unload into a Reload that
    /// downloaded 2.5 GB). Order: preview > loaded > last loaded > recommended > native > highest.
    func testShownPrecisionLoadedWins() {
        let f = family(["BF16", "8b", "4b"])
        // Loaded wins over last loaded and the recommendation.
        XCTAssertEqual(shownPrecision(loaded: "4b", lastLoaded: "BF16", recommended: "8b", family: f), "4b")
        XCTAssertEqual(loadAction(selected: shownPrecision(loaded: "4b", lastLoaded: "BF16", recommended: "8b", family: f),
                                  loaded: "4b", native: "BF16", downloaded: true), .unload, "a loaded row offers Unload")
        // A preview shows its precision; the loaded row then offers Reload.
        XCTAssertEqual(shownPrecision(preview: "BF16", loaded: "4b", lastLoaded: nil, recommended: "8b", family: f), "BF16")
        XCTAssertEqual(loadAction(selected: "BF16", loaded: "4b", native: "BF16", downloaded: false), .reload)
        // Unloaded: last loaded, else recommended, else native, else the highest offered.
        XCTAssertEqual(shownPrecision(loaded: nil, lastLoaded: "4b", recommended: "8b", family: f), "4b")
        XCTAssertEqual(shownPrecision(loaded: nil, lastLoaded: nil, recommended: "8b", family: f), "8b")
        XCTAssertEqual(shownPrecision(loaded: nil, lastLoaded: nil, recommended: nil, family: f), "BF16")
        XCTAssertEqual(shownPrecision(loaded: nil, lastLoaded: nil, recommended: nil, family: family(["8b", "4b"])), "8b")
        // Labels no longer offered fall through; the retired `native` sentinel resolves.
        XCTAssertEqual(shownPrecision(preview: "6b", loaded: nil, lastLoaded: "2b", recommended: nil, family: f), "BF16")
        XCTAssertEqual(shownPrecision(loaded: nil, lastLoaded: nativeSelection, recommended: "8b", family: f), "BF16")
        XCTAssertEqual(committedPrecision(loaded: "8b", lastLoaded: "4b", recommended: nil, family: f), "8b")
    }

    func testConfigurationRecordsLoads() throws {
        var config = Configuration(model: "/old")
        config.recordLoad(path: "/models/p4", mode: .dictation, family: "parakeet-v3", precision: "4b")
        config.recordLoad(path: "/models/n8", mode: .streaming, family: "nemotron", precision: "8b")
        XCTAssertEqual(config.model, "/models/p4"); XCTAssertEqual(config.streamingModel, "/models/n8")
        XCTAssertEqual(config.lastLoaded, ["parakeet-v3": "4b", "nemotron": "8b"])
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.lastLoaded, config.lastLoaded)
        // Older config.json files have no lastLoaded.
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(#"{"model":"/x"}"#.utf8)).lastLoaded, [:])
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
        let baseline = PrecisionResult(speed_x: 364.6, stock: StockBaseline(speed_x: 58.04, j_per_min: 95.2, memory_mb: 2412))
        XCTAssertEqual(stockLine(baseline), "Stock MLX on any Mac: 58.0\u{00d7} \u{00b7} 95 J \u{00b7} 2.41 GB")
        XCTAssertEqual(stockLine(PrecisionResult(stock: StockBaseline(speed_x: 228.8, memory_mb: 1732))), "Stock MLX on any Mac: 229\u{00d7} \u{00b7} 1.73 GB", "an unmeasured figure is left out")
        XCTAssertNil(stockLine(PrecisionResult(speed_x: 364.6))); XCTAssertNil(stockLine(nil))
        let loaded = engineHelp(engine: "optimized", reason: nil, optimizations: nil, chip: "M5 Max", precision: "BF16", stock: stockLine(baseline))
        XCTAssertEqual(loaded.components(separatedBy: "\n").last, "Stock MLX on any Mac: 58.0\u{00d7} \u{00b7} 95 J \u{00b7} 2.41 GB")
    }
    func testStockBaselineDecodes() throws {
        let json = #"{"speed_x": 387.4, "latency_ms": {"p50": 13.9, "p95": 22.4, "n": 231, "kind": "segment"}, "stock": {"wer": 15.5, "speed_x": "fast", "j_per_min": 6.67, "memory_mb": 1732, "latency_ms": {"p50": 23.7, "p95": 45.4}, "suite": "v2"}}"#
        let r = try JSONDecoder().decode(PrecisionResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.latency_ms?.p95, 22.4); XCTAssertEqual(r.latency_ms?.kind, "segment")
        XCTAssertEqual(r.stock?.wer, 15.5); XCTAssertNil(r.stock?.speed_x, "a wrongly typed figure is not measured")
        XCTAssertEqual(r.stock?.latency_ms?.p50, 23.7); XCTAssertEqual(r.stock?.memory_mb, 1732)
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
        XCTAssertEqual(defaultRecommendationTolerancePoints, 0.1)
        XCTAssertEqual(maximumRecommendationTolerancePoints, 0.2)
        XCTAssertTrue(all.contains("Vella's quality gate") && all.contains("within 0.1 points of 16") && all.contains("up to 0.2 points"),
                      "the quality gate and its English tolerance")
        XCTAssertTrue(docs[0].contains("breaks against 16") && docs[1].contains("breaks against 16"), "presence rule")
        XCTAssertTrue(docs[0].contains("No tier is recommended") && docs[1].contains("Nothing is marked as recommended"), "no recommended cell")
        XCTAssertFalse(all.contains("0.5 points"), "retired 0.5-point margin")
        XCTAssertTrue(docs[0].contains("Mode · Microphone · Shortcuts") && docs[0].contains("Models… · Keep Hot · Memory"), "menu order")
        XCTAssertEqual(keepHotChoices.map(\.minutes), [5, 15, 30, 60, 0])
        XCTAssertTrue(all.contains("Always (default), 5, 15, 30 or 60 min"), "manual Keep Hot choices and default")
        for stale in ["In use", "one row per variant", "Install/Use", "inline bit-width picker"] {
            XCTAssertFalse(all.contains(stale), stale)
        }
        for column in ["WER", "Format", "Speed", "J / min", "Memory"] { XCTAssertTrue(docs[1].contains(column), column) }
        // Table v2 with Toby's corrections (29 Sep, 21:xx): one line per model; Capabilities; Precision as two rows,
        // Optimized above Standard, every cell clickable; the Exact/Fast switch beside the Optimized row (up Fast, down
        // Exact, whole-area click, Exact coupled to 16); no On disk column; an always-visible one-word button.
        XCTAssertTrue(docs[1].contains("| Capabilities | Fixed icon slots") && docs[1].contains("Show only models with"), "USAGE Capabilities column and filter")
        XCTAssertTrue(docs[1].contains("| Precision | Two rows of segments `16 8 4`, bits per weight: **Optimized**") && docs[1].contains("above **Standard**")
                      && docs[1].contains("| (switch) | Beside the Optimized row, a switch, up **Fast**, down **Exact**; a click anywhere on it flips it."), "USAGE Precision rows and switch")
        XCTAssertTrue(docs[0].contains("every cell is clickable and shows its own figures") && docs[1].contains("every cell is clickable and shows its own figures"), "both rows clickable")
        XCTAssertTrue(docs[1].contains("`Exact: 16 only, was 8`") && docs[0].contains("flipping to Exact can move the precision to 16"), "Exact coupling documented")
        XCTAssertTrue(docs[1].contains("| (last) | The button: **Get**, **Load**, **Unload** or **Reload**") && docs[0].contains("The last column is the row's button"), "the action button")
        XCTAssertTrue(docs[0].contains("one line per model") && docs[2].contains("two **Precision** rows"), "one line per model, two Precision rows")
        for stale in ["● loaded, ○ on disk, ↓ not downloaded", "state glyph", "| On disk |", "**Path** switch", "**Path** is a switch"] {
            XCTAssertFalse(all.contains(stale), "retired table v2 wording: \(stale)")
        }
        XCTAssertTrue(docs[0].contains("| Model | Mode | Precision | Path |"), "README benchmark table (generated by lab/bench/measure_catalog.py)")
        XCTAssertTrue(docs[1].contains("locked; a change applies at the next load") && docs[0].contains("locked; a change applies at the next load"), "in-use interlock")
        XCTAssertTrue(docs[1].contains("best value across its precisions"), "stable sort documented")
        // One state and download confirmation (Toby, 26 Sep 2026).
        XCTAssertTrue(docs[1].contains("always shows the precision it is loaded at") && docs[1].contains("Closing the menu without Reload discards the preview")
                      && docs[1].contains("else Optimized 16 · Fast"),
                      "USAGE: loaded precision wins; previews are transient")
        XCTAssertTrue(docs[1].contains("the one its next dictation (or streaming session) loads"), "USAGE: dictation uses what was last loaded")
        XCTAssertTrue(docs[1].contains("nothing downloads without **Download**") && docs[1].contains("**Cancel** is the default"), "USAGE: download popup")
        XCTAssertTrue(docs[1].contains("removes its partial files"), "USAGE: partial clean-up")
        XCTAssertTrue(docs[0].contains("nothing downloads without **Download**"), "README: download popup")
        for stale in ["only records the choice", "Nothing downloads without that click", "Partial downloads may be resumed"] {
            XCTAssertFalse(all.contains(stale), stale)
        }
        for stale in ["| Tier |", "| Languages |"] { XCTAssertFalse(docs[1].contains(stale), "USAGE Models table: \(stale)") }
        for stale in ["`4b`, `8b`", "| 8b", "| 4b", "| BF16"] {
            XCTAssertFalse(docs[0].contains(stale) || docs[1].contains(stale), stale)
        }
    }

    /// Wording rule: no tooltip claims what the code does not guarantee.
    func testTooltipsMakeNoStaleClaims() {
        for text in [fitInFreeMemoryHelp, allowSwapHelp, keepHotAlwaysHelp, manualLoadHelp, onDemandLoadHelp, copySkillHelp, accessibilityHeaderHelp] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("never pushes"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("guarantee"), text)
        }
        XCTAssertTrue(fitInFreeMemoryHelp.contains("Best effort"))
    }

    // MARK: Cloud reference rows (estimated)

    func testReferencesDecodeOnlyWhenMarkedEstimated() {
        let json = #"""
        {"schema": 1, "models": {}, "references": {
          "api-a": {"reference": true, "estimated": true, "name": "A", "mode": "dictation", "wer": 12.9, "range": [11.3, 13.3],
                    "source": "S", "method": "M", "multilingual": {"by_language": {"de": 5.0}, "coverage": 1}},
          "api-b": {"reference": true, "name": "B", "mode": "dictation", "wer": 1.0},
          "api-c": {"reference": true, "estimated": true, "name": "C", "mode": "streaming", "wer": 20}
        }}
        """#
        let file = decodeBenchmarks(Data(json.utf8))
        XCTAssertEqual(Set(file.references.keys), ["api-a", "api-c"], "an entry not marked estimated is never shown as a figure")
        XCTAssertEqual(file.references["api-a"]?.id, "api-a")
        XCTAssertEqual(file.references["api-a"]?.range, [11.3, 13.3])
        XCTAssertEqual(file.references(.dictation).map(\.id), ["api-a"])
        XCTAssertEqual(file.references(.streaming).map(\.id), ["api-c"])
        XCTAssertTrue(decodeBenchmarks(Data(#"{"schema": 1, "models": {}}"#.utf8)).references.isEmpty)
    }

    func testReferenceRowsSortWithModelsByWERAndLastElsewhere() {
        let fam = family(["BF16", "8b"])
        let bench = BenchmarkFile(models: ["f": FamilyBenchmark(precisions: ["BF16": r(15, j: 9, x: 30), "8b": r(15.2, j: 7, x: 40)])])
        let low = ReferenceEntry(id: "low", name: "Low", wer: 12.9, range: [11.3, 13.3])
        let high = ReferenceEntry(id: "high", name: "High", wer: 16)
        let byWER = sortedRows([fam], references: [high, low], by: .wer, ascending: true, benchmarks: bench).map(\.id)
        XCTAssertEqual(byWER, ["reference:low", "f", "reference:high"])
        XCTAssertEqual(sortedRows([fam], references: [high, low], by: .wer, ascending: false, benchmarks: bench).map(\.id), ["reference:high", "f", "reference:low"])
        // Speed, energy, memory, disk, format: not applicable, so references come last in either direction.
        for metric in [TableMetric.speed, .energy, .format, .memory, .disk] {
            for ascending in [true, false] {
                XCTAssertEqual(sortedRows([fam], references: [high, low], by: metric, ascending: ascending, benchmarks: bench).first?.id, "f", "\(metric)")
            }
        }
        XCTAssertEqual(sortedRows([fam], references: [high, low], by: nil, ascending: true, benchmarks: bench).map(\.name), ["F", "High", "Low"])
    }

    func testReferenceFormattingSaysEstimated() {
        XCTAssertEqual(formatEstimatedErrorRate(13.42), "~13%")
        XCTAssertNil(formatEstimatedErrorRate(nil))
    }

    func testShippedReferencesAreEstimatedWithSourceAndRange() throws {
        let url = resources.appendingPathComponent("benchmarks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Resources/benchmarks.json not measured yet") }
        let file = decodeBenchmarks(try Data(contentsOf: url))
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        XCTAssertEqual(file.references.count, 2)
        for ref in file.references.values {
            XCTAssertEqual(ref.reference, true); XCTAssertEqual(ref.estimated, true); XCTAssertEqual(ref.mode, .dictation)
            let wer = try XCTUnwrap(ref.wer), range = try XCTUnwrap(ref.range)
            XCTAssertEqual(range.count, 2); XCTAssertLessThanOrEqual(range[0], wer); XCTAssertGreaterThanOrEqual(range[1], wer)
            XCTAssertTrue(ref.source?.contains("https://huggingface.co/spaces/hf-audio/open_asr_leaderboard") == true, ref.id)
            XCTAssertFalse(ref.method?.isEmpty ?? true)
            XCTAssertNil(catalog.family(ref.id), "a reference is never a downloadable model")
            XCTAssertNil(file.models[ref.id], "a reference has no measured precisions")
        }
    }
}
