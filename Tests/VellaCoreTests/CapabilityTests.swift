import XCTest
@testable import VellaCore
import VellaTestSupport

/// The Models table's Capabilities slots, derived from models.json only.
final class CapabilityTests: XCTestCase {
    private let resources = Repository.root.appendingPathComponent("Resources")

    func testSlotsOfTheShippedCatalogArePinned() throws {
        let catalog = try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json")))
        let offered = catalog.families.filter(\.offered)
        func slots(_ id: String) -> [String] {
            let s = capabilitySlots(catalog.family(id)!)
            return Capability.allCases.compactMap { s[$0].map { "\($0.symbol): \($0.help)" } }
        }
        // One globe for every multilingual model, its count in the text; no separate Chinese-Japanese-Korean icon
        // (Toby, 30 Sep). Streaming only where the catalog says so (mode); timestamps and translation are not in it.
        XCTAssertEqual(slots("parakeet-v3-ultra"), ["globe: 25 European languages"])
        XCTAssertEqual(slots("parakeet-v3"), ["globe: 25 European languages"])
        XCTAssertEqual(slots("qwen3-asr-1.7b"), ["globe: 30 languages"])
        XCTAssertEqual(slots("whisper-large-v3"), ["globe: 100 languages"])
        XCTAssertEqual(slots("nemotron-3.5-streaming-0.6b"), ["globe: 28 languages", "waveform: Streams: types the text while you speak"])
        XCTAssertEqual(Capability.allCases, [.languages, .streaming])
        XCTAssertEqual(filterableCapabilities(offered), [], "every model is multilingual, and Streaming is already a section: nothing to filter")
        XCTAssertEqual(offered.filter { hasCapabilities($0, [.streaming]) }.map(\.id), ["nemotron-3.5-streaming-0.6b"])
        XCTAssertTrue(offered.allSatisfy { hasCapabilities($0, []) })
    }

    func testAnEnglishOnlyModelHasEmptySlots() {
        let f = ModelFamily(id: "x", name: "X", mode: .dictation, languages: ["en"], params: "", license: "mit", native: "BF16", variants: [:])
        XCTAssertTrue(capabilitySlots(f).isEmpty)
        XCTAssertFalse(hasCapabilities(f, [.languages]))
    }
}
