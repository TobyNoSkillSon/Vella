import Foundation
import VellaWire

// Hover text of the Models table, kept here so tests can pin it. Family tooltip format
// (VFamily/research/hover-contract-2026-09-28.md): short lines joined with "\n", no trailing periods on fragments.
// A model name gets at most 5 lines (name; publisher, year · licence; summary; size · native precision; loaded state),
// a number two (what it is and which way is better; who measured or estimated it, on which Mac, when).
// Unknown facts are omitted, never "not stated". No repository ids, hashes, paths or internal names;
// the CC BY licence URL is included for the Parakeet models.

public let notMeasuredHelp = "Not measured at this precision"

private let enUS = Locale(identifier: "en_US")
/// `pl` → `Polish`; an unknown code stays as it is.
public func languageDisplayName(_ code: String) -> String { enUS.localizedString(forLanguageCode: code) ?? code }

/// A catalog licence id (the upstream card's metadata) as its display name; nil for a free-form id.
public func licenceDisplayName(_ id: String) -> String? {
    switch id.lowercased() {
    case "cc-by-4.0": return "CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)"
    case "apache-2.0": return "Apache-2.0"
    case "mit": return "MIT"
    default: return nil
    }
}

/// The model name's tooltip: name; publisher, year · licence; summary; size · native precision; loaded state.
public func modelHelp(_ f: ModelFamily, loaded: LoadedFamily? = nil) -> String {
    var lines = [f.name]
    let who = [f.publisher, f.released.map { String($0) }].compactMap { $0 }.joined(separator: ", ")
    let licence =
        f.license == "cc-by-4.0"
        ? licenceDisplayName(f.license)
        : f.id == "nemotron-3.5-streaming-0.6b"
            ? "OpenMDW-1.1 upstream; MLX card: NVIDIA Open Model License"
            : f.licence ?? licenceDisplayName(f.license)
    let origin = [who.isEmpty ? nil : who, licence].compactMap { $0 }.joined(separator: " \u{00b7} ")
    if !origin.isEmpty { lines.append(origin) }
    if let summary = f.summary, !summary.isEmpty { lines.append(summary) }
    lines.append((f.params.isEmpty ? "" : "\(f.params) parameters \u{00b7} ") + "native \(precisionInProse(f.native))")
    if let loaded {
        let how = loaded.residency == "on_demand" ? ", on demand" : loaded.residency == "manual" ? ", kept hot" : ""
        lines.append("Loaded at \(humanDType(precision: loaded.precision, familyID: f.id))" + how)
    }
    return lines.joined(separator: "\n")
}

/// The second line of every local figure: "Measured by Vella · M5 Max · 2026-09-28".
public func measuredProvenance(_ r: PrecisionResult) -> String {
    let chip = displayChip(r.hardware?.split(separator: ",").first.map(String.init))
    return ["Measured by Vella", chip, r.date].compactMap { $0 }.joined(separator: " \u{00b7} ")
}

/// `the v2 benchmark (240 min)`, `the v2 quick benchmark (22.5 min)`; nil without a suite.
public func suiteDescription(_ key: String?, suites: [String: SuiteInfo]?) -> String? {
    guard let key, !key.isEmpty else { return nil }
    let name = "the \(key.replacingOccurrences(of: "-", with: " ")) benchmark"
    guard let minutes = suites?[key]?.audio_min, minutes > 0 else { return name }
    let text = minutes >= 100 ? String(format: "%.0f", minutes) : String(format: "%g", (minutes * 10).rounded() / 10)
    return "\(name) (\(text) min)"
}
/// Speed, energy and memory come from one run of the quick suite per precision; accuracy from the row's own suite.
public let performanceSuite = "v2-quick"

/// Line 1 `<what> on <suite>, <detail>: <which way is better>`, line 2 the provenance.
private func figure(_ what: String, on suite: String?, _ detail: String? = nil, better: String, _ r: PrecisionResult) -> String {
    what + (suite.map { " on \($0)" } ?? "") + (detail.map { ", \($0)" } ?? "") + ": \(better)\n" + measuredProvenance(r)
}

public func werHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.wer != nil else { return notMeasuredHelp }
    return figure("English word error rate", on: suiteDescription(r.suite, suites: suites), better: "lower is better", r)
        + (languageWERLine(r).map { "\n" + $0 } ?? "")
}

/// `Word error rate by language: French 16.1%, German 8.7%; mean 12.9%` when the multilingual suite was measured.
public func languageWERLine(_ r: PrecisionResult?) -> String? {
    guard let by = r?.multilingual?.by_language, !by.isEmpty else { return nil }
    let parts = by.map { (languageDisplayName($0.key), $0.value) }.sorted { $0.0 < $1.0 }.map { "\($0.0) \(String(format: "%.1f%%", $0.1))" }
    return "Word error rate by language: " + parts.joined(separator: ", ") + (r?.multilingual?.mean.map { String(format: "; mean %.1f%%", $0) } ?? "")
}

public func formatHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.format != nil else { return notMeasuredHelp }
    return figure("Character error rate", on: suiteDescription(r.suite, suites: suites), "with case and punctuation kept", better: "lower is better", r)
}

public func speedHelp(_ mode: RecognitionMode, _ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, let x = r.speed_x else { return notMeasuredHelp }
    let suite = suites?[performanceSuite] != nil ? suiteDescription(performanceSuite, suites: suites) : nil
    if mode == .streaming {
        return figure("Streaming replay speed in \u{00d7} real time", on: suite, "not microphone-to-text latency", better: "higher is faster", r)
    }
    return figure(
        "Speed in \u{00d7} real time", on: suite, "timed after loading",
        better: "higher is faster" + (x < slowSpeedFloor ? "; under 20\u{00d7} is very slow for dictation" : ""), r)
}

public func energyHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.j_per_min != nil else { return notMeasuredHelp }
    let suite = suites?[performanceSuite] != nil ? suiteDescription(performanceSuite, suites: suites) : nil
    return figure("Whole-chip joules per audio minute", on: suite, "net of loaded idle power", better: "lower is better", r)
}

public func memoryHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.memory_mb != nil else { return notMeasuredHelp }
    let suite = suites?[performanceSuite] != nil ? suiteDescription(performanceSuite, suites: suites) : nil
    return figure("Peak memory of Vella's model worker", on: suite, "loading included", better: "lower is better", r)
}

// MARK: Cloud reference rows

public let referenceNotApplicableHelp = "Not applicable: a cloud API runs on the provider's servers"
public let referenceFormatHelp = "Not estimated: no public case-and-punctuation figure to scale from"

public func referenceModelHelp(_ r: ReferenceEntry) -> String {
    [
        r.name, (r.provider.map { "\($0) \u{00b7} " } ?? "") + "Proprietary cloud API",
        "Cloud speech-to-text shown for comparison only; Vella never sends audio to it"
    ].joined(separator: "\n")
}

/// The board an estimate is scaled from, by name only: `source` up to its first comma or parenthesis
/// (`Hugging Face Open ASR Leaderboard, English short-form average … (https://…)` → the board's name).
public func referenceSourceName(_ source: String?) -> String? {
    guard let source else { return nil }
    let name = source.prefix { $0 != "," && $0 != "(" && $0 != ";" }.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

public func referenceWERTooltip(_ r: ReferenceEntry) -> String {
    guard r.wer != nil else { return "Not estimated" }
    var what = "Estimated English word error rate on the v2 benchmark"
    if let range = r.range, range.count == 2 { what += String(format: ", range %.1f\u{2013}%.1f%%", range[0], range[1]) }
    let from = referenceSourceName(r.source).map { "Estimate scaled from the \($0)" } ?? "Estimate, not measured by Vella"
    return what + ": lower is better\n" + [from, r.date].compactMap { $0 }.joined(separator: " \u{00b7} ")
}

// MARK: Precision cells (16 / 8 / 4 in the shown Exact/Fast position)

/// Line 1 of a tier cell's tooltip: the flavour of the weights. `bf16, as published`; `bf16, converted once from the
/// published fp32`; `8-bit weights throughout (affine-8 g64)`; a per-layer recipe `8-bit decoder, 16-bit encoder (affine-8 g64)`.
public func tierFlavour(_ family: ModelFamily, tier: ModelTier, cell: BenchmarkCell?) -> String {
    let layers = cell?.recipe.layers ?? [:]
    if tier == .t16 {
        let format = layers["all"] ?? (modelTier(ofPrecision: family.native) == .t16 ? family.native.lowercased() : "bf16")
        if let source = cell?.recipe.converted_from ?? (modelTier(ofPrecision: family.native) == nil ? family.native.lowercased() : nil) {
            return "\(format), converted once from the published \(source)"
        }
        return "\(format), as published"
    }
    let affine = "affine-\(tier.rawValue) g64"
    let groups = layers.filter { $0.key != "all" }
    if groups.isEmpty { return "\(tier.rawValue)-bit weights throughout (\(affine))" }
    // Per-layer recipe: quantized groups first, then the 16-bit ones, each as "<bits> <group>".
    func bits(_ format: String) -> String { format.hasPrefix("affine-") ? String(format.dropFirst(7).prefix { $0.isNumber }) + "-bit" : "16-bit" }
    let parts = groups.sorted { ($0.value.hasPrefix("affine") ? 0 : 1, $0.key) < ($1.value.hasPrefix("affine") ? 0 : 1, $1.key) }
        .map { "\(bits($0.value)) \($0.key == "model.encoder" ? "encoder" : $0.key)" }
    return parts.joined(separator: ", ") + " (\(affine))"
}

/// `28 Sep` from `2026-09-28`; nil when not a date.
public func shortDate(_ iso: String?) -> String? {
    guard let iso, iso.count >= 10 else { return nil }
    let parts = iso.prefix(10).split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month) else { return nil }
    let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return "\(day) \(names[month - 1])"
}

/// `M5 Max, 28 Sep`: where and when a cell was measured.
public func cellBasis(_ cell: BenchmarkCell?) -> String? {
    let chip = displayChip(cell?.measured?.hardware?.split(separator: ",").first.map(String.init))
    let parts = [chip, shortDate(cell?.measured?.date)].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

/// Line 2 of a tier cell's tooltip: the change against the 16-bit cell of the same switch position (`baseName` is its
/// dtype, `bf16` or `fp16`) with its basis, `vs bf16: Speed: 2.0× faster · Energy: 35% less · WER +0.05 pt · M5 Max, 28 Sep`.
/// The 16-bit cell itself is the reference. `hardwareDeltas` false (a Mac other than the measured one): speed and energy
/// are left out, since another Mac's change is not this one's (Toby, 15 Oct: no relative claims there); WER stays.
public func tierDeltaLine(_ cell: BenchmarkCell?, base: BenchmarkCell?, isBase: Bool, baseName: String = "16", hardwareDeltas: Bool = true) -> String {
    guard let cell, !cell.isPending else { return unmeasuredReasonHelp(cell) }
    let basis = cellBasis(cell)
    if isBase { return (["Reference for the deltas", basis].compactMap { $0 }).joined(separator: " \u{00b7} ") }
    guard let base, !base.isPending else {
        return (["No \(baseName) measurement to compare with yet", basis].compactMap { $0 }).joined(separator: " \u{00b7} ")
    }
    var parts: [String] = []
    let r = cell.result, b = base.result
    if hardwareDeltas, let delta = speedDelta(r.speed_x, base: b.speed_x) { parts.append("Speed: " + delta.text) }
    if hardwareDeltas, let delta = energyDelta(r.j_per_min, base: b.j_per_min) { parts.append("Energy: " + delta.text) }
    if let x = r.wer, let y = b.wer {
        let d = x - y
        parts.append(abs(d) < 0.005 ? "same WER" : "WER " + (d < 0 ? "\u{2212}" : "+") + String(format: "%.2f pt", abs(d)))
    }
    return "vs \(baseName): " + (parts + [basis].compactMap { $0 }).joined(separator: " \u{00b7} ")
}

/// A tier cell's tooltip: flavour; delta vs the 16-bit cell of the same switch position with its basis; for a cell that
/// loses anything against 16, the loss (`cellLoss`). With `figuresPending` (benchmarks.json `figures_pending`) the
/// flavour only: no delta and no loss until the final build is measured.
public func tierCellHelp(
    _ family: ModelFamily, _ benchmark: FamilyBenchmark?, tier: ModelTier, mode: OptimizedMode, figuresPending: Bool = false, hardwareDeltas: Bool = true
) -> String {
    let selection = ModelSelection(tier: tier, mode: mode)
    let cell = benchmarkCell(benchmark, selection)
    var lines = [tierFlavour(family, tier: tier, cell: cell)]
    if figuresPending { return lines[0] }
    let baseName = tierDTypeLabel(family, .t16)
    let base = benchmarkCell(benchmark, ModelSelection(tier: .t16, mode: mode))
    lines.append(tierDeltaLine(cell, base: base, isBase: tier == .t16, baseName: baseName, hardwareDeltas: hardwareDeltas))
    let loss = cellLoss(benchmark, tier: tier, segment: selection.segmentKey)
    if !loss.isEmpty { lines.append("Loss vs \(baseName): " + loss.joined(separator: ", ")) }
    return lines.joined(separator: "\n")
}

/// What the shown cell loses against 16, as its tooltip's `Loss vs …` line and the API's cell `loss` list state it,
/// from that cell's own gate: a failed presence verdict and failed (or borderline) gate checks, lost clips first,
/// which averages hide (`plainLossItems`). A cell without a gate of its own states its tier's losses. Empty for a cell
/// that loses nothing measurable; a `not_gated` verdict is not a loss.
public func cellLoss(_ benchmark: FamilyBenchmark?, tier: ModelTier, segment: Recipe) -> [String] {
    let cell = benchmarkCell(
        benchmark,
        ModelSelection(tier: tier, path: segment == .standard ? .standard : .optimized, mode: segment == .optimized_fast ? .fast : .exact))
    guard let gate = cell?.gate else {
        guard let t = benchmark?.tiers[tier], t.gate.status != .pass else { return [] }
        return t.gate.loss
    }
    var reasons = gate.presence?.offered == false ? gate.presence?.reasons ?? [] : []
    if gate.status == .fail || gate.status == .borderline { reasons += gate.reasons }
    return plainLossItems(reasons)
}

// MARK: Greyed cells and pending figures (table pass v3, 30 Sep)

/// Every figure cell's tooltip while benchmarks.json says `figures_pending` (its figures predate the final build).
public let figuresPendingHelp = "Figures pending the final measurement"
public let unmeasuredCellHelp = "Not measured yet"
public func unmeasuredReasonHelp(_ cell: BenchmarkCell?) -> String {
    guard let reason = cell?.notMeasuredReason, !reason.isEmpty else { return unmeasuredCellHelp }
    return unmeasuredCellHelp + ": " + reason
}
public let modelDeletionBusyHelp = "Finish dictation, downloading or calibration before deleting a model."

/// A greyed Precision cell of a tier the catalog does not offer. A failed presence verdict never greys a cell (6 Oct):
/// the offered cell states it as its loss.
public func tierAbsentHelp(_ benchmark: FamilyBenchmark?, tier: ModelTier) -> String { "Not offered for this model" }
/// A greyed cell under Exact whose tier has only a Fast recipe (family coupling rule).
public func exactRecipeMissingHelp(_ dtype: String) -> String { "No Exact recipe at \(dtype); Fast offers it" }
