import XCTest
import VellaTestSupport
import VellaWire
@testable import VellaCore

final class FinalBenchmarkTests: XCTestCase {
    func testCanonicalFastFiguresAndInexactClassification() throws {
        let file = decodeBenchmarks(try Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json")))
        let ultra = try XCTUnwrap(file.models["parakeet-v3-ultra"])
        let fast = try XCTUnwrap(benchmarkCell(ultra, ModelSelection(tier: .t8, path: .optimized, mode: .fast)))
        XCTAssertEqual(fast.result.speed_x ?? 0, 515.0, accuracy: 0.1)
        XCTAssertTrue(fast.recipe.inexact.contains("int8_gemm"))
        for (id, family) in file.models {
            for tier in family.tiers.values {
                XCTAssertTrue(tier.cells[.optimized_exact]?.recipe.inexact.isEmpty ?? true, id)
                XCTAssertFalse(tier.cells[.optimized_exact]?.recipe.kernels.contains("joint_batch") ?? false, id)
                if tier.cells[.optimized_fast]?.recipe.inexact.isEmpty == true, tier.cells[.optimized_exact]?.isPending == false {
                    XCTAssertEqual(tier.displayCells[.optimized_fast], .optimized_exact, id)
                }
            }
        }
        let qwen = try XCTUnwrap(file.models["qwen3-asr-1.7b"])
        XCTAssertEqual(benchmarkCell(qwen, ModelSelection(tier: .t16, path: .optimized, mode: .fast)), qwen.tiers[.t16]?.cells[.optimized_exact])
    }

    /// Withdrawn third-party comparison: published comparisons are Vella against stock MLX plus the cloud
    /// reference rows. No competitor name or competitor_comparisons key may ship in the app resources or the docs.
    func testNoCompetitorComparisonShips() throws {
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json"))) as? [String: Any])
        XCTAssertNil(raw["competitor_comparisons"])
        XCTAssertNotNil(raw["references"], "the cloud reference rows stay")
        let tokens = ["whisper.cpp", "whispercpp", "whisper-cpp", "wcpp", "macwhisper", "buzz", "competitor_comparisons"]
        var files = ["README.md", "CHANGELOG.md", "docs/USAGE.md"]
        for folder in ["Resources", "docs"] {
            let base = Repository.root.appendingPathComponent(folder)
            let found = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
            files += found.filter { ["json", "md", "js", "html", "plist", "sh"].contains(($0 as NSString).pathExtension) }.map { folder + "/" + $0 }
        }
        XCTAssertTrue(files.contains("Resources/benchmarks.json") && files.contains("docs/BENCHMARKS.md") && files.contains("Resources/AGENT_GUIDE.md"))
        for relative in Set(files) {
            let text = try String(contentsOf: Repository.root.appendingPathComponent(relative), encoding: .utf8).lowercased()
            for token in tokens { XCTAssertFalse(text.contains(token), "\(relative) mentions the withdrawn comparison: \(token)") }
        }
    }

    func testPublicDataGuardRefusesAPlantedCompetitorMention() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("vella-competitor-guard-\(UUID())")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for relative in ["Resources/benchmarks.json", "Resources/models.json", "Resources/SKILL.md", "README.md", "CHANGELOG.md"] {
            try Data("portable fixture".utf8).write(to: fixture.appendingPathComponent(relative))
        }
        func run() throws -> (Int32, String) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swift", Repository.root.appendingPathComponent("scripts/public-data-guard.swift").path, fixture.path]
            process.currentDirectoryURL = Repository.root
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }
        XCTAssertEqual(try run().0, 0)
        let plants = [
            ("README.md", "whisper.cpp synthetic fixture"),
            ("SECURITY.md", "whisper_cpp"), ("CONTRIBUTING.md", "Whisper cpp"),
            ("AGENTS.md", "ggml-fixture"), ("THIRD_PARTY_NOTICES.md", "whisper.cpp"),
            (".github/ISSUE_TEMPLATE/test.md", "whisper.cpp"),
            ("Sources/Test.swift", "let name = \"whisper_cpp\""),
            ("Worker/Sources/MLXAudioSTT/Whisper/README.md", "Whisper cpp"),
            ("Resources/AGENT_GUIDE.md", "compared with MacWhisper"),
            ("docs/BENCHMARKS.md", "\"competitor_comparisons\": {}")
        ]
        for (relative, planted) in plants {
            let url = fixture.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try? Data(contentsOf: url)
            try Data(planted.utf8).write(to: url)
            let (status, text) = try run()
            XCTAssertNotEqual(status, 0, "guard accepted a planted mention in \(relative)")
            XCTAssertTrue(text.contains("withdrawn competitor comparison"), text)
            if let original { try original.write(to: url) } else { try FileManager.default.removeItem(at: url) }
        }
    }

    func testReasonDecodesAndDefaultsForOldAndMalformedData() throws {
        for (field, expected) in [(#", "not_measured_reason":"Standard changed""#, "Standard changed"), ("", nil), (#", "not_measured_reason":42"#, nil)] {
            let data = Data(
                "{\"schema\":2,\"models\":{\"demo\":{\"tiers\":{\"16\":{\"precision\":\"FP16\",\"standard\":{\"recipe\":{\"layers\":{}}\(field)}}}}},\"references\":{}}".utf8)
            let cell = try XCTUnwrap(decodeBenchmarks(data).models["demo"]?.tiers[.t16]?.cells[.standard])
            XCTAssertEqual(cell.notMeasuredReason, expected)
            XCTAssertEqual(unmeasuredReasonHelp(cell), expected.map { "Not measured yet: " + $0 } ?? "Not measured yet")
        }
        XCTAssertEqual(unmeasuredReasonHelp(nil), "Not measured yet")
    }

    func testShippedWorkerSourceGuardMatchesAndBuildBridgeIsExplicit() throws {
        let data = try Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let builds = try XCTUnwrap(raw["builds"] as? [String: [String: Any]])
        XCTAssertEqual(builds["measured"]?["commit"] as? String, "deb8845")
        XCTAssertEqual(builds["shipped"]?["worker_source_commit"] as? String, "9aad75cbac72dbc650669fe227fc273414db6c63")
        for field in ["summary", "defaults"] {
            let claim = try XCTUnwrap(builds["bridge"]?[field] as? String)
            XCTAssertTrue(claim.hasPrefix("Historical, before GPU-identity keys:"), field)
        }
        let defaults = try XCTUnwrap(builds["bridge"]?["defaults"] as? String)
        XCTAssertTrue(defaults.contains("current default and explicit measured lever configurations still agree"))
        XCTAssertTrue(defaults.contains("current keys differ from historical verdict keys and require local requalification"))
        let bridge = try XCTUnwrap(builds["bridge"]?["whisper_fast_token_identity"] as? [String: Any])
        XCTAssertEqual(bridge["status"] as? String, "pass")
        XCTAssertEqual(bridge["cells"] as? Int, 6)
        XCTAssertEqual(bridge["token_identical_per_cell"] as? Int, 122)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Repository.root.appendingPathComponent("scripts/worker-source-identity.sh").path]
        process.currentDirectoryURL = Repository.root
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
    }

    func testPublicDataGuardAndItsCounterexamples() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("vella-public-guard-\(UUID())")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for relative in ["Resources/benchmarks.json", "Resources/models.json", "Resources/SKILL.md", "README.md", "CHANGELOG.md"] {
            try Data("portable fixture".utf8).write(to: fixture.appendingPathComponent(relative))
        }
        for argument in [Repository.root.path, "--selftest", fixture.path] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swift", Repository.root.appendingPathComponent("scripts/public-data-guard.swift").path, argument]
            process.currentDirectoryURL = Repository.root
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, text)
        }
        let data = try Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let builds = try XCTUnwrap(raw["builds"] as? [String: [String: Any]])
        XCTAssertEqual(builds["measured"]?["env_map_sha256"] as? String, "f6b6918a5ede08b3dffa45f4540bc9c9c488f566da8ef63fd7860e0aa8723242")
        func check(_ value: Any) {
            if let object = value as? [String: Any] {
                XCTAssertNil(object["identity"], "full machine identities are local evidence")
                XCTAssertNil(object["_raw"], "raw run paths are local evidence")
                for child in object.values { check(child) }
            } else if let children = value as? [Any] {
                for child in children { check(child) }
            }
        }
        check(raw)
    }

    func testWhisperTierAndFaithfulCellProvenance() throws {
        let data = try Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(raw["models"] as? [String: [String: Any]])
        for id in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            let tiers = try XCTUnwrap(models[id]?["tiers"] as? [String: [String: Any]])
            for tier in tiers.values {
                XCTAssertEqual((tier["gate"] as? [String: Any])?["baseline"] as? String, "tier16 Standard fp16 on same faithful build")
                XCTAssertEqual((tier["presence"] as? [String: Any])?["baseline"] as? String, "tier16 Standard fp16 on same faithful build")
                for path in ["standard", "optimized_exact", "optimized_fast"] {
                    let cell = try XCTUnwrap(tier[path] as? [String: Any])
                    let gate = try XCTUnwrap(cell["gate"] as? [String: Any])
                    XCTAssertEqual(gate["baseline"] as? String, "tier16 Standard fp16 on same faithful build")
                    XCTAssertNotNil(cell["measured"] as? [String: Any])
                    XCTAssertNotNil(gate["presence"] as? [String: Any])
                }
            }
        }
    }

    func testFinalWhisperCellsAndSelectionConsequences() throws {
        let resources = Repository.root.appendingPathComponent("Resources")
        let data = try Data(contentsOf: resources.appendingPathComponent("benchmarks.json"))
        let file = decodeBenchmarks(data)
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        XCTAssertFalse(file.figuresPending)
        for id in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            let family = try XCTUnwrap(catalog.family(id))
            let benchmark = try XCTUnwrap(file.models[id])
            let rules = SelectionRules(family: family, benchmark: benchmark)
            XCTAssertFalse(rules.switchAvailable, "Whisper Fast and Exact run the same exact recipe")
            for tier in ModelTier.allCases {
                let entry = try XCTUnwrap(benchmark.tiers[tier])
                for recipe in Recipe.allCases {
                    let cell = try XCTUnwrap(entry.cells[recipe])
                    XCTAssertFalse(cell.isPending)
                    XCTAssertNil(cell.notMeasuredReason)
                    XCTAssertNotNil(cell.result.wer); XCTAssertNotNil(cell.result.format); XCTAssertNotNil(cell.result.multilingual)
                    XCTAssertNotNil(cell.result.speed_x); XCTAssertNotNil(cell.result.j_per_min); XCTAssertNotNil(cell.result.memory_mb)
                }
                let fast = ModelSelection(tier: tier, path: .optimized, mode: .fast)
                XCTAssertTrue(rules.measured(fast), "Fast resolves to the faithful canonical Exact measurement")
                let fastCell = try XCTUnwrap(benchmarkCell(benchmark, fast))
                XCTAssertEqual(fastCell.recipe.gate_revision, "whisper-4")
                XCTAssertFalse(fastCell.recipe.kernels.contains("encoder")); XCTAssertTrue(fastCell.recipe.inexact.isEmpty)
                if entry.presence.offered {
                    let standard = ModelSelection(tier: tier, path: .standard, mode: .fast)
                    let exact = ModelSelection(tier: tier, path: .optimized, mode: .exact)
                    XCTAssertTrue(rules.isPresent(standard))
                    XCTAssertTrue(rules.isPresent(exact))
                    XCTAssertNil(rules.cellRefusal(standard))
                    XCTAssertNil(rules.cellRefusal(exact))
                    XCTAssertNil(rules.cellRefusal(standard, loaded: standard))
                    XCTAssertNil(rules.cellRefusal(fast))
                    XCTAssertEqual(rules.valid(standard), standard)
                    XCTAssertEqual(rules.valid(exact), exact)
                    XCTAssertTrue(tierCellHelp(family, benchmark, tier: tier, segment: .optimized_fast).contains("vs Standard fp16:"))
                }
            }
        }
    }
}
