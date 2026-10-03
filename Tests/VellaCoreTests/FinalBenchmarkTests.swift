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

    /// Toby withdrew the whisper.cpp comparison (3 Oct 2026): published comparisons are Vella against stock MLX plus the cloud
    /// reference rows. No competitor name or competitor_comparisons key may ship in the app resources, the Pages site or the docs.
    func testNoCompetitorComparisonShips() throws {
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json"))) as? [String: Any])
        XCTAssertNil(raw["competitor_comparisons"])
        XCTAssertNotNil(raw["references"], "the cloud reference rows stay")
        let tokens = ["whisper.cpp", "whispercpp", "whisper-cpp", "wcpp", "macwhisper", "buzz", "competitor_comparisons"]
        var files = ["README.md", "CHANGELOG.md", "docs/USAGE.md"]
        for folder in ["Resources", "docs"] {
            let base = Repository.root.appendingPathComponent(folder)
            for relative in FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? [] {
                if ["json", "md", "js", "html", "plist"].contains((relative as NSString).pathExtension) { files.append(folder + "/" + relative) }
            }
        }
        XCTAssertTrue(files.contains("Resources/benchmarks.json") && files.contains("docs/data.js") && files.contains("Resources/AGENT_GUIDE.md"))
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
        for relative in ["Resources/benchmarks.json", "Resources/models.json", "Resources/SKILL.md", "README.md", "CHANGELOG.md", "docs/data.js"] {
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
        for (relative, planted) in [("README.md", "whisper.cpp Metal CLI"), ("Resources/AGENT_GUIDE.md", "compared with MacWhisper"), ("docs/data.js", "\"competitor_comparisons\": {}")] {
            let url = fixture.appendingPathComponent(relative)
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
        XCTAssertEqual(builds["measured"]?["commit"] as? String, "55cb080")
        XCTAssertEqual(builds["shipped"]?["worker_source_commit"] as? String, "08203e24ebdf83004ca4d81daa03f678880898c2")
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
        for relative in ["Resources/benchmarks.json", "Resources/models.json", "Resources/SKILL.md", "README.md", "CHANGELOG.md", "docs/data.js"] {
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

    func testWhisperTierAndWithdrawnCellProvenance() throws {
        let data = try Data(contentsOf: Repository.root.appendingPathComponent("Resources/benchmarks.json"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(raw["models"] as? [String: [String: Any]])
        for id in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            let tiers = try XCTUnwrap(models[id]?["tiers"] as? [String: [String: Any]])
            for tier in tiers.values {
                XCTAssertEqual((tier["gate"] as? [String: Any])?["baseline"] as? String, "tier16 Optimized Fast (measured)")
                XCTAssertEqual((tier["presence"] as? [String: Any])?["baseline"] as? String, "tier16 Optimized Fast (measured)")
                for path in ["standard", "optimized_exact"] {
                    let cell = try XCTUnwrap(tier[path] as? [String: Any])
                    XCTAssertEqual((cell["gate"] as? [String: Any])?["status"] as? String, "withdrawn")
                    for (key, value) in cell where !["recipe", "gate", "build_provenance", "not_measured_reason"].contains(key) {
                        XCTAssertTrue(value is NSNull, "withdrawn figure \(key) retained: \(value)")
                    }
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
                for recipe in [Recipe.standard, .optimized_exact] {
                    let cell = try XCTUnwrap(entry.cells[recipe])
                    XCTAssertTrue(cell.isPending)
                    XCTAssertNotNil(cell.notMeasuredReason)
                    XCTAssertNil(cell.result.wer); XCTAssertNil(cell.result.format); XCTAssertNil(cell.result.multilingual)
                    XCTAssertNil(cell.result.speed_x); XCTAssertNil(cell.result.j_per_min); XCTAssertNil(cell.result.memory_mb)
                    XCTAssertNil(cell.result.disk_mb); XCTAssertNil(cell.result.latency_ms)
                    XCTAssertTrue(tierDeltaLine(cell, base: nil, isBase: false).hasPrefix("Not measured yet: "))
                }
                let fast = ModelSelection(tier: tier, path: .optimized, mode: .fast)
                XCTAssertTrue(rules.measured(fast), "Fast must not resolve to the withdrawn Exact measurement")
                let fastCell = try XCTUnwrap(benchmarkCell(benchmark, fast))
                XCTAssertEqual(fastCell.recipe.gate_revision, "whisper-4")
                XCTAssertFalse(fastCell.recipe.kernels.contains("encoder")); XCTAssertTrue(fastCell.recipe.inexact.isEmpty)
                if entry.presence.offered {
                    let standard = ModelSelection(tier: tier, path: .standard, mode: .fast)
                    let exact = ModelSelection(tier: tier, path: .optimized, mode: .exact)
                    XCTAssertTrue(rules.cellRefusal(standard)?.hasPrefix("Not measured yet: Standard") == true)
                    XCTAssertTrue(rules.cellRefusal(exact)?.hasPrefix("Not measured yet: Exact") == true)
                    XCTAssertNil(rules.cellRefusal(standard, loaded: standard), "Loaded Standard remains selectable")
                    XCTAssertNil(rules.cellRefusal(fast))
                    XCTAssertEqual(rules.valid(standard), fast)
                    XCTAssertEqual(rules.valid(exact), fast)
                    XCTAssertFalse(tierCellHelp(family, benchmark, tier: tier, segment: .optimized_fast).contains("vs Standard fp16:"))
                }
            }
        }
    }
}
