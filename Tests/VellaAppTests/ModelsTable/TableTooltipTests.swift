import XCTest
import Foundation
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// The Models table's hover text in the family tooltip format (VFamily hover contract, "Tooltip text format"), on the
/// shipped catalog and benchmarks. Every tooltip of every offered row, at every precision, unloaded and loaded, obeys
/// the line rules and the forbidden patterns; the model notes are pinned. The cells show these texts through AppKit
/// (TooltipCell.swift), since SwiftUI `.help` never shows inside NSMenu tracking.
final class TableTooltipTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }

    /// The Macs the tooltips are checked on: the measured M5 Max, an M4 Pro (no tensor units) and an M1.
    static let macs: [(name: String, hardware: BenchmarkHardware, gpu: GPUCapability)] = [
        ("M5 Max", .measured, GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)),
        ("M4 Pro", BenchmarkHardware(chip: "Apple M4 Pro", gpuCores: 20), GPUCapability(appleFamily: 9, architecture: "applegpu_g16s", osMajor: 26, osMinor: 6)),
        ("M1", BenchmarkHardware(chip: "Apple M1", gpuCores: 8), GPUCapability(appleFamily: 7, architecture: "applegpu_g13g", osMajor: 26, osMinor: 6))
    ]

    @MainActor private func shippedController() throws -> ModelsController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-tooltips-\(UUID())")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("models-installed.json")
        let resources = ModelLibrary.resourceDirectory()
        let c = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"))
        // Fixed hardware, whatever Mac runs the tests: the measured M5 Max.
        c.benchmarkHardware = Self.macs[0].hardware; c.gpu = Self.macs[0].gpu
        return c
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
        // The requested Parakeet attribution URL is the only permitted URL, in the Model column only.
        let checked =
            label.hasSuffix("[Model]") && (label.hasPrefix("parakeet-v3 ") || label.hasPrefix("parakeet-v3-ultra "))
            ? text.replacingOccurrences(of: "https://creativecommons.org/licenses/by/4.0/", with: "") : text
        for (pattern, what) in Self.forbidden where checked.range(of: pattern, options: .regularExpression) != nil {
            XCTFail("\(label): \(what) in tooltip:\n\(text)", file: file, line: line)
        }
        for l in text.components(separatedBy: "\n") {
            XCTAssertFalse(l.trimmingCharacters(in: .whitespaces).isEmpty, "\(label): empty line", file: file, line: line)
            XCTAssertFalse(l.contains("  "), "\(label): double space: \(l)", file: file, line: line)
        }
    }
    /// Fragments carry no trailing period (the reference figure's two sentences are exempt).
    private func assertNoTrailingPeriod(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for l in text.components(separatedBy: "\n") where l.hasSuffix(".") && !l.hasPrefix("Not measured yet:") && !l.hasPrefix("Not measured on your Mac.") {
            XCTFail("\(label): trailing period: \(l)", file: file, line: line)
        }
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    private static let figures: Set<String> = ["WER", "Format", "Speed", "J / min", "Peak RAM"]
    private static let provenance = #"^Measured by Vella · M5 Max · 20\d\d-\d\d-\d\d$"#
    /// The tier cell's delta line: vs the 16-bit cell of the same switch position with its basis (speed and energy only
    /// on the measured Mac), the reference itself, or pending. Never "Standard".
    private static let deltaPattern =
        #"^(vs (bf16|fp16): (Speed: (same|[0-9.]+% (faster|slower)|[0-9.]+× faster)( · Energy: (same|[0-9.]+% (less|more)))? · )?(WER (−|\+)[0-9.]+ pt|same WER) · M5 Max, \d+ (Sep|Oct)|Reference for the deltas · M5 Max, \d+ (Sep|Oct)|No (bf16|fp16) measurement to compare with yet · M5 Max, \d+ (Sep|Oct)|Not measured yet(: [^\n]+)?)$"#
    /// A greyed cell's one line: why it cannot be chosen.
    private static let greyedPattern =
        #"^(Not measured yet(: [^\n]+)?|Not offered: [^\n]+|Not offered for this model|No Exact recipe at (bf16|fp16|int[48]); Fast offers it)$"#
    /// The warning triangle's line: a precision without matrix hardware on this Mac.
    private static let warningPattern =
        #"^(No hardware support for (int8|int4) on this Mac|(Exact runs|Runs) (int8|int4) without the matrix hardware on this Mac): saves memory, (may be slower than (bf16|fp16)|measured slower than (bf16|fp16) here)$"#
    /// The gold cell's line: why it is recommended for this Mac.
    private static let recommendedPattern =
        #"^Recommended for this Mac(: (int8|int4) keeps (bf16|fp16) accuracy, uses less memory and (runs on this Mac's matrix hardware|measured faster than (bf16|fp16) on this Mac)|: [^\n]+)?$"#
    /// The first line of a speed or energy figure on another Mac.
    private static let referencePattern = #"^Not measured on your Mac\. M5 Max: [0-9.]+(×| J) (real time|per audio minute)\.$"#

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
                if let loaded {
                    XCTAssertTrue(l.last?.hasPrefix("Loaded at \(humanDType(precision: loaded.precision, familyID: family.id))") ?? false, label)
                } else {
                    XCTAssertFalse(text.contains("Loaded"), label)
                }
                assertNoTrailingPeriod(text, label)
            case let c where Self.figures.contains(c):
                XCTAssertEqual(text == figuresPendingHelp, table.controller.benchmarks.figuresPending, "\(label): pending figures show none")
                if text == notMeasuredHelp || text == figuresPendingHelp { continue }
                if text.hasPrefix("Not measured yet:") {
                    let cell = table.controller.shownCell(family).flatMap { benchmarkCell(table.controller.benchmark(family), $0) }
                    XCTAssertTrue(cell?.isPending == true, label)
                    XCTAssertEqual(text, unmeasuredReasonHelp(cell), label)
                    continue
                }
                // On another Mac, speed and energy start with the M5 Max reference line; the other figures never do.
                var l = l
                let measuredHere = table.controller.benchmarkHardware.isMeasuredConfiguration
                if ["Speed", "J / min"].contains(c), !measuredHere {
                    XCTAssertNotNil(l.first?.range(of: Self.referencePattern, options: .regularExpression), "\(label): \(l.first ?? "")")
                    l.removeFirst()
                } else {
                    XCTAssertFalse(text.contains("Not measured on your Mac"), "\(label): only speed and energy are hardware-dependent")
                }
                // Two lines: what it is, then who measured it; WER adds the measured languages on a third.
                XCTAssertEqual(l.count, c == "WER" && l.count == 3 ? 3 : 2, "\(label): what it is, then where it comes from")
                if l.count == 3 { XCTAssertTrue(l[2].hasPrefix("Word error rate by language: "), "\(label): \(l[2])") }
                guard l.count >= 2 else { continue }
                XCTAssertNotNil(l[0].range(of: #": (lower is better|higher is faster)"#, options: .regularExpression), "\(label): \(l[0])")
                XCTAssertNotNil(l[1].range(of: Self.provenance, options: .regularExpression), "\(label): \(l[1])")
                assertNoTrailingPeriod(text, label)
            case "Action":
                XCTAssertEqual(l.count, 2, "\(label): the model's state, then what a click does")
                XCTAssertTrue(["Loaded", "On disk, not loaded", "Not downloaded"].contains(l[0]), "\(label): \(l[0])")
                XCTAssertNotNil(
                    l.last?.range(of: "^(Asks, then downloads|Load it for|Free its memory|Unload the loaded precision)", options: .regularExpression), "\(label): \(l.last ?? "")")
            case let c where c.hasPrefix("Precision ") && text.range(of: Self.greyedPattern, options: .regularExpression) != nil:
                continue // a greyed cell: one line saying why (absent, no Exact recipe, not measured yet)
            case let c where c.hasPrefix("Precision "):
                // The warning (a precision without matrix hardware here) and the recommendation (the gold cell) first;
                // then flavour; delta vs 16-bit with its basis; for a worse precision its loss; while in use the
                // interlock. While the figures are pending, the flavour alone (and the interlock): no gold, no warning.
                let pending = table.controller.benchmarks.figuresPending
                var l = l
                if let first = l.first, first.range(of: Self.warningPattern, options: .regularExpression) != nil {
                    XCTAssertFalse(pending, "\(label): no warning on pending figures"); l.removeFirst()
                }
                if let first = l.first, first.hasPrefix("Recommended") {
                    XCTAssertNotNil(first.range(of: Self.recommendedPattern, options: .regularExpression), "\(label): \(first)")
                    XCTAssertFalse(pending, "\(label): no recommendation on pending figures"); l.removeFirst()
                }
                XCTAssertTrue((pending ? 1...2 : 2...4).contains(l.count), "\(label): \(text)")
                XCTAssertNotNil(
                    l[0].range(
                        of:
                            #"^(bf16|fp16), (as published|converted once from the published fp32)$|^[48]-bit weights throughout \(affine-[48] g64\)$|^(16|[48])-bit [A-Za-z._ ]+(, (16|[48])-bit [A-Za-z._ ]+)* \(affine-[48] g64\)$"#,
                        options: .regularExpression), "\(label): \(l[0])")
                if pending {
                    XCTAssertTrue(l.dropFirst().allSatisfy { $0 == TierControl.inUseHelp }, "\(label): no delta while pending")
                    continue
                }
                guard l.count >= 2 else { continue }
                XCTAssertNotNil(l[1].range(of: Self.deltaPattern, options: .regularExpression), "\(label): \(l[1])")
                for extra in l.dropFirst(2) {
                    XCTAssertTrue(extra.range(of: "^Loss vs (bf16|fp16): ", options: .regularExpression) != nil || extra == TierControl.inUseHelp, "\(label): \(extra)")
                }
                assertNoTrailingPeriod(text, label)
            case "Bolt":
                XCTAssertEqual(text, TierControl.boltHelp, label)
            case "Coupling":
                XCTAssertEqual(text, ModelTable.couplingHelp, label)
            case "Exact/Fast":
                XCTAssertEqual(l.first, ExactFastSwitch.help, label)
                XCTAssertTrue(
                    l.dropFirst().allSatisfy {
                        [ExactFastSwitch.sameHelp, ExactFastSwitch.pinnedUnmeasuredHelp, ExactFastSwitch.inUseHelp, ExactFastSwitch.exactNotMeasuredHelp].contains($0)
                    }, label)
            default:
                XCTFail("\(label): unexpected column")
            }
        }
        // The bolt, then all three cells, always, named by the dtype that runs; no path is ever named (Toby, 15 Oct).
        for (_, text) in cells { XCTAssertFalse(text.contains("Standard") || text.contains("Optimized"), "\(family.id) \(state): \(text)") }
        let precisionColumns = ["Bolt"] + ModelTier.allCases.map { "Precision \(tierDTypeLabel(family, $0))" }
        let expected =
            ["Model"] + (table.controller.couplingNote(family) != nil ? ["Coupling"] : []) + precisionColumns
            + (table.controller.hasOptimizedPath(family) ? ["Exact/Fast"] : [])
            + ["WER", "Format", "Speed", "J / min", "Peak RAM", "Action"]
        XCTAssertEqual(columns, expected, "\(family.id) \(state)")
    }

    @MainActor func testLoadedWithdrawnWhisperFigureTooltipsRetainTheirReason() throws {
        let c = try shippedController()
        let family = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        // A synthetic withdrawal still explains its reason; the corrected bundled Standard cell is measured.
        var benchmark = try XCTUnwrap(c.benchmarks.models[family.id])
        benchmark.tiers[.t16]?.cells[.standard]?.measured = nil
        benchmark.tiers[.t16]?.cells[.standard]?.result = PrecisionResult()
        benchmark.tiers[.t16]?.cells[.standard]?.notMeasuredReason = "fixture: Standard measurement withdrawn"
        c.benchmarks.models[family.id] = benchmark
        // A worker on stock MLX after a fallback: its figures are the (withdrawn) stock cell's.
        let standard = ModelSelection(tier: .t16, path: .standard, mode: .fast)
        c.runtime = TableRuntime(loaded: [family.id: LoadedFamily(precision: "FP16", engine: "mlx", selection: standard.request)], chip: "M5 Max")
        let table = ModelTable(controller: c)
        let cell = try XCTUnwrap(benchmarkCell(c.benchmark(family), standard))
        for (column, text) in table.tooltips(family) where Self.figures.contains(column) {
            XCTAssertEqual(text, unmeasuredReasonHelp(cell), column)
        }
    }

    /// Every tooltip the table renders, for every offered row in every present cell and switch position, unloaded and
    /// loaded (on demand and kept hot, on the optimized path and after a fallback to stock MLX), on the measured M5 Max,
    /// an M4 Pro and an M1, follows the family format.
    @MainActor func testEveryRenderedTooltipFollowsTheFamilyFormat() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let families = c.families(.dictation) + c.families(.streaming)
        XCTAssertEqual(families.count, 7)
        var checked = 0
        for mac in Self.macs {
            c.benchmarkHardware = mac.hardware; c.gpu = mac.gpu
            for pending in [true, false] {
                c.benchmarks.figuresPending = pending
                for family in families {
                    for loaded in [
                        nil, LoadedFamily(precision: c.options(family)[0], engine: "optimized", optimizations: ["decoder": true], residency: "manual"),
                        LoadedFamily(precision: c.options(family).last!, engine: "mlx", engineReason: "no optimized path for this model", residency: "on_demand")
                    ] {
                        c.runtime = TableRuntime(loaded: loaded.map { [family.id: $0] } ?? [:], chip: "Apple M5 Max")
                        for mode in [OptimizedMode.exact, .fast] {
                            for tier in c.precisions(family, mode) {
                                c.discardPreviews()
                                c.setMode(family, mode)
                                c.select(family, tier: tier)
                                checkRow(table, family, loaded: loaded, state: "\(tier.rawValue) \(mode)\(loaded.map { " loaded \($0.precision)" } ?? "")")
                                checked += 1
                            }
                        }
                        c.discardPreviews()
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 3 * 2 * 3 * 2 * families.count)
        for r in c.references(.dictation) + c.references(.streaming) {
            let cells = table.tooltips(r)
            XCTAssertEqual(cells.map(\.0), ["Model", "WER", "Format", "Speed", "J / min", "Peak RAM"])
            for (column, text) in cells {
                assertClean(text, "\(r.id) [\(column)]")
                assertNoTrailingPeriod(text, "\(r.id) [\(column)]")
            }
        }
    }

    /// Every Precision segment's tooltip of the shipped table (both switch positions, on the measured M5 Max, an M4 Pro
    /// and an M1: recommendation and warning lines included), the bolt's and the Exact/Fast switch's, pinned in
    /// TierTooltips.txt beside this file. `VELLA_PIN_UPDATE=1 swift test --filter TableTooltipTests` rewrites it after
    /// a deliberate change (review the diff).
    @MainActor func testTierCellTooltipsArePinned() throws {
        let c = try shippedController()
        c.benchmarks.figuresPending = false // pinned as after the final measurement; the pending text is checked below
        let table = ModelTable(controller: c)
        var blocks: [String] = []
        for mac in Self.macs {
            c.benchmarkHardware = mac.hardware; c.gpu = mac.gpu
            for family in c.families(.dictation) + c.families(.streaming) {
                for mode in [OptimizedMode.exact, .fast] {
                    c.discardPreviews()
                    c.setMode(family, mode)
                    for (column, text) in table.tooltips(family)
                    where column.hasPrefix("Precision ") || (mac.name == "M5 Max" && mode == .exact && (column == "Bolt" || column == "Exact/Fast")) {
                        let tag = column.hasPrefix("Precision ") ? " · \(mode == .exact ? "Exact" : "Fast") · \(mac.name)" : ""
                        blocks.append("[\(family.name) · \(column)\(tag)]\n\(text)\n")
                    }
                }
                c.discardPreviews()
            }
        }
        c.benchmarkHardware = Self.macs[0].hardware; c.gpu = Self.macs[0].gpu
        let text = blocks.joined(separator: "\n")
        let pin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("TierTooltips.txt")
        if ProcessInfo.processInfo.environment["VELLA_PIN_UPDATE"] == "1" { try text.write(to: pin, atomically: true, encoding: .utf8) }
        XCTAssertEqual(text, try String(contentsOf: pin, encoding: .utf8))
        // While the figures are pending, an available cell shows its flavour only; a greyed one its reason.
        c.benchmarks.figuresPending = true
        c.discardPreviews()
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let tips = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tips["Precision bf16"], "bf16, as published")
        XCTAssertEqual(tips["Precision int8"], "16-bit decoder, 16-bit joint (affine-8 g64)")
        XCTAssertNil(tips["Precision Standard bf16"], "no Standard row")
    }

    /// The Model tooltip of every offered row, as the catalog's structured fields assemble it.
    static let modelNotes: [String: String] = [
        "parakeet-v3-ultra": """
        Parakeet v3 Ultra
        Moondream, 2026 · CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)
        Moondream's post-training of NVIDIA Parakeet v3 for dictation in 25 European languages; none from outside Europe
        0.6B parameters · native BF16
        """,
        "parakeet-v3": """
        Parakeet v3
        NVIDIA, 2025 · CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)
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
        NVIDIA, 2026 · OpenMDW-1.1 upstream; MLX card: NVIDIA Open Model License
        Transcribes 28 languages as the audio arrives, so Streaming mode types while you speak; not used for Dictation
        0.6B parameters · native BF16
        """
    ]

    @MainActor func testModelTooltipsArePinned() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let families = c.families(.dictation) + c.families(.streaming)
        XCTAssertEqual(Set(families.map(\.id)), Set(Self.modelNotes.keys))
        for family in families {
            XCTAssertEqual(table.tooltips(family).first { $0.0 == "Model" }?.1, Self.modelNotes[family.id], family.id)
            // With the Capabilities column gone (Toby, 30 Sep), the languages live in the model's tooltip.
            XCTAssertTrue(Self.modelNotes[family.id]?.contains("languages") == true, "\(family.id): its languages")
            XCTAssertNotNil(family.publisher, family.id); XCTAssertNotNil(family.released, family.id)
            XCTAssertNotNil(family.licence, family.id); XCTAssertNotNil(family.summary, family.id)
        }
        let turbo = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        XCTAssertEqual(
            modelHelp(turbo, loaded: LoadedFamily(precision: "8b", residency: "manual")),
            Self.modelNotes["whisper-large-v3-turbo"]! + "\nLoaded at int8, kept hot")
        XCTAssertEqual(
            modelHelp(turbo, loaded: LoadedFamily(precision: "FP16", residency: "on_demand")).components(separatedBy: "\n").last,
            "Loaded at fp16, on demand")
        // A family without the structured fields: name, the licence's display name, size; nothing invented.
        var bare = turbo; bare.publisher = nil; bare.released = nil; bare.licence = nil; bare.summary = nil
        XCTAssertEqual(modelHelp(bare), "Whisper large-v3 turbo\nMIT\n0.8B parameters · native FP16")
        bare.license = "Some custom licence (see repository)"
        XCTAssertEqual(modelHelp(bare), "Whisper large-v3 turbo\n0.8B parameters · native FP16", "a free-form licence id is not shown")
    }

    /// One row's figures in full: what each is, then who measured it, where and when.
    @MainActor func testFigureTooltipsArePinned() throws {
        let c = try shippedController()
        c.benchmarks.figuresPending = false // as after the final build's measurement
        let table = ModelTable(controller: c)
        let ultra = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        c.select(ultra, tier: .t16); c.setMode(ultra, .fast) // 16 Fast
        let tips = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let by = "Measured by Vella · M5 Max · 2026-10-01"
        XCTAssertEqual(
            tips["WER"],
            "English word error rate on the v2 benchmark (240 min): lower is better\n" + by
                + "\nWord error rate by language: French 16.6%, German 8.7%, Polish 6.9%, Spanish 13.7%, Swedish 17.9%; mean 12.7%")
        XCTAssertEqual(tips["Format"], "Character error rate on the v2 benchmark (240 min), with case and punctuation kept: lower is better\n" + by)
        XCTAssertEqual(tips["Speed"], "Speed in × real time on the v2 quick benchmark (22.5 min), timed after loading: higher is faster\n" + by)
        XCTAssertEqual(tips["J / min"], "Whole-chip joules per audio minute on the v2 quick benchmark (22.5 min), net of loaded idle power: lower is better\n" + by)
        XCTAssertEqual(tips["Peak RAM"], "Peak memory of Vella's model worker on the v2 quick benchmark (22.5 min), loading included: lower is better\n" + by)
        // Another Mac (Toby's friend's M4 Pro): speed and energy lead with the M5 Max figure as a plain number; word
        // error, format errors and peak RAM read the same, since they depend on the precision, not the Mac.
        c.benchmarkHardware = Self.macs[1].hardware; c.gpu = Self.macs[1].gpu
        let other = Dictionary(table.tooltips(ultra).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(other["Speed"], "Not measured on your Mac. M5 Max: 507× real time.\n" + tips["Speed"]!)
        XCTAssertEqual(other["J / min"], "Not measured on your Mac. M5 Max: 4.6 J per audio minute.\n" + tips["J / min"]!)
        for column in ["WER", "Format", "Peak RAM"] { XCTAssertEqual(other[column], tips[column], column) }
        c.benchmarkHardware = Self.macs[0].hardware; c.gpu = Self.macs[0].gpu
        XCTAssertNil(tips["On disk"], "no On disk column: the Get pop-up and the action's tooltip give the download size")
        XCTAssertEqual(tips["Action"], "Not downloaded\nAsks, then downloads \(formatBytes(ultra.variants["BF16"]!.downloadBytes)) from Hugging Face; then loads it for dictation.")
        XCTAssertFalse(tips.keys.contains { $0.hasPrefix("Capability") }, "no Capabilities column (Toby, 30 Sep)")
        c.select(ultra, tier: .t4)
        XCTAssertEqual(
            table.tooltips(ultra).first { $0.0 == "Action" }?.1,
            "Not downloaded\nAsks, then downloads the BF16 (bfloat16) weights (\(formatBytes(ultra.variants["BF16"]!.downloadBytes))) it is made from; then loads it for dictation. The quantized weights are made in memory each time this precision loads."
        )
        // Parakeet v3's bf16 is converted from the fp32 download: the tooltip gives that download, never Zero kB
        // (lifecycle audit 2.1, A6).
        let v3 = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        let fetched = try XCTUnwrap(v3.acquisition(of: "8b")).download.downloadBytes
        XCTAssertGreaterThan(fetched, 0)
        for tier in [ModelTier.t16, .t8] {
            c.select(v3, tier: tier)
            let action = try XCTUnwrap(table.tooltips(v3).first { $0.0 == "Action" }?.1)
            XCTAssertTrue(action.contains(formatBytes(fetched)) && !action.contains("Zero"), action)
        }
        let nemotron = try XCTUnwrap(c.catalog.family("nemotron-3.5-streaming-0.6b"))
        XCTAssertNotNil(c.result(nemotron, "8b"), "corrected int8 cells supply measured shipping figures despite recommendation failure")
        XCTAssertTrue(speedHelp(nemotron.mode, c.result(nemotron, "8b"), suites: c.benchmarks.suites).hasPrefix("Streaming replay speed"))
        XCTAssertTrue(speedHelp(nemotron.mode, c.result(nemotron, "BF16"), suites: c.benchmarks.suites).hasPrefix("Streaming replay speed"))
    }

    /// Cloud rows: estimated, from which board and when; nothing to download; nothing runs on this Mac.
    @MainActor func testCloudRowTooltipsArePinned() throws {
        let c = try shippedController()
        let table = ModelTable(controller: c)
        let azure = try XCTUnwrap(c.references(.dictation).first { $0.id == "azure-speech" })
        // Scaled from the local models' measured WER: pending with them.
        c.benchmarks.figuresPending = true
        XCTAssertEqual(table.tooltips(azure).first { $0.0 == "WER" }?.1, figuresPendingHelp)
        c.benchmarks.figuresPending = false
        let tips = Dictionary(table.tooltips(azure).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tips["Model"], "Microsoft Azure Speech\nMicrosoft · Proprietary cloud API\nCloud speech-to-text shown for comparison only; Vella never sends audio to it")
        XCTAssertEqual(
            tips["WER"],
            "Estimated English word error rate on the v2 benchmark, range 11.3–13.3%: lower is better\n"
                + "Estimate scaled from the Hugging Face Open ASR Leaderboard · 2026-09-26")
        XCTAssertEqual(tips["Speed"], referenceNotApplicableHelp)
        XCTAssertNil(tips["On disk"])
    }

    /// The table's source uses AppKit tooltips only: SwiftUI `.help` never shows inside NSMenu tracking.
    func testModelsTableUsesNoSwiftUIHelp() throws {
        let source = Repository.root.appendingPathComponent("Sources/Vella/ModelsTable/ModelTable.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains(".help("), "use .appKitTooltip on a framed non-interactive cell")
        XCTAssertGreaterThanOrEqual(
            text.components(separatedBy: ".appKitTooltip(").count - 1, 18, "every cell with hover text (the Capabilities slots and the engine line are gone)")
    }
}
