import XCTest
import VellaWire
@testable import VellaCore

final class CellPresenceTests: XCTestCase {
    func testUngatedStatusIsNotDecodedAsFailure() throws {
        let gate = try JSONDecoder().decode(
            SegmentGate.self, from: Data(#"{"status":"not_gated","presence":{"offered":false},"reasons":["not gated (no same-layout baseline)"]}"#.utf8))
        XCTAssertEqual(gate.status, .notGated)
        XCTAssertEqual(gate.presence?.offered, false)
    }
    func testCellPresenceOverridesTierAndDoesNotUseRecommendationVerdict() {
        var cell = BenchmarkCell(recipe: CellRecipe(layers: [:]))
        var tier = TierBenchmark(precision: "BF16", cells: [.standard: cell])
        func offered() -> Bool { cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .standard) }
        XCTAssertTrue(offered(), "a cell without a gate inherits its tier")
        cell.gate = SegmentGate(status: .pass, presence: TierPresence(offered: false, reasons: ["lost words"]))
        tier.cells[.standard] = cell
        XCTAssertFalse(offered(), "an offered tier cannot override a rejected cell")
        tier.presence.offered = false
        cell.gate = SegmentGate(status: .fail, presence: TierPresence(offered: true))
        tier.cells[.standard] = cell
        XCTAssertTrue(offered(), "recommendation failure is not absence; the cell verdict owns presence")
        cell.gate = SegmentGate(status: .pass)
        tier.cells[.standard] = cell
        XCTAssertFalse(offered(), "a gate without presence fails closed")
        cell.gate = nil
        tier.cells[.standard] = cell
        XCTAssertFalse(offered(), "only a gate-less cell inherits tier absence")
        XCTAssertFalse(cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .optimized_fast))
        XCTAssertTrue(cellPresent(nil, tier: .t16, segment: .standard))
    }

    func testSuppliedMalformedGateFailsClosedWhileAbsentGateKeepsTierFallback() throws {
        for rawGate in ["\"bad\"", "[]", "null", "73", "true", "{\"status\":\"pass\"}", "{\"presence\":{\"offered\":\"yes\"}}"] {
            let raw = try JSONSerialization.jsonObject(
                with: Data(
                    """
                    {"precision":"BF16","presence":{"offered":true},
                     "standard":{"gate":\(rawGate),"measured":{"suite":"fixture"}}}
                    """.utf8))
            let tier = try XCTUnwrap(decodeTier(raw))
            XCTAssertNotNil(tier.cells[.standard]?.gate, rawGate)
            XCTAssertFalse(cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .standard), rawGate)
        }
        for offered in [true, false] {
            let absent: [String: Any] = ["precision": "BF16", "presence": ["offered": offered], "standard": [:] as [String: Any]]
            let tier = try XCTUnwrap(decodeTier(absent))
            XCTAssertNil(tier.cells[.standard]?.gate)
            XCTAssertEqual(cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .standard), offered)
            var gated = absent
            gated["standard"] = ["gate": ["status": "fail", "presence": ["offered": !offered]]] as [String: Any]
            let valid = try XCTUnwrap(decodeTier(gated))
            XCTAssertEqual(cellPresent(FamilyBenchmark(tiers: [.t16: valid]), tier: .t16, segment: .standard), !offered)
        }
    }

    func testCorrectedNemotronKeepsEveryNativeAndInt8CellAndRejectsInt4() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let family = try XCTUnwrap(catalog.family("nemotron-3.5-streaming-0.6b"))
        let benchmark = decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json"))).models[family.id]
        let rules = SelectionRules(family: family, benchmark: benchmark)
        XCTAssertTrue(rules.hasOptimizedPath)
        XCTAssertTrue(rules.switchAvailable)
        for tier in ModelTier.allCases {
            for recipe in Recipe.allCases {
                let selection = ModelSelection(tier: tier, path: recipe == .standard ? .standard : .optimized, mode: recipe == .optimized_exact ? .exact : .fast)
                XCTAssertEqual(cellPresent(benchmark, tier: tier, segment: recipe), tier != .t4)
                XCTAssertEqual(rules.isPresent(selection), tier != .t4)
                XCTAssertTrue(rules.measured(selection))
                if tier != .t4 {
                    XCTAssertEqual(rules.valid(selection), selection)
                    XCTAssertNil(rules.cellRefusal(selection))
                } else {
                    XCTAssertNotNil(rules.cellRefusal(selection))
                    XCTAssertNotEqual(rules.valid(selection).tier, .t4)
                }
            }
        }
        XCTAssertEqual(benchmark?.tiers[.t8]?.gate.status, .fail, "int8 is offered, not recommended")
        let saved = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        XCTAssertEqual(rules.runnable(recorded: saved, precision: "8b", available: { $0 == "8b" }), saved)
    }

    func testCorrectedCatalogRetainsEveryPreviouslyOfferedCell() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let file = decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json")))
        let offered: [String: [ModelTier]] = [
            "parakeet-v3": [.t16, .t8], "parakeet-v3-ultra": [.t16, .t8, .t4], "qwen3-asr-1.7b": [.t16], "qwen3-asr-0.6b": [.t16, .t8],
            "nemotron-3.5-streaming-0.6b": [.t16, .t8], "whisper-large-v3": [.t16, .t8], "whisper-large-v3-turbo": [.t16, .t8]
        ]
        XCTAssertEqual(Set(offered.keys), Set(catalog.families.map(\.id)))
        var checked = 0
        for family in catalog.families {
            let benchmark = try XCTUnwrap(file.models[family.id])
            let rules = SelectionRules(family: family, benchmark: benchmark)
            for tier in ModelTier.allCases {
                for recipe in Recipe.allCases {
                    let expected = offered[family.id]!.contains(tier)
                    let selection = ModelSelection(tier: tier, path: recipe == .standard ? .standard : .optimized, mode: recipe == .optimized_exact ? .exact : .fast)
                    XCTAssertEqual(cellPresent(benchmark, tier: tier, segment: recipe), expected, "\(family.id) \(tier) \(recipe)")
                    XCTAssertEqual(rules.isPresent(selection), expected, "\(family.id) \(tier) \(recipe)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 63)
    }
}
