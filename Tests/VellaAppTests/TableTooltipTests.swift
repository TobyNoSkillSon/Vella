import XCTest
import Foundation
@testable import Vella
@testable import VellaCore

/// The family hover contract (VFamily, 28 Sep 2026) on the shipped catalog and benchmarks: every offered model's name
/// says what it is, who released it, when, what it is for in Vella and its exact licence name; every figure says
/// what it is based on and who measured or estimated it.
final class TableTooltipTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }

    @MainActor private func shippedController() throws -> ModelsController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-tooltips-\(UUID())")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("models-installed.json")
        let resources = ModelLibrary.resourceDirectory()
        return ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                benchmarksURL: resources.appendingPathComponent("benchmarks.json"))
    }

    private static let licenceNames = ["CC BY 4.0", "Apache-2.0", "MIT"]
    private static let publishers = ["NVIDIA", "Moondream", "Qwen", "OpenAI"]

    @MainActor func testEveryOfferedModelNoteNamesPublisherYearPurposeAndLicence() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let families = c.families(.dictation) + c.families(.streaming)
        XCTAssertEqual(families.count, 7)
        for family in families {
            let notes = try XCTUnwrap(family.notes, family.id)
            XCTAssertTrue((2...3).contains(notes.components(separatedBy: ". ").count) && notes.count <= 400, "\(family.id): keep the note to 2-3 sentences: \(notes)")
            XCTAssertNotNil(notes.range(of: #"\b20\d\d\b"#, options: .regularExpression), "\(family.id): release year")
            XCTAssertTrue(Self.publishers.contains { notes.contains($0) }, "\(family.id): who released it")
            XCTAssertTrue(notes.contains("In Vella:") || notes.contains("In Vella it"), "\(family.id): what it is for in Vella")
            let model = try XCTUnwrap(table.tooltips(family).first { $0.0 == "Model" }?.1, family.id)
            XCTAssertTrue(model.contains(notes), family.id)
            let licence = try XCTUnwrap(model.range(of: "License: ").map { String(model[$0.upperBound...]) }, family.id)
            XCTAssertTrue(Self.licenceNames.contains { licence == $0 + "." } || licence.hasPrefix("OpenMDW-1.1"),
                          "\(family.id): exact licence name, not a metadata id: \(licence)")
        }
        XCTAssertEqual(ModelTable.licenseName("cc-by-4.0"), "CC BY 4.0")
        XCTAssertEqual(ModelTable.licenseName("apache-2.0"), "Apache-2.0")
        XCTAssertEqual(ModelTable.licenseName("mit"), "MIT")
        let nemotron = try XCTUnwrap(c.catalog.family("nemotron-3.5-streaming-0.6b"))
        XCTAssertTrue(ModelTable.licenseName(nemotron.license).contains("NVIDIA Open Model License"), "upstream and conversion licences both named")
    }

    /// Every figure a local row shows names its benchmark and that we measured it, on which Mac and when.
    @MainActor func testEveryScoreTooltipStatesItsBasis() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        for family in c.families(.dictation) + c.families(.streaming) {
            for precision in c.options(family) {
                c.preview(family, precision)
                guard c.result(family, precision) != nil else { continue }
                let tips = Dictionary(table.tooltips(family).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
                for column in ["WER", "Format", "Speed", "J / min", "Memory"] {
                    let text = try XCTUnwrap(tips[column], "\(family.id) \(precision) \(column)")
                    if text == "Not measured at this precision." { continue }
                    XCTAssertTrue(text.contains("Benchmark vella-v2"), "\(family.id) \(precision) \(column): benchmark: \(text)")
                    XCTAssertTrue(text.contains("Measured by us on Apple M5 Max"), "\(family.id) \(precision) \(column): who and which Mac: \(text)")
                    XCTAssertNotNil(text.range(of: #"20\d\d-\d\d-\d\d"#, options: .regularExpression), "\(family.id) \(precision) \(column): date")
                }
                for column in ["Speed", "J / min", "Memory"] where tips[column] != "Not measured at this precision." {
                    XCTAssertTrue(tips[column]?.contains("Benchmark vella-v2-quick, 22.5 min of audio") ?? false,
                                  "\(family.id) \(precision) \(column): performance comes from the quick suite")
                }
                let disk = try XCTUnwrap(tips["On disk"])
                XCTAssertTrue(disk.contains("pinned Hugging Face revision") || disk.contains("Measured by us") || disk.contains("not measured"),
                              "\(family.id) \(precision) On disk: \(disk)")
            }
            c.discardPreviews()
        }
        for header in ["WER", "Format", "Speed", "J / min", "Memory", "On disk"] {
            XCTAssertTrue(ModelTable.headerHelps.contains { $0.0 == header && !$0.1.isEmpty }, header)
        }
    }

    /// Cloud rows: every column says estimated, not applicable or not disclosed, and the WER estimate names its board and date.
    @MainActor func testCloudRowTooltipsStateTheirBasis() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let references = c.references(.dictation)
        XCTAssertFalse(references.isEmpty)
        for r in references {
            let tips = Dictionary(table.tooltips(r).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            XCTAssertEqual(Set(tips.keys), ["Model", "Params", "WER", "Format", "Speed", "J / min", "Memory", "On disk"])
            XCTAssertTrue(tips["Model"]!.contains("proprietary cloud") && tips["Model"]!.contains("not measured by us"), tips["Model"]!)
            let wer = tips["WER"]!
            XCTAssertTrue(wer.hasPrefix("Estimated, not measured by us") && wer.contains("Open ASR Leaderboard"), wer)
            XCTAssertNotNil(wer.range(of: #"Estimate made 20\d\d-\d\d-\d\d\."#, options: .regularExpression), wer)
            for column in ["Speed", "J / min", "Memory"] { XCTAssertEqual(tips[column], ModelTable.referenceNotApplicable) }
        }
    }
}
