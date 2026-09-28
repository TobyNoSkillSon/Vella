import XCTest
import Foundation
@testable import Vella
@testable import VellaCore

/// The Models table's hover text in the family tooltip format (VFamily hover contract, "Tooltip text format"), on the
/// shipped catalog and benchmarks. Every tooltip of every offered row, at every precision, unloaded and loaded, obeys
/// the line rules and the forbidden patterns; the model notes are pinned. The cells show these texts through AppKit
/// (TooltipCell.swift), since SwiftUI `.help` never shows inside NSMenu tracking.
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

    /// Forbidden anywhere in tooltip text: commit hashes, paths and repository ids, revisions, JSON, URLs, filler,
    /// internal worker names (two letters, dash, word: `vg-gate`).
    private static let forbidden: [(String, String)] = [
        (#"\b[0-9a-f]{7,}\b"#, "hex hash"), ("/", "path or repository id"), ("@", "revision"), (#"[{}]"#, "JSON"),
        ("(?i)not stated", "filler"), ("(?i)not disclosed", "filler"), ("(?i)not listed", "filler"), ("(?i)https?:", "URL"),
        (#"\bv[a-z]-[a-z]+"#, "worker name"), (#"\bVELLA_"#, "environment name")
    ]
    private func assertClean(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.isEmpty, label, file: file, line: line)
        for (pattern, what) in Self.forbidden where text.range(of: pattern, options: .regularExpression) != nil {
            XCTFail("\(label): \(what) in tooltip:\n\(text)", file: file, line: line)
        }
        for l in text.components(separatedBy: "\n") {
            XCTAssertFalse(l.trimmingCharacters(in: .whitespaces).isEmpty, "\(label): empty line", file: file, line: line)
            XCTAssertFalse(l.contains("  "), "\(label): double space: \(l)", file: file, line: line)
        }
    }
    /// Fragments carry no trailing period (the recommended segment's gate sentences and the engine lines are exempt).
    private func assertNoTrailingPeriod(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for l in text.components(separatedBy: "\n") where l.hasSuffix(".") {
            XCTFail("\(label): trailing period: \(l)", file: file, line: line)
        }
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    private static let figures: Set<String> = ["WER", "Format", "Speed", "J / min", "Memory"]
    private static let provenance = #"^Measured by Vella · M5 Max · 20\d\d-\d\d-\d\d$"#

    /// Checks every cell of one row's tooltips against the format, and that each cell has one.
    @MainActor private func checkRow(_ table: ModelTable, _ family: ModelFamily, loaded: LoadedFamily?, state: String) {
        let cells = table.tooltips(family)
        let columns = cells.map(\.0)
        XCTAssertEqual(Set(columns).count, columns.count, "\(state): one tooltip per cell")
        for (column, text) in cells {
            let label = "\(family.id) \(state) [\(column)]"
            assertClean(text, label)
            let l = lines(text)
            switch column {
            case "Model":
                XCTAssertTrue((2...5).contains(l.count), "\(label): 2-5 lines")
                XCTAssertEqual(l.first, family.name, label)
                XCTAssertTrue(l.contains { $0.hasSuffix("parameters · native \(precisionInProse(family.native))") }, label)
                XCTAssertFalse(text.contains(" · ") && l.contains { $0.components(separatedBy: " · ").count > 2 }, "\(label): no · chains")
                if let loaded { XCTAssertTrue(l.last?.hasPrefix("Loaded at \(precisionInProse(loaded.precision))") ?? false, label) }
                else { XCTAssertFalse(text.contains("Loaded"), label) }
                assertNoTrailingPeriod(text, label)
            case let c where Self.figures.contains(c):
                if text == notMeasuredHelp { continue }
                XCTAssertEqual(l.count, 2, "\(label): what it is, then where it comes from")
                XCTAssertNotNil(l[0].range(of: #": (lower is better|higher is faster)"#, options: .regularExpression), "\(label): \(l[0])")
                XCTAssertNotNil(l.last?.range(of: Self.provenance, options: .regularExpression), "\(label): \(l.last ?? "")")
                assertNoTrailingPeriod(text, label)
            case "On disk":
                XCTAssertTrue((1...2).contains(l.count), label)
                assertNoTrailingPeriod(text, label)
            case "Languages":
                XCTAssertTrue(l.count == 1 || l.count == 3, "\(label): the list, then by-language WER and its provenance")
                if l.count == 3 { XCTAssertNotNil(l[2].range(of: Self.provenance, options: .regularExpression), label) }
                assertNoTrailingPeriod(text, label)
            case let c where c.hasPrefix("Q "):
                // The recommended segment adds the rule and one line per rejected, more efficient precision.
                XCTAssertTrue((1...8).contains(l.count), label)
                XCTAssertTrue(l[0].hasPrefix(precisionFormatName(String(c.dropFirst(2)))), label)
            case "Engine":
                XCTAssertNotNil(loaded, label)
            default:
                XCTFail("\(label): unexpected column")
            }
        }
        let expected = ["Model"] + (loaded?.engine != nil ? ["Engine"] : []) + ["Languages"] + table.controller.options(family).map { "Q \($0)" }
            + ["WER", "Format", "Speed", "J / min", "Memory", "On disk"]
        XCTAssertEqual(columns, expected, "\(family.id) \(state)")
    }

    /// Every tooltip the table renders, for every offered row at every offered precision, unloaded and loaded
    /// (on demand and kept hot, with the engine label), follows the family format.
    @MainActor func testEveryRenderedTooltipFollowsTheFamilyFormat() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let families = c.families(.dictation) + c.families(.streaming)
        XCTAssertEqual(families.count, 7)
        var checked = 0
        for family in families {
            for loaded in [nil, LoadedFamily(precision: c.options(family)[0], engine: "optimized", optimizations: ["decoder": true], residency: "manual"),
                           LoadedFamily(precision: c.options(family).last!, engine: "mlx", engineReason: "no optimized path for this model", residency: "on_demand")] {
                c.runtime = TableRuntime(loaded: loaded.map { [family.id: $0] } ?? [:], chip: "Apple M5 Max")
                for precision in c.options(family) {
                    c.preview(family, precision)
                    checkRow(table, family, loaded: loaded, state: "\(precision)\(loaded.map { " loaded \($0.precision)" } ?? "")")
                    checked += 1
                }
                c.discardPreviews()
            }
        }
        XCTAssertEqual(checked, 3 * families.reduce(0) { $0 + c.options($1).count })
        for r in c.references(.dictation) + c.references(.streaming) {
            let cells = table.tooltips(r)
            XCTAssertEqual(cells.map(\.0), ["Model", "WER", "Format", "Speed", "J / min", "Memory", "On disk"])
            for (column, text) in cells {
                assertClean(text, "\(r.id) [\(column)]")
                assertNoTrailingPeriod(text, "\(r.id) [\(column)]")
            }
        }
    }

    /// The Model tooltip of every offered row, as the catalog's structured fields assemble it.
    static let modelNotes: [String: String] = [
        "parakeet-v3-ultra": """
            Parakeet v3 Ultra
            Moondream, 2026 · CC BY 4.0
            NVIDIA's Parakeet v3, post-trained for dictation in 25 European languages; none from outside Europe
            0.6B parameters · native BF16
            """,
        "parakeet-v3": """
            Parakeet v3
            NVIDIA, 2025 · CC BY 4.0
            The unmodified Parakeet v3 that Ultra is post-trained from: the same 25 European languages, no others
            0.6B parameters · native FP32
            """,
        "qwen3-asr-1.7b": """
            Qwen3 ASR 1.7B
            Qwen (Alibaba), 2026 · Apache-2.0
            Dictation in 30 languages, including Chinese, Japanese and Korean, which Parakeet lacks; slower than Parakeet
            1.7B parameters · native BF16
            """,
        "qwen3-asr-0.6b": """
            Qwen3 ASR 0.6B
            Qwen (Alibaba), 2026 · Apache-2.0
            The smaller Qwen3 ASR: the same 30 languages in less memory, a little less accurate than the 1.7B
            0.6B parameters · native BF16
            """,
        "whisper-large-v3": """
            Whisper large-v3
            OpenAI, 2023 · Apache-2.0
            Dictation in about 100 languages, the most of any model here, from a family other than Parakeet and Qwen
            1.55B parameters · native FP16
            """,
        "whisper-large-v3-turbo": """
            Whisper large-v3 turbo
            OpenAI, 2024 · MIT
            Whisper large-v3 with 4 decoder layers instead of 32: the same languages, much faster, a little less accurate outside English
            0.8B parameters · native FP16
            """,
        "nemotron-3.5-streaming-0.6b": """
            Nemotron 3.5 Streaming
            NVIDIA, 2026 · OpenMDW-1.1 (MLX conversion: NVIDIA Open Model License)
            Transcribes audio as it arrives, so Streaming mode types while you speak; not used for Dictation
            0.6B parameters · native BF16
            """,
    ]

    @MainActor func testModelTooltipsArePinned() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let families = c.families(.dictation) + c.families(.streaming)
        XCTAssertEqual(Set(families.map(\.id)), Set(Self.modelNotes.keys))
        for family in families {
            XCTAssertEqual(table.tooltips(family).first { $0.0 == "Model" }?.1, Self.modelNotes[family.id], family.id)
            XCTAssertNotNil(family.publisher, family.id); XCTAssertNotNil(family.released, family.id)
            XCTAssertNotNil(family.licence, family.id); XCTAssertNotNil(family.summary, family.id)
        }
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        XCTAssertEqual(modelHelp(turbo, loaded: LoadedFamily(precision: "8b", residency: "manual")),
                       Self.modelNotes["whisper-large-v3-turbo"]! + "\nLoaded at 8-bit, kept hot")
        XCTAssertEqual(modelHelp(turbo, loaded: LoadedFamily(precision: "FP16", residency: "on_demand")).components(separatedBy: "\n").last,
                       "Loaded at FP16, on demand")
        // A family without the structured fields: name, the licence's display name, size; nothing invented.
        var bare = turbo; bare.publisher = nil; bare.released = nil; bare.licence = nil; bare.summary = nil
        XCTAssertEqual(modelHelp(bare), "Whisper large-v3 turbo\nMIT\n0.8B parameters · native FP16")
        bare.license = "Some custom licence (see repository)"
        XCTAssertEqual(modelHelp(bare), "Whisper large-v3 turbo\n0.8B parameters · native FP16", "a free-form licence id is not shown")
    }

    /// One row's figures in full: what each is, then who measured it, where and when.
    @MainActor func testFigureTooltipsArePinned() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        c.preview(ultra, "BF16")
        let tips = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let by = "Measured by Vella · M5 Max · 2026-09-28"
        XCTAssertEqual(tips["WER"], "English word error rate on the v2 benchmark (240 min): lower is better\n" + by)
        XCTAssertEqual(tips["Format"], "Character error rate on the v2 benchmark (240 min), with case and punctuation kept: lower is better\n" + by)
        XCTAssertEqual(tips["Speed"], "Speed in × real time on the v2 quick benchmark (22.5 min), timed after loading: higher is faster\n" + by)
        XCTAssertEqual(tips["J / min"], "Whole-chip joules per audio minute on the v2 quick benchmark (22.5 min), net of loaded idle power: lower is better\n" + by)
        XCTAssertEqual(tips["Memory"], "Peak memory of Vella's model worker on the v2 quick benchmark (22.5 min), loading included: lower is better\n" + by)
        XCTAssertEqual(tips["On disk"], "Not downloaded\nDownloads \(formatBytes(ultra.variants["BF16"]!.downloadBytes)) from Hugging Face after you confirm")
        let languages = try XCTUnwrap(tips["Languages"])
        XCTAssertTrue(languages.hasPrefix("25 languages: Bulgarian, Croatian, Czech"), languages)
        XCTAssertEqual(lines(languages)[1], "Word error rate by language: French 16.0%, German 8.5%, Polish 6.9%, Spanish 13.9%, Swedish 19.1%; mean 12.9%")
        c.preview(ultra, "4b")
        let derived = "Made on this Mac at load from the BF16 weights; nothing extra is stored"
        XCTAssertEqual(table.tooltips(ultra).first { $0.0 == "On disk" }?.1,
                       c.disk(ultra, "4b") == nil ? derived : derived + "\nThe size shown is those BF16 files")
        let nemotron = try XCTUnwrap(c.catalog.family("nemotron-3.5-streaming-0.6b"))
        XCTAssertEqual(speedHelp(nemotron.mode, c.result(nemotron, "8b"), suites: c.benchmarks.suites),
                       "Streaming replay speed in × real time on the v2 quick benchmark (22.5 min), not microphone-to-text latency: higher is faster\n" + by)
    }

    /// Cloud rows: estimated, from which board and when; nothing to download; nothing runs on this Mac.
    @MainActor func testCloudRowTooltipsArePinned() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let azure = try XCTUnwrap(c.references(.dictation).first { $0.id == "azure-speech" })
        let tips = Dictionary(table.tooltips(azure).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tips["Model"], "Microsoft Azure Speech\nMicrosoft · Proprietary cloud API\nCloud speech-to-text shown for comparison only; Vella never sends audio to it")
        XCTAssertEqual(tips["WER"], "Estimated English word error rate on the v2 benchmark, range 11.3–13.3%: lower is better\n"
                       + "Estimate scaled from the Hugging Face Open ASR Leaderboard · 2026-09-26")
        XCTAssertEqual(tips["Speed"], referenceNotApplicableHelp)
        XCTAssertEqual(tips["On disk"], "Cloud service: nothing to download\nVella never sends audio to it")
    }

    /// The table's source uses AppKit tooltips only: SwiftUI `.help` never shows inside NSMenu tracking.
    func testModelsTableUsesNoSwiftUIHelp() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/Vella/ModelsMenu.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains(".help("), "use .appKitTooltip on a framed non-interactive cell")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: ".appKitTooltip(").count - 1, 20)
    }
}
