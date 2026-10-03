import XCTest
@testable import VellaCore

final class CellPresenceTests: XCTestCase {
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

    func testBundledNemotronRejectedSelectionResolvesToStandard16() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let family = try XCTUnwrap(catalog.family("nemotron-3.5-streaming-0.6b"))
        let benchmark = decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json"))).models[family.id]
        let rules = SelectionRules(family: family, benchmark: benchmark)
        let saved = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        XCTAssertFalse(rules.isPresent(saved))
        XCTAssertFalse(rules.hasOptimizedPath)
        XCTAssertFalse(rules.switchAvailable)
        XCTAssertEqual(rules.valid(saved), ModelSelection(tier: .t16, path: .standard, mode: .fast))
        XCTAssertEqual(rules.runnable(recorded: saved, precision: "8b", available: { $0 == "8b" }), rules.valid(saved))
        XCTAssertNotNil(rules.cellRefusal(saved))
    }
}
