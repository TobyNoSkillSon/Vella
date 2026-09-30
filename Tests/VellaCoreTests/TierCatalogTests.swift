import XCTest
@testable import VellaCore
import VellaTestSupport

/// The final family design's catalog and download rules (Toby, 29 Sep 2026; lab/notes/models-table-ROUND.md): tiers
/// 16/8/4 only (fp32 never), 16 = the published 16-bit checkpoint or an fp32 source converted once at Get, 8 and 4
/// derived locally with affine g64 from 16, never from a quantized source; the Get flow offers only present tiers.
final class TierCatalogTests: XCTestCase {
    private var resources: URL {
        Repository.root.appendingPathComponent("Resources")
    }
    private func catalog() throws -> ModelCatalog { try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json"))) }

    func testShippedTiersFollowPresence() throws {
        let c = try catalog()
        let tiers = Dictionary(uniqueKeysWithValues: c.families.map { ($0.id, $0.tiersOffered ?? []) })
        // Presence today (v-family correction, 29 Sep): a tier is absent only when it breaks.
        XCTAssertEqual(
            tiers,
            [
                "parakeet-v3-ultra": ["16", "8", "4"], "parakeet-v3": ["16"], "qwen3-asr-1.7b": ["16"],
                "qwen3-asr-0.6b": ["16", "8"], "whisper-large-v3": ["16", "8"], "whisper-large-v3-turbo": ["16", "8"],
                "nemotron-3.5-streaming-0.6b": ["16", "8"]
            ])
        XCTAssertEqual(precisionOptions(try XCTUnwrap(c.family("parakeet-v3"))), ["BF16"], "fp32 is never a tier")
        XCTAssertEqual(precisionOptions(try XCTUnwrap(c.family("parakeet-v3-ultra"))), ["BF16", "8b", "4b"])
        XCTAssertEqual(precisionOptions(try XCTUnwrap(c.family("whisper-large-v3"))), ["FP16", "8b"])
        XCTAssertEqual(precisionOptions(try XCTUnwrap(c.family("qwen3-asr-1.7b"))), ["BF16"])
        XCTAssertEqual(precisionOptions(try XCTUnwrap(c.family("nemotron-3.5-streaming-0.6b"))), ["BF16", "8b"])
    }

    /// `tiers_offered` is the tiers benchmarks.json marks present (schema 2 `tiers.<t>.presence.offered`).
    func testTiersOfferedMatchBenchmarkPresence() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("benchmarks.json"))) as? [String: Any]
        let models = try XCTUnwrap(object?["models"] as? [String: Any])
        for f in try catalog().families {
            guard let tiers = (models[f.id] as? [String: Any])?["tiers"] as? [String: Any] else { continue }
            let present = tiers.compactMap { key, value -> String? in
                ((value as? [String: Any])?["presence"] as? [String: Any])?["offered"] as? Bool == true ? key : nil
            }
            XCTAssertEqual(Set(present), Set(f.tiersOffered ?? []), f.id)
        }
    }

    func testEveryFamilyDownloadsItsSixteenBitCheckpointAndDerivesTheRest() throws {
        for f in try catalog().families {
            let download = try XCTUnwrap(f.download, f.id)
            XCTAssertEqual(f.derivationProblems(), [], f.id)
            XCTAssertTrue(["bfloat16", "float16", "float32"].contains(f.nativeDType ?? ""), f.id)
            // The download is the 16-bit variant, or for an fp32-only model its fp32 source (converted at Get).
            let sixteen = try XCTUnwrap(precisionLabel(f, tier: .t16), f.id)
            let v16 = try XCTUnwrap(f.variants[sixteen])
            let root = v16.isStored ? try XCTUnwrap(f.variants[v16.derivedFrom ?? ""]) : v16
            XCTAssertFalse(root.isDerived, f.id)
            XCTAssertEqual([download.repo, download.revision], [root.repository, root.revision], f.id)
            XCTAssertEqual(download.bytes, root.downloadBytes, f.id)
            XCTAssertEqual(f.nativeDType == "float32", v16.isStored, "only an fp32-only model converts its 16 at Get: \(f.id)")
            // 8 and 4: affine g64 from the 16-bit variant, never downloaded, never from a quantized source.
            for label in ["8b", "4b"] {
                guard let v = f.variants[label] else { continue }
                XCTAssertEqual(v.derivedFrom, sixteen, "\(f.id) \(label)")
                XCTAssertEqual(v.groupSize, 64, "\(f.id) \(label)")
                XCTAssertEqual(v.bits, label == "8b" ? 8 : 4)
                XCTAssertEqual(v.repository, "", "\(f.id) \(label) is made on this Mac")
                XCTAssertTrue(download.convert_to.contains(label == "8b" ? "8" : "4"), "\(f.id) \(label)")
            }
            // Only the one published checkpoint per family is downloadable: no quantized repository anywhere.
            XCTAssertEqual(f.variants.values.filter { !$0.isDerived }.count, 1, f.id)
            XCTAssertNil(download.vendor_quant_repo, f.id)
            for tier in f.tiersOffered ?? [] { XCTAssertNotNil(ModelTier(rawValue: tier).flatMap { precisionLabel(f, tier: $0) }, "\(f.id) \(tier)") }
        }
        // The downloader list: the published 16-bit checkpoints, and Parakeet v3's stored BF16 (its FP32 repository).
        let records = catalogVariants(try catalog())
        let bf16 = try XCTUnwrap(records.first { $0.id == "parakeet-tdt-0.6b-v3-mlx-bf16-local" })
        XCTAssertEqual(bf16.repository, "animaslabs/parakeet-tdt-0.6b-v3-mlx")
        XCTAssertEqual(bf16.quantization, "BF16")
        XCTAssertFalse(records.contains { $0.quantization.hasSuffix("-bit") }, "no quantized download")
    }

    func testTobysInstalledVariantsMapOntoPresentTiers() throws {
        let c = try catalog()
        // Kept install ids: an earlier download of exactly a tier's format counts as that tier.
        XCTAssertEqual(c.locate(variant: "nemotron-3.5-asr-streaming-0.6b-8bit")?.precision, "8b")
        XCTAssertEqual(c.locate(variant: "parakeet-ultra-mlx-bf16")?.precision, "BF16")
        XCTAssertEqual(c.locate(variant: "Qwen3-ASR-1.7B-bf16")?.precision, "BF16")
        // Parakeet v3 4-bit stays a known id (tier 4 is absent, so it is not shown); the imported Whisper q8 maps to 8.
        XCTAssertEqual(c.locate(variant: "parakeet-tdt-0.6b-v3-mlx-4bit")?.precision, "4b")
        XCTAssertEqual(c.family("whisper-large-v3")?.precision(ofLegacyID: "imported-whisper-large-v3-q8"), "8b")
        XCTAssertNil(c.locate(variant: "Voxtral-Mini-4B-Realtime-2602-4bit"), "a removed model's id is not in the catalog")
    }

    // MARK: Resolution to files (no silent fallback to another tier)

    private let fixture = ModelFamily(
        id: "p", name: "P", mode: .dictation, languages: ["en"], params: "0.6B", license: "mit", native: "FP32",
        variants: [
            "FP32": CatalogVariant(id: "p-fp32", repository: "o/p", revision: String(repeating: "a", count: 40), downloadBytes: 2_000_000_000, architecture: "parakeet"),
            "BF16": {
                var v = CatalogVariant(id: "p-bf16", architecture: "parakeet", derivedFrom: "FP32", dtype: "bfloat16"); v.stored = true; return v
            }(),
            "8b": CatalogVariant(id: "p-8bit", architecture: "parakeet", derivedFrom: "BF16", bits: 8, groupSize: 64)
        ], tiersOffered: ["16", "8"])

    func testStoredConversionIsARootAndFp32IsNotATier() throws {
        XCTAssertEqual(fixture.derivationProblems(), [])
        XCTAssertEqual(precisionOptions(fixture), ["BF16", "8b"])
        XCTAssertEqual(fixture.downloadSource(of: "BF16")?.variant.id, "p-bf16", "Get fetches the stored variant itself")
        XCTAssertEqual(fixture.downloadSource(of: "8b")?.variant.id, "p-bf16", "8 is made from the stored 16, not from fp32")
        let recipe = try fixture.derivation("8b")
        XCTAssertEqual(recipe.sourceLabel, "BF16"); XCTAssertNil(recipe.dtype); XCTAssertEqual(recipe.bits, 8)
        let acquisition = try XCTUnwrap(fixture.acquisition(of: "8b"))
        XCTAssertEqual(acquisition.download.id, "p-fp32"); XCTAssertEqual(acquisition.convert, "bfloat16")
        XCTAssertEqual(estimatedWeightBytes(fixture, "BF16"), 1_000_000_000)
        XCTAssertEqual(fixture.diskBytes("BF16"), 1_000_000_000, "stored only as bf16")
    }

    func testAvailabilityNeverFallsBackToAnotherTier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-tiers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String) throws -> String {
            let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url.appendingPathComponent("config.json")); return url.path
        }
        let models = root.appendingPathComponent("Models")
        // Only an old FP32 download: neither 16 (stored bf16 needs its Get) nor 8 is available.
        var installed = ["p-fp32": try folder("fp32")]
        XCTAssertFalse(precisionAvailable(fixture, "BF16") { installed[$0] })
        XCTAssertFalse(precisionAvailable(fixture, "8b") { installed[$0] })
        XCTAssertNil(try precisionLoadPath(fixture, "8b", installedPath: { installed[$0] }, modelsDirectory: models))
        // After the Get: 16 loads its own folder, 8 gets a manifest reading it.
        installed["p-bf16"] = try folder("bf16")
        XCTAssertEqual(try precisionLoadPath(fixture, "BF16", installedPath: { installed[$0] }, modelsDirectory: models), installed["p-bf16"])
        let eight = try XCTUnwrap(try precisionLoadPath(fixture, "8b", installedPath: { installed[$0] }, modelsDirectory: models))
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: eight))?.source, URL(fileURLWithPath: installed["p-bf16"]!).standardizedFileURL.path)
        // An earlier checkpoint registered under the 8b id itself loads as is (no manifest).
        installed["p-8bit"] = try folder("published-8bit")
        XCTAssertEqual(try precisionLoadPath(fixture, "8b", installedPath: { installed[$0] }, modelsDirectory: models), installed["p-8bit"])
    }

    func testNeverQuantizeFromAQuantizedSource() {
        let bad = ModelFamily(
            id: "q", name: "Q", mode: .dictation, languages: [], params: "", license: "", native: "8b",
            variants: [
                "8b": CatalogVariant(id: "q8", repository: "o/q8", revision: String(repeating: "b", count: 40), downloadBytes: 1, architecture: "parakeet"),
                "4b": CatalogVariant(id: "q4", architecture: "parakeet", derivedFrom: "8b", bits: 4, groupSize: 64)
            ])
        XCTAssertEqual(bad.derivationProblems().count, 1)
        XCTAssertThrowsError(try bad.derivation("4b"))
    }

    // MARK: Get pop-up

    func testGetPopUpStatesDownloadConversionAndStoredSize() throws {
        let c = try catalog()
        let v3 = try XCTUnwrap(c.family("parakeet-v3"))
        let bf16 = try XCTUnwrap(downloadPrompt(family: v3, precision: "BF16", followUp: .load, freeBytes: 812_000_000_000))
        XCTAssertEqual(bf16.title, "Download Parakeet v3 · 16 (BF16)?")
        XCTAssertEqual(bf16.variantID, "parakeet-tdt-0.6b-v3-mlx-bf16-local")
        XCTAssertEqual(
            bf16.body,
            """
            Parakeet v3 is published as FP32 (float32) on Hugging Face: animaslabs/parakeet-tdt-0.6b-v3-mlx at revision b3f0e8a. Vella converts it once to BF16 (bfloat16) and keeps only those weights.

            Download: 2.51 GB (2,509,016,021 bytes). Conversion: about 3 s once. Stored: 1.25 GB; disk needed while converting: 3.76 GB; 812 GB free.

            When the download finishes, it loads for dictation.
            """)
        let ultra = try XCTUnwrap(c.family("parakeet-v3-ultra"))
        let eight = try XCTUnwrap(downloadPrompt(family: ultra, precision: "8b", followUp: .reload(from: "BF16"), freeBytes: nil))
        XCTAssertEqual(eight.title, "Download Parakeet v3 Ultra · 16 (BF16) to make 8 (8-bit)?")
        XCTAssertEqual(eight.variantID, "parakeet-ultra-mlx-bf16")
        XCTAssertEqual(
            eight.body,
            """
            Parakeet v3 Ultra at BF16 (bfloat16), as published on Hugging Face: selcukkubur/parakeet-ultra-mlx at revision b554592.

            8-bit (affine, group 64) is made on this Mac from the 16-bit weights each time it loads; only a small recipe file is added.

            Download: 1.25 GB (1,254,840,214 bytes). Conversion: about 2 s at each load. Stored: 1.25 GB.

            When the download finishes, it loads for dictation in place of the loaded BF16.
            """)
        let whisper = try XCTUnwrap(c.family("whisper-large-v3"))
        let sixteen = try XCTUnwrap(downloadPrompt(family: whisper, precision: "FP16", followUp: .transcribe, freeBytes: 100))
        XCTAssertTrue(sixteen.body.contains("Download: 3.09 GB (3,087,748,437 bytes). Stored: 3.09 GB; 100 bytes free. Not enough free disk space."), sixteen.body)
        // An absent tier is never offered, and fp32 is never a tier.
        XCTAssertNil(downloadPrompt(family: whisper, precision: "4b", followUp: .load, freeBytes: nil))
        XCTAssertNil(downloadPrompt(family: v3, precision: "8b", followUp: .load, freeBytes: nil))
        XCTAssertNil(downloadPrompt(family: v3, precision: "FP32", followUp: .load, freeBytes: nil))
    }
}
