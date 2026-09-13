import XCTest
import Foundation
import AppKit
@testable import Vella
@testable import VellaCore
final class ModelsTests: XCTestCase {
    @MainActor func testCatalogAndReferenceResultsLoad() {
        let library = ModelLibrary()
        XCTAssertGreaterThanOrEqual(library.models.count, 4)
        XCTAssertNotNil(library.references["Qwen3-ASR-1.7B-bf16"])
        XCTAssertNil(library.references["unmeasured-model-does-not-exist"])
        XCTAssertEqual(library.references["Qwen3-ASR-1.7B-bf16"]?.clips.count, 144)
    }
    @MainActor func testCalibrationRejectsExtrapolation() throws {
        let result = try XCTUnwrap(ModelLibrary().references["Qwen3-ASR-1.7B-bf16"])
        XCTAssertNotNil(result.estimatedSeconds(for: 10))
        XCTAssertNil(result.estimatedSeconds(for: 300))
        XCTAssertNil(result.estimatedSeconds(for: 0))
    }
    @MainActor func testSavedRecordingsIsOneFolderActionWithoutHistorySubmenu() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.rebuildMenu()
        let entries = delegate.menu.items.filter { $0.title.hasPrefix("Open Saved Recordings") || $0.title.hasPrefix("Saved Recordings") }
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "Open Saved Recordings")
        XCTAssertNil(entry.submenu)
        XCTAssertEqual(entry.action.map(NSStringFromSelector), "savedRecordings")
        XCTAssertTrue(entry.isEnabled)
    }
    @MainActor func testModelsOpensOneTableWithoutNestedMenus() {
        _ = NSApplication.shared
        let menus = ModelsMenu()
        let root = menus.modelItem()
        XCTAssertEqual(root.submenu?.items.count, 1)
        XCTAssertNotNil(root.submenu?.items.first?.view)
        XCTAssertTrue(root.submenu?.items.first?.view?.allowsVibrancy == true)
        XCTAssertEqual(root.submenu?.items.first?.view?.frame.width, 534)
        XCTAssertEqual(root.submenu?.items.first?.view?.layer?.backgroundColor?.alpha, 0)
        XCTAssertNil(root.submenu?.items.first?.submenu)
    }
    @MainActor func testSortDirectionsAndUnmeasuredLast() {
        let library = ModelLibrary()
        let measured = library.references
        let ascending = sortedRecommendations(library.models, results: measured, column: .errorRate, ascending: true)
        let descending = sortedRecommendations(library.models, results: measured, column: .errorRate, ascending: false)
        let ascValues = ascending.compactMap { measured[$0.id]?.wordErrorRate }
        let descValues = descending.compactMap { measured[$0.id]?.wordErrorRate }
        XCTAssertEqual(ascValues, ascValues.sorted())
        XCTAssertEqual(descValues, descValues.sorted(by: >))
        if library.models.contains(where: { measured[$0.id] == nil }) {
            XCTAssertNil(measured[ascending.last!.id]); XCTAssertNil(measured[descending.last!.id])
        }
    }
    @MainActor func testAgentRequestCopiesLocalDocumentationLink() {
        let library = ModelLibrary()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(library.copyAgentRequest(to: pasteboard))
        let request = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(request.contains(library.resources.appendingPathComponent("AGENT_GUIDE.md").path))
        XCTAssertTrue(request.contains("transcription model"))
        XCTAssertTrue(request.contains("Source checkout:"))
        XCTAssertTrue(request.contains("ask before switching models"))
        XCTAssertLessThan(request.count, 700)
    }
    @MainActor func testReferenceSelectionPrefersMatchingProcessorWithoutRelabeling() throws {
        let original = try XCTUnwrap(ModelLibrary().references["Qwen3-ASR-1.7B-bf16"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["machine"] = "Apple M4 Pro"
        let other = try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(preferredBenchmark([original, other], processor: "Apple M4 Pro")?.machine, "Apple M4 Pro")
        XCTAssertEqual(preferredBenchmark([original], processor: "Apple M4 Pro")?.machine, original.machine)
    }
    func testTwentyMinuteSuiteHasDiverseSpeakersAndAlignedClips() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/Benchmarks/english-20m-v1/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clips = try XCTUnwrap(manifest["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.count, 141)
        XCTAssertEqual(Set(clips.compactMap { $0["speaker"] as? Int }).count, 35)
        let duration = try XCTUnwrap(manifest["audioSeconds"] as? Double)
        XCTAssertGreaterThanOrEqual(duration, 1200)
        XCTAssertLessThan(duration, 1201)
        XCTAssertTrue(clips.allSatisfy { !($0["reference"] as? String ?? "").isEmpty })
    }
    @MainActor func testProcessorFallbackUsesNearestGenerationThenM5Max() throws {
        let original = try XCTUnwrap(ModelLibrary().references["Qwen3-ASR-1.7B-bf16"])
        func measured(on machine: String) throws -> BenchmarkResult {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object["machine"] = machine
            return try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let pro = try measured(on: "Apple M1 Pro"), base = try measured(on: "Apple M1"), unrelated = try measured(on: "Apple M4 Ultra")
        XCTAssertEqual(preferredBenchmark([original, base, pro], processor: "Apple M1 Max")?.machine, "Apple M1 Pro")
        XCTAssertEqual(preferredBenchmark([unrelated, original], processor: "Apple M2 Max")?.machine, "Apple M5 Max")
        XCTAssertEqual(preferredBenchmark([base, pro, original], processor: "M1")?.machine, "Apple M1")
        XCTAssertNil(preferredBenchmark([unrelated], processor: "Apple M2 Max"))
    }
    @MainActor func testFormattedResultsAndSorting() throws {
        let library = ModelLibrary()
        XCTAssertEqual(library.references.count, 16)
        let benchmarkOnly: Set<String> = [
            "Qwen3-ASR-0.6B-4bit", "nemotron-3.5-asr-streaming-0.6b-8bit",
            "Voxtral-Mini-4B-Realtime-2602-4bit", "granite-speech-5.0-470m-turboctc-mlx-fp16"
        ]
        XCTAssertTrue(benchmarkOnly.isSubset(of: Set(library.references.keys)))
        XCTAssertTrue(benchmarkOnly.isDisjoint(with: Set(library.models.map(\.id))))
        for result in library.references.values {
            XCTAssertEqual(result.suiteID, "english-formatted-20m-v1")
            XCTAssertNotNil(result.formatting?.scorerSHA256)
            XCTAssertNotNil(result.formatting?.lexicalNormalizerSHA256)
            XCTAssertEqual(result.formatting?.quotedReferenceClips, 3)
        }
        let rows = sortedRecommendations(library.models, results: library.references, column: .formattedError, ascending: true)
        let values = rows.compactMap { library.references[$0.id]?.formatting?.formattedCharacterErrorRate }
        XCTAssertEqual(values, values.sorted())
        let original = try XCTUnwrap(library.references["Qwen3-ASR-1.7B-bf16"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["clips"] = []
        let compact = try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(compact.formatting?.formattedCharacterErrorRate, original.formatting?.formattedCharacterErrorRate)
        XCTAssertTrue(compact.clips.isEmpty)
    }
    @MainActor func testRecommendedRowsKeepFullCatalogAndActiveException() {
        let library = ModelLibrary()
        library.activeModelPath = ""
        library.installed = [:]
        XCTAssertEqual(library.displayedModels.count, 5)
        XCTAssertEqual(Set(library.displayedModels.map(\.architecture)).count, 5)
        XCTAssertTrue(library.displayedModels.allSatisfy { $0.recommended == true })
        XCTAssertGreaterThanOrEqual(library.models.count, 12)
        library.installed["Qwen3-ASR-1.7B-8bit"] = InstalledModel(path: "/tmp/vella-active-test")
        library.activeModelPath = "/tmp/vella-active-test"
        XCTAssertEqual(library.displayedModels.count, 6)
        XCTAssertTrue(library.displayedModels.contains { $0.id == "Qwen3-ASR-1.7B-8bit" })
        XCTAssertEqual(library.activeModelPath, "/tmp/vella-active-test")
    }
    @MainActor func testMemoryColumnUsesWarmMeasurements() throws {
        let library = ModelLibrary()
        XCTAssertTrue(library.references.values.allSatisfy { ($0.runtimePeakMLXBytes ?? 0) > 0 })
        let sorted = sortedRecommendations(library.models, results: library.references, column: .memory, ascending: true)
        let values = sorted.compactMap { library.references[$0.id]?.runtimePeakMLXBytes }
        XCTAssertEqual(values, values.sorted())
        let original = try XCTUnwrap(library.references.values.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "runtimePeakMLXBytes")
        let legacy = try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.runtimePeakMLXBytes)
        XCTAssertNotNil(legacy.peakMLXBytes)
    }
}
