import XCTest
import VellaTestSupport
import VellaWire
@testable import VellaCore

final class FinalBenchmarkTests: XCTestCase {
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
