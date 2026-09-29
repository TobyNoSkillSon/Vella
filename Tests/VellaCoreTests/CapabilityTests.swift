import XCTest
@testable import VellaCore

/// The Models table's Capabilities slots, derived from models.json only.
final class CapabilityTests: XCTestCase {
    private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources")

    func testSlotsOfTheShippedCatalogArePinned() throws {
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let offered = catalog.families.filter(\.offered)
        func slots(_ id: String) -> [String] {
            let s = capabilitySlots(catalog.family(id)!)
            return Capability.allCases.compactMap { s[$0].map { "\($0.symbol): \($0.help)" } }
        }
        XCTAssertEqual(slots("parakeet-v3-ultra"), ["globe.europe.africa: 25 European languages"])
        XCTAssertEqual(slots("parakeet-v3"), ["globe.europe.africa: 25 European languages"])
        XCTAssertEqual(slots("qwen3-asr-1.7b"), ["globe: 30 languages", "character.textbox.zh: Chinese (with Cantonese), Japanese and Korean"])
        XCTAssertEqual(slots("whisper-large-v3"), ["globe: 100 languages", "character.textbox.zh: Chinese (with Cantonese), Japanese and Korean"])
        XCTAssertEqual(slots("nemotron-3.5-streaming-0.6b"), ["globe: 28 languages", "character.textbox.zh: Chinese, Japanese and Korean"])
        XCTAssertEqual(filterableCapabilities(offered), [.cjk], "every model is multilingual; only CJK tells them apart")
        XCTAssertEqual(offered.filter { hasCapabilities($0, [.cjk]) }.count, offered.count - 2)
        XCTAssertTrue(offered.allSatisfy { hasCapabilities($0, []) })
    }

    func testAnEnglishOnlyModelHasEmptySlots() {
        let f = ModelFamily(id: "x", name: "X", mode: .dictation, languages: ["en"], params: "", license: "mit", native: "BF16", variants: [:])
        XCTAssertTrue(capabilitySlots(f).isEmpty)
        XCTAssertFalse(hasCapabilities(f, [.languages]))
    }
}
