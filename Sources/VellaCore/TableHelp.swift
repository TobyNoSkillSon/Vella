import Foundation

// Hover text of the Models table, kept here so tests can pin it. Family tooltip format
// (VFamily/research/hover-contract-2026-09-28.md): short lines joined with "\n", no trailing periods on fragments.
// A model name gets at most 5 lines (name; publisher, year · licence; summary; size · native precision; loaded state),
// a number two (what it is and which way is better; who measured or estimated it, on which Mac, when).
// Unknown facts are omitted, never "not stated". No repository ids, hashes, paths, URLs or internal names.

public let notMeasuredHelp = "Not measured at this precision"

private let enUS = Locale(identifier: "en_US")
/// `pl` → `Polish`; an unknown code stays as it is.
public func languageDisplayName(_ code: String) -> String { enUS.localizedString(forLanguageCode: code) ?? code }

/// A catalog licence id (the upstream card's metadata) as its display name; nil for a free-form id.
public func licenceDisplayName(_ id: String) -> String? {
    switch id.lowercased() {
    case "cc-by-4.0": return "CC BY 4.0"
    case "apache-2.0": return "Apache-2.0"
    case "mit": return "MIT"
    default: return nil
    }
}

/// The model name's tooltip: name; publisher, year · licence; summary; size · native precision; loaded state.
public func modelHelp(_ f: ModelFamily, loaded: LoadedFamily? = nil) -> String {
    var lines = [f.name]
    let who = [f.publisher, f.released.map { String($0) }].compactMap { $0 }.joined(separator: ", ")
    let origin = [who.isEmpty ? nil : who, f.licence ?? licenceDisplayName(f.license)].compactMap { $0 }.joined(separator: " \u{00b7} ")
    if !origin.isEmpty { lines.append(origin) }
    if let summary = f.summary, !summary.isEmpty { lines.append(summary) }
    lines.append((f.params.isEmpty ? "" : "\(f.params) parameters \u{00b7} ") + "native \(precisionInProse(f.native))")
    if let loaded {
        let how = loaded.residency == "on_demand" ? ", on demand" : loaded.residency == "manual" ? ", kept hot" : ""
        lines.append("Loaded at \(precisionInProse(loaded.precision))" + how)
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

/// Line 1 `<what> on <suite>, <detail>: <which way is better>`, line 2 the provenance, and for Speed, J / min and
/// Memory a third line with the stock-MLX baseline when one was measured (`stockLine`).
private func figure(_ what: String, on suite: String?, _ detail: String? = nil, better: String, _ r: PrecisionResult, stock: Bool = false) -> String {
    what + (suite.map { " on \($0)" } ?? "") + (detail.map { ", \($0)" } ?? "") + ": \(better)\n" + measuredProvenance(r)
        + ((stock ? stockLine(r) : nil).map { "\n" + $0 } ?? "")
}

/// The stock-MLX baseline in one line: `Stock MLX on any Mac: 58× · 95 J · 2.4 GB` (speed, joules per audio minute, peak
/// memory; a figure that was not measured is left out). Nil when the precision has no stock baseline.
public func stockLine(_ r: PrecisionResult?) -> String? {
    guard let s = r?.stock else { return nil }
    let parts = [formatSpeed(s.speed_x), formatEnergy(s.j_per_min), formatMemory(s.memory_mb)].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    return "Stock MLX on any Mac: " + parts.joined(separator: " \u{00b7} ") + (s.note == nil ? "" : " (remeasure pending)")
}

public func werHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.wer != nil else { return notMeasuredHelp }
    return figure("English word error rate", on: suiteDescription(r.suite, suites: suites), better: "lower is better", r)
}

public func formatHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.format != nil else { return notMeasuredHelp }
    return figure("Character error rate", on: suiteDescription(r.suite, suites: suites), "with case and punctuation kept", better: "lower is better", r)
}

public func speedHelp(_ mode: RecognitionMode, _ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, let x = r.speed_x else { return notMeasuredHelp }
    let suite = suites?[performanceSuite] != nil ? suiteDescription(performanceSuite, suites: suites) : nil
    if mode == .streaming {
        return figure("Streaming replay speed in \u{00d7} real time", on: suite, "not microphone-to-text latency", better: "higher is faster", r, stock: true)
    }
    return figure("Speed in \u{00d7} real time", on: suite, "timed after loading",
                  better: "higher is faster" + (x < slowSpeedFloor ? "; under 20\u{00d7} is very slow for dictation" : ""), r, stock: true)
}

public func energyHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.j_per_min != nil else { return notMeasuredHelp }
    let suite = suites?[performanceSuite] != nil ? suiteDescription(performanceSuite, suites: suites) : nil
    return figure("Whole-chip joules per audio minute", on: suite, "net of loaded idle power", better: "lower is better", r, stock: true)
}

public func memoryHelp(_ r: PrecisionResult?, suites: [String: SuiteInfo]?) -> String {
    guard let r, r.memory_mb != nil else { return notMeasuredHelp }
    let suite = suites?[performanceSuite] != nil ? suiteDescription(performanceSuite, suites: suites) : nil
    return figure("Peak memory of Vella's model worker", on: suite, "loading included", better: "lower is better", r, stock: true)
}

/// The Languages cell: the languages the model transcribes, then (when measured) the word error rate per benchmark
/// language at the selected precision and who measured it. Nil when the catalog lists no languages.
public func languagesHelp(_ f: ModelFamily, _ r: PrecisionResult?) -> String? {
    guard !f.languages.isEmpty else { return nil }
    let names = f.languages.map(languageDisplayName)
    var lines = [names.count == 1 ? names[0] : "\(names.count) languages: " + names.joined(separator: ", ")]
    if let r, let by = r.multilingual?.by_language, !by.isEmpty {
        let parts = by.map { (languageDisplayName($0.key), $0.value) }.sorted { $0.0 < $1.0 }.map { "\($0.0) \(String(format: "%.1f%%", $0.1))" }
        let mean = r.multilingual?.mean.map { String(format: "; mean %.1f%%", $0) } ?? ""
        lines.append("Word error rate by language: " + parts.joined(separator: ", ") + mean)
        lines.append(measuredProvenance(r))
    }
    return lines.joined(separator: "\n")
}

/// The On disk cell. `derivedSource`: the precision it is made from on this Mac; `sizeKnown`: the cell shows a size
/// (a derived precision without one gets no second line: nothing of its own is stored to size).
public func diskHelp(_ f: ModelFamily, _ precision: String, installed: Bool, derivedSource: String?, sizeKnown: Bool) -> String {
    guard let v = f.variants[precision] else { return "No download at this precision" }
    if let source = derivedSource {
        let name = precisionInProse(source)
        return "Made on this Mac at load from the \(name) weights; nothing extra is stored"
            + (sizeKnown ? "\nThe size shown is those \(name) files" : "")
    }
    return installed ? "Downloaded from Hugging Face\nThe size of the pinned files"
        : "Not downloaded\nDownloads \(formatBytes(v.downloadBytes)) from Hugging Face after you confirm"
}

// MARK: Cloud reference rows

public let referenceNotApplicableHelp = "Not applicable: a cloud API runs on the provider's servers"
public let referenceFormatHelp = "Not estimated: no public case-and-punctuation figure to scale from"
public let referenceDiskHelp = "Cloud service: nothing to download\nVella never sends audio to it"

public func referenceModelHelp(_ r: ReferenceEntry) -> String {
    [r.name, (r.provider.map { "\($0) \u{00b7} " } ?? "") + "Proprietary cloud API",
     "Cloud speech-to-text shown for comparison only; Vella never sends audio to it"].joined(separator: "\n")
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
