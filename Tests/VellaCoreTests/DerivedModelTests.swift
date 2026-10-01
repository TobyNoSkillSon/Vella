import XCTest
@testable import VellaCore
import VellaTestSupport

final class DerivedModelTests: XCTestCase {
    private var resources: URL { Repository.root.appendingPathComponent("Resources") }
    private func shipped() throws -> ModelCatalog { try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json"))) }
    private func published(_ id: String, _ bytes: Int64 = 1000) -> CatalogVariant {
        CatalogVariant(id: id, repository: "o/\(id)", revision: String(repeating: "a", count: 40), downloadBytes: bytes, architecture: "parakeet")
    }
    private func family(_ variants: [String: CatalogVariant], native: String = "FP32") -> ModelFamily {
        ModelFamily(id: "f", name: "F", mode: .dictation, languages: ["en"], params: "0.6B", license: "mit", native: native, variants: variants)
    }

    func testShippedDerivedVariantsResolveToTheirDownloadSource() throws {
        let catalog = try shipped()
        let ultra = try XCTUnwrap(catalog.family("parakeet-v3-ultra"))
        let v3 = try XCTUnwrap(catalog.family("parakeet-v3"))
        let nemotron = try XCTUnwrap(catalog.family("nemotron-3.5-streaming-0.6b"))
        XCTAssertEqual(
            try ultra.derivation("8b"),
            DerivationRecipe(sourceLabel: "BF16", source: ultra.variants["BF16"]!, dtype: nil, bits: 8, groupSize: 64, floatModules: ["decoder", "joint"]))
        XCTAssertEqual(try ultra.derivation("4b").bits, 4)
        // Parakeet v3's BF16 is a stored conversion (made once at Get): a root, not a derivation; 8 and 4 derive from it.
        XCTAssertThrowsError(try v3.derivation("BF16"))
        XCTAssertEqual(
            try v3.derivation("8b"),
            DerivationRecipe(sourceLabel: "BF16", source: v3.variants["BF16"]!, dtype: nil, bits: 8, groupSize: 64, floatModules: ["decoder", "joint"]))
        XCTAssertEqual(try nemotron.derivation("4b").source.id, "nemotron-3.5-asr-streaming-0.6b-bf16")
        XCTAssertEqual(try nemotron.derivation("8b").source.id, "nemotron-3.5-asr-streaming-0.6b-bf16")
        // Get fetches the root: the 16-bit download, or the stored BF16 (which downloads the FP32 repository).
        XCTAssertEqual(ultra.downloadSource(of: "4b")?.variant.id, "parakeet-ultra-mlx-bf16")
        XCTAssertEqual(v3.downloadSource(of: "BF16")?.label, "BF16")
        XCTAssertEqual(v3.downloadSource(of: "8b")?.variant.id, "parakeet-tdt-0.6b-v3-mlx-bf16-local")
        XCTAssertEqual(v3.acquisition(of: "BF16")?.download.id, "parakeet-tdt-0.6b-v3-mlx-fp32")
        XCTAssertTrue(ultra.isDerived("8b")); XCTAssertFalse(ultra.isDerived("BF16")); XCTAssertTrue(v3.isDerived("4b"))
        // On disk: a derived precision is its root's files; the stored BF16 is half the FP32 download.
        XCTAssertEqual(ultra.diskBytes("4b"), 1254840214)
        XCTAssertEqual(v3.diskBytes("BF16"), 1254508010)
        // Derived variants are not downloads; every install id still resolves, new ones included.
        let downloads = Set(catalogVariants(catalog).map(\.id))
        XCTAssertTrue(downloads.contains("parakeet-tdt-0.6b-v3-mlx-bf16-local"), "the stored BF16 downloads its FP32 source")
        for id in ["parakeet-ultra-mlx-8bit-local", "parakeet-ultra-mlx-4bit-local", "parakeet-tdt-0.6b-v3-mlx-8bit", "nemotron-3.5-asr-streaming-0.6b-4bit-local"] {
            XCTAssertFalse(downloads.contains(id), id)
            XCTAssertNotNil(catalog.locate(variant: id), id)
        }
        XCTAssertEqual(catalog.locate(variant: "parakeet-ultra-mlx-4bit-local")?.precision, "4b")
        for f in catalog.families { XCTAssertEqual(f.derivationProblems(), [], f.id) }
        // Precision options follow tiers_offered (presence); fp32 is never a tier.
        XCTAssertEqual(precisionOptions(ultra), ["BF16", "8b", "4b"])
        XCTAssertEqual(precisionOptions(v3), ["BF16"])
    }

    func testDerivedVariantRoundTripsWithoutDownloadFields() throws {
        let json = #"{"id":"x-4","derivedFrom":"BF16","bits":4,"groupSize":64,"architecture":"parakeet"}"#
        let v = try JSONDecoder().decode(CatalogVariant.self, from: Data(json.utf8))
        XCTAssertTrue(v.isDerived); XCTAssertEqual(v.repository, ""); XCTAssertEqual(v.downloadBytes, 0)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["id", "derivedFrom", "bits", "groupSize", "architecture"])
        XCTAssertEqual(try JSONDecoder().decode(CatalogVariant.self, from: JSONEncoder().encode(v)), v)
        // A downloaded variant still requires its pin.
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogVariant.self, from: Data(#"{"id":"y","architecture":"parakeet"}"#.utf8)))
    }

    func testChainsComposeCastThenQuantizeAndRejectInvalidRecipes() throws {
        let f = family([
            "FP32": published("f32", 4000),
            "BF16": CatalogVariant(id: "b", architecture: "parakeet", derivedFrom: "FP32", dtype: "bfloat16"),
            "4b": CatalogVariant(id: "q", architecture: "parakeet", derivedFrom: "BF16", bits: 4, groupSize: 64)
        ])
        XCTAssertEqual(try f.derivation("4b"), DerivationRecipe(sourceLabel: "FP32", source: f.variants["FP32"]!, dtype: "bfloat16", bits: 4, groupSize: 64))
        XCTAssertEqual(f.downloadSource(of: "4b")?.variant.id, "f32")
        func problem(
            _ label: String, _ v: CatalogVariant,
            native: [String: CatalogVariant] = ["BF16": CatalogVariant(id: "s", repository: "o/s", revision: "r", downloadBytes: 1, architecture: "parakeet")]
        ) -> Bool {
            var variants = native; variants[label] = v
            return !family(variants, native: "BF16").derivationProblems().isEmpty
        }
        XCTAssertTrue(problem("2b", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", bits: 2, groupSize: 64)), "never below 4 bits")
        XCTAssertTrue(problem("4b", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", bits: 8, groupSize: 64)), "label must match bits")
        XCTAssertTrue(problem("4b", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", bits: 4, groupSize: 48)), "group size")
        XCTAssertTrue(problem("4b", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", bits: 4)), "group size required")
        XCTAssertTrue(problem("FP32", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", dtype: "float32")), "never upscale")
        XCTAssertTrue(problem("FP16", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", dtype: "bfloat16")), "BF16 is not FP16")
        XCTAssertTrue(problem("8b", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "FP32", bits: 8, groupSize: 64)), "missing source")
        XCTAssertTrue(problem("8b", CatalogVariant(id: "x", architecture: "whisper", derivedFrom: "BF16", bits: 8, groupSize: 64)), "architecture")
        XCTAssertFalse(problem("8b", CatalogVariant(id: "x", architecture: "parakeet", derivedFrom: "BF16", bits: 8, groupSize: 64)))
        var cyclic = f
        cyclic.variants["FP32"] = CatalogVariant(id: "f32", architecture: "parakeet", derivedFrom: "4b", dtype: "float32")
        XCTAssertThrowsError(try cyclic.derivation("4b"))
        XCTAssertNil(cyclic.downloadSource(of: "4b"))
        // Quantize-then-quantize is rejected.
        let twice = family(
            [
                "BF16": published("s"), "8b": CatalogVariant(id: "e", architecture: "parakeet", derivedFrom: "BF16", bits: 8, groupSize: 64),
                "4b": CatalogVariant(id: "f", architecture: "parakeet", derivedFrom: "8b", bits: 4, groupSize: 64)
            ], native: "BF16")
        XCTAssertThrowsError(try twice.derivation("4b"))
    }

    func testPrepareDerivedModelWritesAManifestDirectoryIdempotently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-derived-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("Models")
        let source = models.appendingPathComponent("parakeet-ultra-mlx-bf16")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        let ultra = try XCTUnwrap(try shipped().family("parakeet-v3-ultra"))
        let path = try prepareDerivedModel(family: ultra, precision: "8b", sourcePath: source.path, modelsDirectory: models)
        XCTAssertEqual(path, models.appendingPathComponent("parakeet-ultra-mlx-8bit-local").standardizedFileURL.path)
        let manifest = try XCTUnwrap(derivedModelManifest(at: URL(fileURLWithPath: path)))
        XCTAssertEqual(
            manifest,
            DerivedModelManifest(
                schema: 1, family: "parakeet-v3-ultra", precision: "8b", source: source.standardizedFileURL.path,
                sourceVariant: "parakeet-ultra-mlx-bf16", sourcePrecision: "BF16", dtype: nil, bits: 8, groupSize: 64,
                floatModules: ["decoder", "joint"]))
        let file = URL(fileURLWithPath: path).appendingPathComponent(DerivedModelManifest.fileName)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(try prepareDerivedModel(family: ultra, precision: "8b", sourcePath: source.path, modelsDirectory: models), path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before, "unchanged manifest is not rewritten")
        // BF16 and 8b of one source get different model paths (worker identity, gate key, residency).
        let four = try prepareDerivedModel(family: ultra, precision: "4b", sourcePath: source.path, modelsDirectory: models)
        XCTAssertNotEqual(four, path)
        XCTAssertThrowsError(try prepareDerivedModel(family: ultra, precision: "BF16", sourcePath: source.path, modelsDirectory: models), "not derived")
        XCTAssertThrowsError(
            try prepareDerivedModel(family: ultra, precision: "8b", sourcePath: root.appendingPathComponent("missing").path, modelsDirectory: models), "source not installed")
        // A directory holding real weights is never written into: the manifest goes to a non-colliding folder beside it.
        try Data().write(to: URL(fileURLWithPath: four).appendingPathComponent("model.safetensors"))
        let beside = try prepareDerivedModel(family: ultra, precision: "4b", sourcePath: source.path, modelsDirectory: models)
        XCTAssertEqual(beside, models.appendingPathComponent("parakeet-ultra-mlx-4bit-local.derived").standardizedFileURL.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: four).sorted(), ["model.safetensors", DerivedModelManifest.fileName])
        // Deleting the source removes its manifest-only directories and leaves anything else.
        XCTAssertEqual(removeDerivedModels(sourcePath: source.path, modelsDirectory: models).sorted(), [beside, path].sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: four))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMemoryIsMeasuredWhenAvailableElseAScaledEstimateWithANote() throws {
        let catalog = try shipped()
        let nemotron = try XCTUnwrap(catalog.family("nemotron-3.5-streaming-0.6b"))
        let bench = BenchmarkFile(models: [
            "nemotron-3.5-streaming-0.6b": FamilyBenchmark(precisions: [
                "BF16": PrecisionResult(memory_mb: 1400), "8b": PrecisionResult(memory_mb: 900)
            ])
        ])
        XCTAssertEqual(estimatedMemory(family: nemotron, precision: "8b", benchmarks: bench), MemoryEstimate(mb: 900, measured: true, note: nil))
        let four = try XCTUnwrap(estimatedMemory(family: nemotron, precision: "4b", benchmarks: bench))
        XCTAssertFalse(four.measured)
        XCTAssertTrue(four.note?.contains("BF16") == true && four.note?.contains("not measured") == true, four.note ?? "")
        // 4-bit group-64 weights over 85 % of the bytes: 1400 × (0.85 × 4.5/16 + 0.15) ≈ 544.7 MB.
        XCTAssertEqual(four.mb, 1400 * (0.85 * 4.5 / 16 + 0.15), accuracy: 0.01)
        // The weight model reproduces the published Nemotron 8b size from BF16 within 2 %.
        let predicted8 = try XCTUnwrap(estimatedWeightBytes(FamilyTestHelper.derived8(nemotron), "8b"))
        XCTAssertEqual(predicted8 / 756247988, 1, accuracy: 0.02)
        XCTAssertNil(estimatedMemory(family: nemotron, precision: "4b", benchmarks: BenchmarkFile()), "nothing measured: no number")
    }

    /// Mixed per-layer recipe (Whisper 8 tiers: encoder FP16, decoder affine-8 g64): the catalog fields reach the worker
    /// manifest, uniform manifests keep their bytes, the size estimate keeps the float share at 16 bits, and a mixed
    /// tier always loads from its root (never a checkpoint registered under its id, such as a re-keyed uniform import).
    func testMixedRecipeFloatModules() throws {
        let json = #"{"id":"x-8","derivedFrom":"FP16","bits":8,"groupSize":64,"floatModules":["model.encoder"],"floatShare":0.4,"architecture":"whisper"}"#
        let v = try JSONDecoder().decode(CatalogVariant.self, from: Data(json.utf8))
        XCTAssertEqual(v.floatModules, ["model.encoder"]); XCTAssertEqual(v.floatShare, 0.4)
        XCTAssertEqual(try JSONDecoder().decode(CatalogVariant.self, from: JSONEncoder().encode(v)), v)
        let native = ["FP16": published("s", 3000)]
        func whisper(_ eight: CatalogVariant) -> ModelFamily {
            var variants = native; variants["8b"] = eight
            return ModelFamily(id: "w", name: "W", mode: .dictation, languages: ["en"], params: "1B", license: "mit", native: "FP16", variants: variants)
        }
        func mixed(_ modules: [String]?, _ share: Double?, bits: Int? = 8, dtype: String? = nil) -> CatalogVariant {
            var v = CatalogVariant(id: "m", architecture: "parakeet", derivedFrom: "FP16", bits: bits, groupSize: bits == nil ? nil : 64, dtype: dtype)
            v.floatModules = modules; v.floatShare = share
            return v
        }
        XCTAssertEqual(whisper(mixed(["model.encoder"], 0.4)).derivationProblems(), [])
        XCTAssertEqual(try whisper(mixed(["model.encoder"], 0.4)).derivation("8b").floatModules, ["model.encoder"])
        for (index, bad) in [
            mixed(["model.encoder"], nil), mixed(nil, 0.4), mixed([], 0.4), mixed(["a/b"], 0.4), mixed([".x"], 0.4),
            mixed(["model.encoder"], 1.2), mixed(["model.encoder", "model.encoder"], 0.4)
        ].enumerated() {
            XCTAssertFalse(whisper(bad).derivationProblems().isEmpty, "case \(index)")
        }
        // Uniform recipes: unchanged recipe and size.
        let uniform = whisper(CatalogVariant(id: "u", architecture: "parakeet", derivedFrom: "FP16", bits: 8, groupSize: 64))
        XCTAssertEqual(try uniform.derivation("8b").floatModules, [])
        XCTAssertEqual(try XCTUnwrap(estimatedWeightBytes(uniform, "8b")), 3000 * (0.85 * 8.5 / 16 + 0.15), accuracy: 1e-6)
        XCTAssertEqual(
            try XCTUnwrap(estimatedWeightBytes(whisper(mixed(["model.encoder"], 0.4)), "8b")), 3000 * (0.45 * 8.5 / 16 + 0.4 + 0.15), accuracy: 1e-6)
        // The shipped Whisper 8 tiers are the mixed recipe; the worker manifest carries it.
        let catalog = try shipped()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-mixed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("Models")
        let source = models.appendingPathComponent("whisper-large-v3-asr-fp16")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        for id in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            let f = try XCTUnwrap(catalog.family(id))
            XCTAssertEqual(f.variants["8b"]?.floatModules, ["model.encoder"], id)
            XCTAssertNil(f.variants["4b"]?.floatModules, id)
        }
        // Parakeet v3 / v3 Ultra 8 and 4 tiers: decoder and joint keep BF16 (plain affine g64 elsewhere).
        for id in ["parakeet-v3", "parakeet-v3-ultra"] {
            let f = try XCTUnwrap(catalog.family(id))
            for tier in ["8b", "4b"] {
                XCTAssertEqual(f.variants[tier]?.floatModules, ["decoder", "joint"], "\(id) \(tier)")
                XCTAssertEqual(f.variants[tier]?.groupSize, 64, "\(id) \(tier)")
                XCTAssertEqual(try f.derivation(tier).floatModules, ["decoder", "joint"], "\(id) \(tier)")
            }
        }
        let large = try XCTUnwrap(catalog.family("whisper-large-v3"))
        let path = try prepareDerivedModel(family: large, precision: "8b", sourcePath: source.path, modelsDirectory: models)
        XCTAssertEqual(derivedModelManifest(at: URL(fileURLWithPath: path))?.floatModules, ["model.encoder"])
        let four = try prepareDerivedModel(family: large, precision: "4b", sourcePath: source.path, modelsDirectory: models)
        let fourFile = URL(fileURLWithPath: four).appendingPathComponent(DerivedModelManifest.fileName)
        let fourObject = try JSONSerialization.jsonObject(with: Data(contentsOf: fourFile)) as? [String: Any]
        XCTAssertNil(fourObject?["floatModules"], "uniform manifests keep their keys")
        // A uniform checkpoint registered under the mixed tier's id is never that tier: without the root it needs a Get,
        // with the root the recipe is made from the root.
        let imported = root.appendingPathComponent("outside/q8").path
        let registered: [String: String] = ["whisper-large-v3-8bit": imported]
        XCTAssertNil(registeredCheckpoint(large, "8b", installedPath: { registered[$0] }))
        XCTAssertFalse(precisionAvailable(large, "8b", installedPath: { registered[$0] }))
        XCTAssertNil(try precisionLoadPath(large, "8b", installedPath: { registered[$0] }, modelsDirectory: models))
        let both = registered.merging(["whisper-large-v3-asr-fp16": source.path]) { $1 }
        XCTAssertEqual(try precisionLoadPath(large, "8b", installedPath: { both[$0] }, modelsDirectory: models), path)
        // A uniform tier keeps its registered checkpoint.
        XCTAssertEqual(registeredCheckpoint(large, "4b", installedPath: { ["whisper-large-v3-asr-4bit": "/x/q4"][$0] }), "/x/q4")
    }
}

private enum FamilyTestHelper {
    /// Nemotron with its 8b replaced by a derived 8b, to compare the estimate with the published file size.
    static func derived8(_ f: ModelFamily) -> ModelFamily {
        var copy = f
        copy.variants["8b"] = CatalogVariant(id: "n8", architecture: "nemotron_asr", derivedFrom: "BF16", bits: 8, groupSize: 64)
        return copy
    }
}
