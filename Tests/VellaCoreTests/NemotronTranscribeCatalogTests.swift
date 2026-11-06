import XCTest
@testable import VellaCore
import VellaTestSupport
import VellaWire

/// Nemotron 3.5 Transcribe 30B-A4B (Toby, 28 Oct 2026): a Dictation model downloaded as NVIDIA's bf16 release, with int8
/// and int4 made from it at load like every family's (the worker's loader applies this architecture's mix). Each tier is
/// offered only where this Mac's memory holds it (MemoryFit.swift); never the first-run model, never downloaded or
/// loaded without the user's Get. No inference.
final class NemotronTranscribeCatalogTests: XCTestCase {
    static let id = "nemotron-3.5-transcribe"
    private func family() throws -> ModelFamily {
        let catalog = try decodeCatalog(Data(contentsOf: Repository.root.appendingPathComponent("Resources/models.json")))
        return try XCTUnwrap(catalog.family(Self.id))
    }
    private static func gb(_ value: Double) -> UInt64 { UInt64(value * 1_073_741_824) }

    func testEntryDecodesAndResolvesToItsDescriptor() throws {
        let f = try family()
        XCTAssertEqual(f.mode, .dictation)
        XCTAssertEqual(f.params, "30B-A4B")
        XCTAssertEqual(paramsColumnText(f.params), "30B", "one line in the Params column")
        XCTAssertEqual(paramsColumnText("0.6B"), "0.6B")
        XCTAssertEqual(f.languages.count, 40)
        XCTAssertEqual(f.licence, "OpenMDW-1.1")
        XCTAssertEqual(f.publisher, "NVIDIA")
        XCTAssertEqual(precisionOptions(f), ["BF16", "8b", "4b"])
        XCTAssertEqual(["16", "8", "4"].map { tierDTypeLabel(f, ModelTier(rawValue: $0)!) }, ["bf16", "int8", "int4"])
        for variant in f.variants.values {
            XCTAssertEqual(variant.architecture, Architecture.nemotronTranscribe.rawValue)
            let descriptor = try XCTUnwrap(ModelRegistry.descriptor(architecture: variant.architecture))
            XCTAssertEqual(descriptor.mode, .dictation)
            XCTAssertTrue(descriptor.catalogFamilies.contains(Self.id))
            XCTAssertFalse(descriptor.calibratable, "Vella never loads a 21-70 GB model by itself to calibrate it")
        }
        // NVIDIA's NeMo layout declares nemo_speechlm; it loads as the same architecture.
        XCTAssertEqual(
            checkpointArchitecture(["model_type": "nemo_speechlm", "architectures": ["Nemotron3_5TranscribeForConditionalGeneration"]]),
            "nemotron_transcribe")
        XCTAssertEqual(checkpointArchitecture(["model_type": "nemo_speechlm", "architectures": ["SomethingElse"]]), "nemo_speechlm")
        XCTAssertEqual(quantizedActivations[Self.id], .half)
    }

    /// The family rule (Toby, 28 Oct 2026, 21:38): the 16-bit checkpoint is the one download; 8 and 4 are made from it.
    func testInt8AndInt4AreMadeFromTheBF16Download() throws {
        let f = try family()
        XCTAssertEqual(f.derivationProblems(), [])
        let bf16 = try XCTUnwrap(f.variants["BF16"])
        XCTAssertFalse(bf16.isDerived)
        XCTAssertEqual(bf16.repository, "nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B")
        XCTAssertEqual(bf16.revision, "ef905575a106fdad904f3b0ce661dccad654607d")
        XCTAssertEqual(bf16.downloadBytes, 67_513_686_219)
        XCTAssertEqual(f.download, CatalogDownload(repo: bf16.repository, revision: bf16.revision, bytes: bf16.downloadBytes, convert_to: ["8", "4"]))
        let files = try XCTUnwrap(bf16.files)
        for name in ["model.safetensors", "config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json", "LICENSE",
            "THIRD_PARTY_NOTICES.md", "licenses/Qwen3-ASR-LICENSE.txt", "licenses/vLLM-LICENSE.txt", "README.md"]
        {
            XCTAssertTrue(files.contains(name), name)
        }
        XCTAssertFalse(files.contains { $0.hasPrefix("llm_backbone/") || $0.hasPrefix(".") || $0.hasSuffix(".png") }, "upstream-only files stay there")
        for (label, bits) in [("8b", 8), ("4b", 4)] {
            let v = try XCTUnwrap(f.variants[label])
            XCTAssertEqual(v.derivedFrom, "BF16", label); XCTAssertEqual(v.bits, bits); XCTAssertEqual(v.groupSize, 64)
            XCTAssertEqual(v.architecture, "nemotron_transcribe")
            XCTAssertNil(v.floatModules, "the mix is the worker loader's, as Qwen's float audio tower"); XCTAssertNil(v.floatShare)
            XCTAssertNil(v.files); XCTAssertEqual(v.repository, ""); XCTAssertEqual(v.downloadBytes, 0)
            XCTAssertTrue(f.isDerived(label))
            XCTAssertEqual(f.downloadSource(of: label)?.variant.id, bf16.id, "\(label) is made from the bf16 download")
            XCTAssertEqual(f.acquisition(of: label)?.download.id, bf16.id)
            XCTAssertNil(f.acquisition(of: label)?.convert)
            XCTAssertEqual(f.diskBytes(label), bf16.downloadBytes, "\(label) stores nothing of its own")
            let recipe = try f.derivation(label)
            XCTAssertEqual(recipe.sourceLabel, "BF16"); XCTAssertEqual(recipe.bits, bits); XCTAssertEqual(recipe.floatModules, [])
            let prompt = try XCTUnwrap(downloadPrompt(family: f, precision: label, followUp: .load, freeBytes: 1_000_000_000_000))
            XCTAssertEqual(prompt.variantID, bf16.id); XCTAssertEqual(prompt.downloadBytes, bf16.downloadBytes)
        }
        // The downloader sees one record for the family, the bf16 one with its file list.
        let records = catalogVariants(ModelCatalog(families: [f]))
        XCTAssertEqual(records.map(\.id), [bf16.id])
        XCTAssertEqual(records.first?.files, files)
        XCTAssertEqual(records.first?.quantization, "BF16")
    }

    /// Load of a made precision writes the manifest-only directory the worker quantizes from (as for every family).
    func testPreparedDerivedModelIsAManifestReadingTheBF16Folder() throws {
        let f = try family()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-nt-derived-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("Models")
        let source = models.appendingPathComponent(f.variants["BF16"]!.id)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"model_type": "nemo_speechlm", "architectures": ["Nemotron3_5TranscribeForConditionalGeneration"]}"#.utf8)
            .write(to: source.appendingPathComponent("config.json"))
        let installed = [f.variants["BF16"]!.id: source.path]
        for (label, bits) in [("8b", 8), ("4b", 4)] {
            let path = try XCTUnwrap(try precisionLoadPath(f, label, installedPath: { installed[$0] }, modelsDirectory: models))
            XCTAssertEqual(path, try prepareDerivedModel(family: f, precision: label, sourcePath: source.path, modelsDirectory: models))
            let manifest = try XCTUnwrap(derivedModelManifest(at: URL(fileURLWithPath: path)))
            XCTAssertEqual(manifest.family, Self.id); XCTAssertEqual(manifest.precision, label)
            XCTAssertEqual(manifest.source, source.standardizedFileURL.path)
            XCTAssertEqual(manifest.bits, bits); XCTAssertEqual(manifest.groupSize, 64)
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            XCTAssertEqual(contents, [DerivedModelManifest.fileName], "no weights of its own")
            XCTAssertTrue(precisionAvailable(f, label) { installed[$0] })
        }
        XCTAssertFalse(precisionAvailable(f, "4b") { _ in nil }, "without the bf16 download nothing is available")
    }

    /// The fit rule (peak + 16 GB within the Mac's memory, rounded up to a size Macs ship with) gives 96 / 64 / 48 GB.
    func testMemoryFloorsPerTier() throws {
        let f = try family()
        XCTAssertEqual(minimumMemoryGB(f, "BF16"), 96)
        XCTAssertEqual(minimumMemoryGB(f, "8b"), 64)
        XCTAssertEqual(minimumMemoryGB(f, "4b"), 48)
        XCTAssertEqual(f.variants["4b"]?.peakMemoryEstimated, nil, "int4's peak is measured")
        XCTAssertEqual(f.variants["8b"]?.peakMemoryEstimated, nil, "measured 6 Nov")
        XCTAssertEqual(f.variants["BF16"]?.peakMemoryEstimated, nil, "measured 6 Nov")
        XCTAssertNil(minimumMemoryGB(peakMB: 600_000))
        // No other family has a floor: they run on every Mac Vella supports.
        let catalog = try decodeCatalog(Data(contentsOf: Repository.root.appendingPathComponent("Resources/models.json")))
        for other in catalog.families where other.id != Self.id {
            for label in other.variants.keys { XCTAssertNil(minimumMemoryGB(other, label), "\(other.id) \(label)") }
            XCTAssertNil(SelectionRules(family: other, benchmark: nil, physicalMemoryBytes: Self.gb(8)).rowMemoryRefusal, other.id)
        }
    }

    func testTiersOfferedAtEachMemorySize() throws {
        let f = try family()
        let expected: [(Double, [ModelTier])] = [
            (16, []), (32, []), (36, []), (47.9, []), (48, [.t4]), (63.9, [.t4]), (64, [.t8, .t4]), (95.9, [.t8, .t4]),
            (96, [.t16, .t8, .t4]), (128, [.t16, .t8, .t4])
        ]
        for (memory, tiers) in expected {
            let rules = SelectionRules(family: f, benchmark: nil, physicalMemoryBytes: Self.gb(memory))
            for mode in OptimizedMode.allCases { XCTAssertEqual(rules.precisions(mode), tiers, "\(memory) GB \(mode)") }
            for tier in ModelTier.allCases {
                let refusal = rules.cellRefusal(ModelSelection(tier: tier, mode: .fast))
                if tiers.contains(tier) {
                    XCTAssertNil(refusal, "\(memory) GB \(tier)")
                } else {
                    XCTAssertEqual(refusal, "Needs \(["16": 96, "8": 64, "4": 48][tier.rawValue]!) GB of memory", "\(memory) GB \(tier)")
                }
            }
            XCTAssertEqual(rules.rowMemoryRefusal, tiers.isEmpty ? "Needs 48 GB of memory" : nil, "\(memory) GB")
            // An unloaded family resolves only to a tier that fits (the runtime and the API use the same rule).
            let chosen = rules.runnable(recorded: ModelSelection(tier: .t16, mode: .fast), precision: nil, recommended: .t4)
            if let first = tiers.first { XCTAssertEqual(chosen.tier, first, "\(memory) GB") }
        }
        // Without a memory figure (fixtures), nothing is gated.
        XCTAssertEqual(SelectionRules(family: f, benchmark: nil).precisions(.fast), [.t16, .t8, .t4])
    }

    func testAdmissionUsesTheTierPeak() throws {
        let f = try family()
        let empty = decodeBenchmarks(Data(#"{"schema": 2, "models": {}}"#.utf8))
        XCTAssertEqual(estimatedMemory(family: f, precision: "4b", benchmarks: empty), MemoryEstimate(mb: 24_050, measured: true, note: nil))
        XCTAssertEqual(estimatedMemory(family: f, precision: "BF16", benchmarks: empty)?.mb, 65_250)
        XCTAssertEqual(estimatedMemory(family: f, precision: "BF16", benchmarks: empty)?.measured, true)
        XCTAssertEqual(catalogPeakMemoryText(f.variants["4b"]), "24.05 GB")
        XCTAssertEqual(catalogPeakMemoryText(f.variants["8b"]), "37.54 GB")
        XCTAssertEqual(catalogPeakMemoryText(f.variants["BF16"]), "65.25 GB")
        XCTAssertTrue(catalogPeakMemoryHelp(f.variants["BF16"]!).contains("Measured on M5 Max"))
        XCTAssertTrue(catalogPeakMemoryHelp(f.variants["4b"]!).contains("Measured on M5 Max"))
    }

    func testTooltipsNameTheRecipeAndTheLicence() throws {
        let f = try family()
        let help = modelHelp(f)
        XCTAssertTrue(help.contains("NVIDIA, 2026 \u{00b7} OpenMDW-1.1"), help)
        XCTAssertTrue(help.contains("30B-A4B parameters"), help)
        XCTAssertEqual(
            tierFlavour(f, tier: .t4, cell: nil),
            "4-bit routed experts, 8-bit other decoder projections, 16-bit embeddings, 16-bit head and encoders (affine-4 g64)")
        XCTAssertEqual(tierFlavour(f, tier: .t8, cell: nil), "8-bit decoder projections, 16-bit embeddings, 16-bit head and encoders (affine-8 g64)")
        XCTAssertEqual(tierFlavour(f, tier: .t16, cell: nil), "bf16, as published")
        XCTAssertTrue(f.notes?.contains("made on this Mac from it at load") == true)
        // No other family states a mix of its own: their recipes come from the uniform quantization fields.
        let catalog = try decodeCatalog(Data(contentsOf: Repository.root.appendingPathComponent("Resources/models.json")))
        XCTAssertTrue(catalog.families.filter { $0.id != "nemotron-3.5-transcribe" }.allSatisfy { $0.variants.values.allSatisfy { $0.recipe == nil } })
    }

    // MARK: Get (downloader), with local fixtures only

    private func fixtureFolder(_ files: [String: String], config: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-nt-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, body) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        return root
    }

    /// After Get the folder must hold every listed file, licence and notices included; NVIDIA's NeMo layout validates as bf16.
    func testValidationRequiresTheLicenceFilesInNvidiasLayout() throws {
        let f = try family()
        let record = try XCTUnwrap(catalogVariants(ModelCatalog(families: [f])).first)
        let body = Dictionary(uniqueKeysWithValues: (record.files ?? []).filter { $0 != "config.json" }.map { ($0, $0.hasSuffix(".json") ? "{}" : "x") })
        let config: [String: Any] = ["model_type": "nemo_speechlm", "architectures": ["Nemotron3_5TranscribeForConditionalGeneration"]]
        let folder = try fixtureFolder(body, config: config)
        XCTAssertNoThrow(try NativeModelDownload.validate(folder, expected: record))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("licenses/vLLM-LICENSE.txt"))
        XCTAssertThrowsError(try NativeModelDownload.validate(folder, expected: record)) {
            XCTAssertEqual($0.localizedDescription, "The model folder is missing licenses/vLLM-LICENSE.txt")
        }
    }

    /// Where Toby's local copy of NVIDIA's release exists, every listed file is there and they add up to the catalog's
    /// download size (file sizes only; nothing is read or loaded).
    func testLocalCopyMatchesTheCatalog() throws {
        let f = try family()
        let v = try XCTUnwrap(f.variants["BF16"])
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path), "no local copy on this Mac")
        let sizes = try (v.files ?? []).map { name -> Int64 in
            ((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))[.size] as? NSNumber)?.int64Value ?? -1
        }
        XCTAssertEqual(sizes.reduce(0, +), v.downloadBytes)
    }
}
