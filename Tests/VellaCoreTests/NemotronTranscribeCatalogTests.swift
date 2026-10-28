import XCTest
@testable import VellaCore
import VellaTestSupport
import VellaWire

/// Nemotron 3.5 Transcribe 30B-A4B (Toby, 28 Oct 2026): a Dictation model in three tiers that are each their own
/// download (NVIDIA's bf16, Vella's mixed int8 and int4), each offered only where this Mac's memory holds it
/// (MemoryFit.swift), never the first-run model, never downloaded or loaded without the user's Get. No inference.
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

    /// The departure from the family rule: every tier is its own pinned download, none is made on this Mac.
    func testEveryTierIsItsOwnDownloadWithItsLicenceFiles() throws {
        let f = try family()
        XCTAssertEqual(f.derivationProblems(), [])
        XCTAssertEqual(f.download?.convert_to, [], "nothing is made on this Mac")
        XCTAssertEqual(f.download?.repo, f.variants["BF16"]?.repository)
        let sizes = ["BF16": Int64(67_513_686_219), "8b": 36_502_781_302, "4b": 21_815_377_547]
        for (label, bytes) in sizes {
            let v = try XCTUnwrap(f.variants[label], label)
            XCTAssertFalse(v.isDerived, label)
            XCTAssertEqual(v.downloadBytes, bytes, label)
            XCTAssertEqual(f.downloadSource(of: label)?.label, label, "\(label) downloads itself")
            XCTAssertEqual(f.diskBytes(label), bytes)
            XCTAssertEqual(v.revision.count, 40)
            XCTAssertTrue(v.repository.hasPrefix(NativeModelDownload.unpublishedOwner + "/"), "\(label): placeholder until Toby picks the source")
            let files = try XCTUnwrap(v.files, label)
            for licence in ["LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/Qwen3-ASR-LICENSE.txt", "licenses/vLLM-LICENSE.txt", "README.md", "config.json"] {
                XCTAssertTrue(files.contains(licence), "\(label) keeps \(licence)")
            }
            XCTAssertFalse(files.contains { $0.contains("ctc_timestamp") || $0.hasPrefix("llm_backbone/") }, "\(label): unused files stay upstream")
            let prompt = try XCTUnwrap(downloadPrompt(family: f, precision: label, followUp: .load, freeBytes: 1_000_000_000_000))
            XCTAssertEqual(prompt.variantID, v.id); XCTAssertEqual(prompt.downloadBytes, bytes)
        }
        XCTAssertEqual(f.variants["BF16"]?.files?.filter { $0.hasSuffix(".safetensors") }, ["model.safetensors"])
        XCTAssertEqual(f.variants["8b"]?.files?.filter { $0.hasPrefix("model-") }.count, 8)
        XCTAssertEqual(f.variants["4b"]?.files?.filter { $0.hasPrefix("model-") }.count, 5)
        XCTAssertTrue(f.variants["8b"]?.files?.contains("extras/mtp.safetensors") == true)
        // The downloader's records carry the file lists, so Get fetches and verifies exactly these.
        let records = catalogVariants(ModelCatalog(families: [f]))
        XCTAssertEqual(Set(records.map(\.id)), Set(f.variants.values.map(\.id)))
        XCTAssertTrue(records.allSatisfy { $0.files != nil })
        XCTAssertEqual(records.first { $0.id == f.variants["4b"]?.id }?.quantization, "4-bit")
    }

    /// The fit rule (peak + 16 GB within the Mac's memory, rounded up to a size Macs ship with) gives 96 / 64 / 48 GB.
    func testMemoryFloorsPerTier() throws {
        let f = try family()
        XCTAssertEqual(minimumMemoryGB(f, "BF16"), 96)
        XCTAssertEqual(minimumMemoryGB(f, "8b"), 64)
        XCTAssertEqual(minimumMemoryGB(f, "4b"), 48)
        XCTAssertEqual(f.variants["4b"]?.peakMemoryEstimated, nil, "int4's 24.7 GB peak is measured")
        XCTAssertEqual(f.variants["8b"]?.peakMemoryEstimated, true)
        XCTAssertEqual(f.variants["BF16"]?.peakMemoryEstimated, true)
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
        XCTAssertEqual(estimatedMemory(family: f, precision: "4b", benchmarks: empty), MemoryEstimate(mb: 24_700, measured: true, note: nil))
        XCTAssertEqual(estimatedMemory(family: f, precision: "BF16", benchmarks: empty)?.mb, 70_000)
        XCTAssertEqual(estimatedMemory(family: f, precision: "BF16", benchmarks: empty)?.measured, false)
        XCTAssertEqual(catalogPeakMemoryText(f.variants["4b"]), "24.7 GB")
        XCTAssertEqual(catalogPeakMemoryText(f.variants["8b"]), "~40 GB")
        XCTAssertEqual(catalogPeakMemoryText(f.variants["BF16"]), "~70 GB")
        XCTAssertTrue(catalogPeakMemoryHelp(f.variants["BF16"]!).contains("Estimated, not measured"))
        XCTAssertTrue(catalogPeakMemoryHelp(f.variants["4b"]!).contains("Measured on M5 Max"))
    }

    func testTooltipsNameTheMixAndTheLicence() throws {
        let f = try family()
        let help = modelHelp(f)
        XCTAssertTrue(help.contains("NVIDIA, 2026 \u{00b7} OpenMDW-1.1"), help)
        XCTAssertTrue(help.contains("30B-A4B parameters"), help)
        XCTAssertTrue(tierCellHelp(f, nil, tier: .t4, mode: .fast).hasPrefix("4-bit routed experts, 8-bit shared experts"), tierCellHelp(f, nil, tier: .t4, mode: .fast))
        XCTAssertTrue(tierCellHelp(f, nil, tier: .t8, mode: .fast).hasPrefix("8-bit experts"))
        XCTAssertEqual(tierFlavour(f, tier: .t16, cell: nil), "bf16, as published")
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
    private static let mixedConfig: [String: Any] = [
        "model_type": "nemotron_transcribe",
        "quantization": ["bits": 4, "group_size": 64, "llm.layers.0.mixer.switch_mlp.fc1": ["bits": 8, "group_size": 64]]
    ]
    private func record(files: [String], bytes: Int64, quantization: String = "8-bit", repository: String = "UNPUBLISHED/NT-fixture") -> ModelRecommendation {
        ModelRecommendation(
            id: "nt-fixture", name: "Nemotron 3.5 Transcribe", quantization: quantization, repository: repository,
            revision: String(repeating: "0", count: 40), downloadBytes: bytes, architecture: "nemotron_transcribe", license: "openmdw-1.1",
            recommendation: "", files: files)
    }

    /// A local source (VELLA_TEST_MODEL_SOURCE_DIR) stands in for the Hub: the listed files, nothing else, all present.
    func testLocalSourceGetCopiesTheListedFilesAndVerifiesThem() async throws {
        let files = ["model-00001-of-00001.safetensors": "weights", "LICENSE": "OpenMDW", "THIRD_PARTY_NOTICES.md": "notices",
            "licenses/vLLM-LICENSE.txt": "apache", "extras/ctc_timestamp.safetensors": "unused"]
        let sources = try fixtureFolder([:], config: [:])
        let source = sources.appendingPathComponent("NT-fixture")
        for (name, body) in files {
            let url = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        let configData = try JSONSerialization.data(withJSONObject: Self.mixedConfig)
        try configData.write(to: source.appendingPathComponent("config.json"))
        let listed = ["config.json", "model-00001-of-00001.safetensors", "LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/vLLM-LICENSE.txt"]
        let bytes = Int64(configData.count + "weights".utf8.count + "OpenMDW".utf8.count + "notices".utf8.count + "apache".utf8.count)
        let models = sources.appendingPathComponent("Models")
        let catalogURL = Repository.root.appendingPathComponent("Resources/models.json")
        let client = NativeModelDownload(catalogURL: catalogURL, localSources: sources) { _, _, _ in }
        let folder = try await client.download(record(files: listed, bytes: bytes), modelsDirectory: models)
        for name in listed { XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("extras/ctc_timestamp.safetensors").path))
        // A wrong total (another build in the source folder) is refused.
        do {
            _ = try await client.download(record(files: listed, bytes: bytes + 1), modelsDirectory: models)
            XCTFail("a size mismatch must fail")
        } catch {}
        // Without a local source, the placeholder downloads nothing and says why; another Get cannot help.
        let none = NativeModelDownload(catalogURL: catalogURL, localSources: nil) { _, _, _ in }
        do {
            _ = try await none.download(record(files: listed, bytes: bytes), modelsDirectory: models)
            XCTFail("an unpublished source must not download")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Nemotron 3.5 Transcribe is not published for download yet. Update Vella when it is")
            XCTAssertFalse(NativeModelDownload.isRetryable(error))
        }
    }

    func testValidationRequiresTheLicenceFilesAndAcceptsTheMixAndNvidiasLayout() throws {
        let listed = ["config.json", "model.safetensors", "LICENSE", "THIRD_PARTY_NOTICES.md"]
        let mixed = try fixtureFolder(["model.safetensors": "w", "LICENSE": "l", "THIRD_PARTY_NOTICES.md": "n"], config: Self.mixedConfig)
        XCTAssertNoThrow(try NativeModelDownload.validate(mixed, expected: record(files: listed, bytes: 0, quantization: "8-bit")))
        XCTAssertNoThrow(try NativeModelDownload.validate(mixed, expected: record(files: listed, bytes: 0, quantization: "4-bit")))
        XCTAssertThrowsError(try NativeModelDownload.validate(mixed, expected: record(files: listed, bytes: 0, quantization: "BF16")))
        try FileManager.default.removeItem(at: mixed.appendingPathComponent("LICENSE"))
        XCTAssertThrowsError(try NativeModelDownload.validate(mixed, expected: record(files: listed, bytes: 0))) {
            XCTAssertEqual($0.localizedDescription, "The model folder is missing LICENSE")
        }
        let nvidia = try fixtureFolder(
            ["model.safetensors": "w", "LICENSE": "l", "THIRD_PARTY_NOTICES.md": "n"],
            config: ["model_type": "nemo_speechlm", "architectures": ["Nemotron3_5TranscribeForConditionalGeneration"]])
        XCTAssertNoThrow(try NativeModelDownload.validate(nvidia, expected: record(files: listed, bytes: 0, quantization: "BF16")))
    }

    /// Where Toby's local builds exist, every listed file is there and they add up to the catalog's download size (file
    /// sizes only; nothing is read or loaded).
    func testLocalBuildsMatchTheCatalog() throws {
        let f = try family()
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models")
        var checked = 0
        for (label, v) in f.variants {
            let folder = home.appendingPathComponent(String(v.repository.split(separator: "/").last ?? ""))
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) else { continue }
            let sizes = try (v.files ?? []).map { name -> Int64 in
                let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return (attributes[.size] as? NSNumber)?.int64Value ?? -1
            }
            XCTAssertEqual(sizes.reduce(0, +), v.downloadBytes, label)
            checked += 1
        }
        try XCTSkipIf(checked == 0, "no local Nemotron 3.5 Transcribe builds on this Mac")
    }
}
