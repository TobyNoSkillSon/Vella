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
    /// Every cell in the file is offered whatever its presence verdict (Toby, 6 Oct: the measured figures let people
    /// judge); only malformed gate data or a missing cell is absent.
    func testEveryCellInTheFileIsOfferedWhateverItsVerdict() {
        var cell = BenchmarkCell(recipe: CellRecipe(layers: [:]))
        var tier = TierBenchmark(precision: "BF16", cells: [.standard: cell])
        func offered() -> Bool { cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .standard) }
        XCTAssertTrue(offered(), "a cell without a gate")
        cell.gate = SegmentGate(status: .fail, presence: TierPresence(offered: false, reasons: ["1 clip empty or cut short where 16 had the words"]))
        tier.cells[.standard] = cell
        XCTAssertTrue(offered(), "a failed presence verdict is stated, not hidden")
        tier.presence.offered = false
        cell.gate = nil
        tier.cells[.standard] = cell
        XCTAssertTrue(offered(), "a failed tier verdict is stated, not hidden")
        cell.gate = SegmentGate(status: .pass)
        tier.cells[.standard] = cell
        XCTAssertFalse(offered(), "a gate without presence is malformed data and fails closed")
        XCTAssertFalse(cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .optimized_fast), "a missing cell")
        XCTAssertTrue(cellPresent(nil, tier: .t16, segment: .standard))
    }

    /// A failed verdict's reasons in the tooltip's words: lost clips first, limits dropped; nothing for a pass.
    func testPresenceLossItemsStateLostClipsFirstInPlainWords() {
        var cell = BenchmarkCell(recipe: CellRecipe(layers: [:]))
        XCTAssertEqual(presenceLossItems(cell), [])
        cell.gate = SegmentGate(
            status: .fail,
            presence: TierPresence(
                offered: false,
                reasons: [
                    "English WER +9.40 pt vs 16 (absent from +5.0)", "21 clips empty or cut short where 16 had the words",
                    "Turkish +42.64 pt vs 16 (presence limit +10.0)"
                ]))
        XCTAssertEqual(
            presenceLossItems(cell),
            ["21 test clips came back empty or cut short", "English WER +9.40 pt", "Turkish +42.64 pt"])
        cell.gate?.presence = TierPresence(offered: false, reasons: ["1 clip empty or cut short where 16 had the words"])
        XCTAssertEqual(presenceLossItems(cell), ["1 test clip came back empty or cut short"])
        cell.gate?.presence = TierPresence(offered: true, reasons: ["1 clip empty or cut short where 16 had the words"])
        XCTAssertEqual(presenceLossItems(cell), [], "a passed verdict states no loss")
    }

    func testSuppliedMalformedGateFailsClosedWhileAbsentOrValidGatesAreOffered() throws {
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
            XCTAssertTrue(cellPresent(FamilyBenchmark(tiers: [.t16: tier]), tier: .t16, segment: .standard))
            var gated = absent
            gated["standard"] = ["gate": ["status": "fail", "presence": ["offered": !offered]]] as [String: Any]
            let valid = try XCTUnwrap(decodeTier(gated))
            XCTAssertTrue(cellPresent(FamilyBenchmark(tiers: [.t16: valid]), tier: .t16, segment: .standard))
        }
    }

    func testNemotronOffersEveryCellAndRecommendsNeitherInt8NorInt4() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let family = try XCTUnwrap(catalog.family("nemotron-3.5-streaming-0.6b"))
        let file = decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json")))
        let benchmark = file.models[family.id]
        let rules = SelectionRules(family: family, benchmark: benchmark)
        XCTAssertTrue(rules.hasOptimizedPath)
        XCTAssertTrue(rules.switchAvailable)
        for tier in ModelTier.allCases {
            for recipe in Recipe.allCases {
                let selection = ModelSelection(tier: tier, path: recipe == .standard ? .standard : .optimized, mode: recipe == .optimized_exact ? .exact : .fast)
                XCTAssertTrue(cellPresent(benchmark, tier: tier, segment: recipe))
                XCTAssertTrue(rules.isPresent(selection))
                XCTAssertTrue(rules.measured(selection))
                XCTAssertEqual(rules.valid(selection), selection)
                XCTAssertNil(rules.cellRefusal(selection))
            }
        }
        XCTAssertEqual(benchmark?.tiers[.t8]?.gate.status, .fail, "int8 is offered, not recommended")
        XCTAssertEqual(benchmark?.tiers[.t4]?.gate.status, .fail, "int4 is offered, not recommended")
        XCTAssertEqual(recommendedPrecision(for: family, in: file), "BF16")
        let saved = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        XCTAssertEqual(rules.runnable(recorded: saved, precision: "8b", available: { $0 == "8b" }), saved)
    }

    /// All 63 model × tier × path cells are offered and measured. The 21 whose presence verdict failed state their loss
    /// (lost clips first) and their tier is never recommended.
    func testShippedCatalogOffersEveryMeasuredCell() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let file = decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json")))
        var checked = 0, warned = 0
        for family in catalog.families {
            let benchmark = try XCTUnwrap(file.models[family.id])
            let rules = SelectionRules(family: family, benchmark: benchmark)
            for tier in ModelTier.allCases {
                for recipe in Recipe.allCases {
                    let selection = ModelSelection(tier: tier, path: recipe == .standard ? .standard : .optimized, mode: recipe == .optimized_exact ? .exact : .fast)
                    XCTAssertTrue(cellPresent(benchmark, tier: tier, segment: recipe), "\(family.id) \(tier) \(recipe)")
                    XCTAssertTrue(rules.isPresent(selection), "\(family.id) \(tier) \(recipe)")
                    XCTAssertTrue(rules.measured(selection), "\(family.id) \(tier) \(recipe)")
                    let cell = benchmark.tiers[tier]?.cells[recipe]
                    if cell?.gate?.presence?.offered == false {
                        warned += 1
                        let items = presenceLossItems(cell)
                        XCTAssertFalse(items.isEmpty, "\(family.id) \(tier) \(recipe)")
                        XCTAssertTrue(items[0].contains("test clip"), "lost clips lead: \(items)")
                        XCTAssertFalse(items.contains { $0.contains("limit") || $0.contains("absent from") }, "\(items)")
                        XCTAssertNotEqual(benchmark.tiers[tier]?.gate.status, .pass, "\(family.id) \(tier) is never recommended")
                        XCTAssertNotEqual(recommendedPrecision(for: family, in: file), precisionLabel(family, tier: tier))
                    }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 63)
        XCTAssertEqual(warned, 21)
    }
}
