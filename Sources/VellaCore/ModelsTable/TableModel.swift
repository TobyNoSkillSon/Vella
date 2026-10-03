import Foundation
import VellaWire

// The Models table's UI-free logic: sort keys and rows, the shown precision, deltas, formatters, the engine label
// and the hardware note.

// MARK: Table sort keys

public enum TableMetric: CaseIterable { case wer, format, speed, energy, memory, disk }

/// Published = downloadable from a pinned repository (derived precisions are made on this Mac and have none).
public func isPublished(_ family: ModelFamily, _ label: String) -> Bool {
    guard let v = family.variants[label], !v.isDerived else { return false }
    return !v.repository.isEmpty && v.downloadBytes > 0
}

/// The table's On disk for a precision in bytes: a published download's pinned size, a stored conversion's converted
/// size, else the measured size; nil =
/// `—`. Unlike `ModelFamily.diskBytes`, a derived precision never borrows its source's size.
public func tableDiskBytes(_ family: ModelFamily, _ label: String, _ result: PrecisionResult?) -> Int64? {
    if isPublished(family, label), let v = family.variants[label] { return v.downloadBytes }
    // A conversion stored at Get (Parakeet v3's bf16 from fp32) has files of its own: its converted size.
    if let v = family.variants[label], v.isStored, let bytes = family.diskBytes(label) { return bytes }
    return result?.disk_mb.map { Int64(($0 * 1_000_000).rounded()) }
}

/// One precision's value for a column, oriented so lower is better (speed negated). Nil when not measured.
public func metricValue(_ metric: TableMetric, family: ModelFamily, label: String, result: PrecisionResult?) -> Double? {
    switch metric {
    case .wer: return result?.wer
    case .format: return result?.format
    case .speed: return result?.speed_x.map { -$0 }
    case .energy: return result?.j_per_min
    case .memory: return result?.memory_mb
    case .disk: return tableDiskBytes(family, label, result).map(Double.init)
    }
}

/// A row's sort key: the model's best value for the column across all its offered precisions, so a row never moves
/// when its selected precision changes. Lower is better (speed negated); nil when nothing is measured.
public func tableSortKey(_ metric: TableMetric, family: ModelFamily, benchmark: FamilyBenchmark?) -> Double? {
    precisionOptions(family).compactMap { metricValue(metric, family: family, label: $0, result: benchmark?.result($0)) }.min()
}

/// Rows of one section sorted by a column's best value; ascending = best first. Rows with nothing measured stay last
/// in either direction; ties keep catalog order. While the file's figures are pending (`figuresPending`) no row has a
/// value: the order is the catalog's, so hidden figures never show through the order.
public func sortedFamilies(_ families: [ModelFamily], by metric: TableMetric?, ascending: Bool, benchmarks: BenchmarkFile) -> [ModelFamily] {
    guard let metric else { return families.sorted { ascending ? $0.name < $1.name : $0.name > $1.name } }
    let keyed = families.enumerated().map {
        ($0.offset, $0.element, benchmarks.figuresPending ? nil : tableSortKey(metric, family: $0.element, benchmark: benchmarks.models[$0.element.id]))
    }
    return keyed.sorted { a, b in
        switch (a.2, b.2) {
        case let (x?, y?): return x == y ? a.0 < b.0 : (ascending ? x < y : x > y)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.0 < b.0
        }
    }.map(\.1)
}

/// One row of a table section: a local model family or a cloud reference.
public enum ModelTableRow: Identifiable, Equatable {
    case family(ModelFamily)
    case reference(ReferenceEntry)
    public var id: String {
        switch self {
        case .family(let f): return f.id
        case .reference(let r): return "reference:" + r.id
        }
    }
    public var name: String {
        switch self {
        case .family(let f): return f.name
        case .reference(let r): return r.name
        }
    }
}

/// A reference row's sort key: its estimated WER for the WER column; nothing else applies (it sorts last there).
public func referenceSortKey(_ metric: TableMetric, _ reference: ReferenceEntry) -> Double? { metric == .wer ? reference.wer : nil }

/// Families and reference rows of one section sorted together, by the same rule as `sortedFamilies`: best value first
/// when ascending, rows without a value last in either direction, ties in input order (families first).
public func sortedRows(
    _ families: [ModelFamily], references: [ReferenceEntry], by metric: TableMetric?, ascending: Bool,
    benchmarks: BenchmarkFile
) -> [ModelTableRow] {
    let rows = families.map(ModelTableRow.family) + references.map(ModelTableRow.reference)
    guard let metric else { return rows.sorted { ascending ? $0.name < $1.name : $0.name > $1.name } }
    let keyed = rows.enumerated().map { index, row -> (Int, ModelTableRow, Double?) in
        if benchmarks.figuresPending { return (index, row, nil) }
        switch row {
        case .family(let f): return (index, row, tableSortKey(metric, family: f, benchmark: benchmarks.models[f.id]))
        case .reference(let r): return (index, row, referenceSortKey(metric, r))
        }
    }
    return keyed.sorted { a, b in
        switch (a.2, b.2) {
        case let (x?, y?): return x == y ? a.0 < b.0 : (ascending ? x < y : x > y)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.0 < b.0
        }
    }.map(\.1)
}

/// `~13%`: a reference's estimated WER, rounded to whole percent because it is an estimate.
public func formatEstimatedErrorRate(_ percent: Double?) -> String? { percent.map { String(format: "~%.0f%%", $0) } }

/// Earlier versions stored the native precision as `native`.
public let nativeSelection = "native"
public func effectivePrecision(stored: String, native: String) -> String { stored == nativeSelection ? native : stored }

/// The precision a row shows: ONE state for selected and loaded (Toby, 26 Sep 2026). A segment the user picked is a
/// transient preview (until Load/Reload; closing the menu discards it); otherwise a loaded model shows its loaded
/// precision; an unloaded one the precision it was last loaded at, else the recommended one, else native, else the
/// highest offered. Nothing stored can override a loaded model.
public func shownPrecision(preview: String? = nil, loaded: String?, lastLoaded: String?, recommended: String?, family: ModelFamily) -> String {
    let options = precisionOptions(family)
    for candidate in [preview, loaded, lastLoaded, recommended] {
        if let label = candidate.map({ effectivePrecision(stored: $0, native: family.native) }), options.contains(label) { return label }
    }
    if options.contains(family.native) { return family.native }
    return options.first ?? family.native
}

/// What a row's button does: Get (download), Load, Unload, or the green Reload of a previewed other precision.
public enum LoadAction: Equatable { case get, load, unload, reload }

// MARK: Deltas vs the recommended precision

public enum DeltaTone: Equatable { case better, worse, neutral }
public struct Delta: Equatable {
    public var text: String
    public var tone: DeltaTone
    public init(_ text: String, _ tone: DeltaTone) { self.text = text; self.tone = tone }
}
private let minus = "\u{2212}"
private func signed(_ value: Double, _ format: String) -> String { (value < 0 ? minus : "+") + String(format: format, abs(value)) }

/// An error rate in percent (WER or format CER) → `+0.4 pt`; lower is better. Under 0.05 points reads `same`.
public func errorRateDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base else { return nil }
    let points = value - base
    if abs(points) < 0.05 { return Delta("same", .neutral) }
    return Delta(signed(points, "%.1f") + " pt", points < 0 ? .better : .worse)
}

/// Speed in × real time → `35% faster` / `20% slower`; at 2× or above, `2.4× faster`. Under 1 % reads `same`.
public func speedDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base, value > 0, base > 0 else { return nil }
    let change = value / base - 1
    if abs(change) < 0.01 { return Delta("same", .neutral) }
    if value / base >= 2 { return Delta(String(format: "%.1f× faster", value / base), .better) }
    return Delta(String(format: "%.0f%%", abs(change) * 100) + (change > 0 ? " faster" : " slower"), change > 0 ? .better : .worse)
}

/// Energy per audio minute → `20% less` / `15% more`, always a percentage. Under 0.5 % reads `same`.
public func energyDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base, value >= 0, base > 0 else { return nil }
    let change = value / base - 1
    if abs(change) < 0.005 { return Delta("same", .neutral) }
    return Delta(String(format: "%.0f%%", abs(change) * 100) + (change < 0 ? " less" : " more"), change < 0 ? .better : .worse)
}

/// Memory → `40% less` / `80% more`, like energy.
public func memoryDelta(_ value: Double?, base: Double?) -> Delta? { energyDelta(value, base: base) }

// MARK: Formatters (en_US everywhere)

private let enUS = Locale(identifier: "en_US")
public func formatBytes(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(enUS)) }
/// `5.12` → `5.1%`.
public func formatErrorRate(_ percent: Double?) -> String? { percent.map { String(format: "%.1f%%", $0) } }
/// `512.3` → `512×`; `18.4` → `18.4×` under 100.
public func formatSpeed(_ x: Double?) -> String? {
    guard let x else { return nil }
    return x >= 100 ? String(format: "%.0f×", x) : String(format: "%.1f×", x)
}
/// Joules per audio minute: `1.9 J` under 10, else whole joules.
public func formatEnergy(_ j: Double?) -> String? {
    guard let j else { return nil }
    return j < 10 ? String(format: "%.1f J", j) : String(format: "%.0f J", j)
}
/// Megabytes → `782 MB` / `1.34 GB`, like On disk.
public func formatMemory(_ mb: Double?) -> String? { mb.map { formatBytes(Int64(($0 * 1_000_000).rounded())) } }
/// Under ~20× real time a model is very slow for dictation.
public let slowSpeedFloor = 20.0

// MARK: Engine label

/// The loaded recipe’s label, with its chip on the optimized path.
/// With the loaded selection: `Standard` on stock MLX as chosen, `Optimized Exact \u{00b7} M5 Max` / `Optimized Fast \u{00b7} M5 Max`.
public func engineLabel(engine: String?, chip: String?, selection: ModelSelection? = nil) -> String {
    guard engine == Engine.optimized.rawValue else { return selection?.path == .standard ? "Standard" : "MLX" }
    let name = selection.map { $0.mode == .exact ? "Optimized Exact" : "Optimized Fast" } ?? "Optimized"
    guard let chip = displayChip(chip) else { return name }
    return name + " \u{00b7} " + chip
}
/// Tooltip for the engine label: which path answers, the optimized components as the worker reports them
/// (component → active) and, off the optimized path, the worker's reason. Never invents a cause.
public func engineHelp(engine: String?, reason: String?, optimizations: [String: Bool]?, chip: String?, precision: String, stock baseline: String? = nil) -> String {
    var lines: [String] = []
    let active = (optimizations ?? [:]).filter(\.value).keys.sorted()
    let stock = (optimizations ?? [:]).filter { !$0.value }.keys.sorted()
    let why = reason.map { " Why: \($0)." } ?? ""
    if engine == Engine.optimized.rawValue {
        lines.append("Optimized path, self-tested at load on this Mac" + (displayChip(chip).map { " (\($0))" } ?? "") + ".")
        if !active.isEmpty { lines.append("Optimized: " + active.joined(separator: ", ") + (stock.isEmpty ? "." : "; stock: " + stock.joined(separator: ", ") + ".")) }
    } else if !active.isEmpty {
        lines.append("Partly optimized \u{2014} optimized: " + active.joined(separator: ", ") + "; stock: " + (stock.isEmpty ? "none" : stock.joined(separator: ", ")) + "." + why)
    } else {
        lines.append("Stock MLX path: the same model without Vella's optimizations; slower." + why)
    }
    lines.append("Precision: \(precisionInProse(precision))")
    if let baseline { lines.append(baseline) } // stockLine(_:) of the loaded precision
    return lines.joined(separator: "\n")
}

// MARK: Hardware note

/// `Apple M5 Max` → `M5 Max`. Nil when empty.
public func displayChip(_ chip: String?) -> String? {
    guard var c = chip?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
    if c.hasPrefix("Apple ") { c = String(c.dropFirst(6)) }
    return c.isEmpty ? nil : c
}
/// `M5` in `M5 Max`, `Apple M5 Pro` or `M5`.
public func chipGeneration(_ chip: String?) -> String? {
    guard let chip else { return nil }
    return chip.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).first { token in
        token.count > 1 && token.first == "M" && token.dropFirst().allSatisfy(\.isNumber)
    }
}
/// The chip the numbers were measured on: the most common chip among the results' `hardware`, else the file's.
public func measurementChip(_ file: BenchmarkFile) -> String? {
    var counts: [String: Int] = [:]
    for model in file.models.values {
        for result in model.precisions.values {
            guard let hardware = result.hardware, let chip = displayChip(hardware.split(separator: ",").first.map(String.init)),
                chipGeneration(chip) != nil
            else { continue }
            counts[chip, default: 0] += 1
        }
    }
    if let top = counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first { return top.key }
    return file.hardware.flatMap { displayChip($0.split(separator: ",").first.map(String.init)) }.flatMap { chipGeneration($0) != nil ? $0 : nil }
}
/// The footer note for every Mac outside the measured chip and GPU-core configuration.
public func hardwareNote(thisChip: String?, measuredOn: String?, gpuCores: Int? = nil) -> (text: String, help: String)? {
    let hardware = BenchmarkHardware(chip: thisChip, gpuCores: gpuCores)
    guard let help = hardware.caveat else { return nil }
    return ("Measured on M5 Max · J / min not known", help)
}

// MARK: Runtime state the table shows

/// A loaded model as the table needs it (the worker status reduced to what is drawn).
public struct LoadedFamily: Equatable {
    public var precision: String
    public var engine: String?
    public var engineReason: String?
    public var optimizations: [String: Bool]?
    public var residency: String?
    /// What the worker runs (its status `recipe`); nil = not reported (an older worker): the table reads engine
    /// `optimized` as Optimized · Fast and anything else as Standard (`runningSelection`).
    public var selection: ModelSelection?
    public init(
        precision: String, engine: String? = nil, engineReason: String? = nil, optimizations: [String: Bool]? = nil, residency: String? = nil,
        selection: ModelSelection? = nil
    ) {
        self.precision = precision; self.engine = engine; self.engineReason = engineReason; self.optimizations = optimizations; self.residency = residency
        self.selection = selection
    }
}

public struct TableRefusal: Equatable {
    public var message: String
    public var at: Double
    public init(message: String, at: Double) { self.message = message; self.at = at }
}

/// The footer's left notice: the app's own error, the worker's, else a memory refusal from the last 10 minutes.
public func footerNotice(lastError: String?, workerError: String?, refusal: TableRefusal?, now: Double) -> String? {
    if let lastError { return lastError }
    if let workerError { return workerError }
    if let refusal, now - refusal.at < 600 { return refusal.message }
    return nil
}

/// Everything the Models table draws from the runtime, keyed by catalog family id.
public struct TableRuntime: Equatable {
    public var loaded: [String: LoadedFamily]
    public var loading: String?
    public var chip: String?
    public var workerError: String?
    public var refusal: TableRefusal?
    /// False while the runtime cannot take load requests (buttons disable).
    public var available: Bool
    public init(
        loaded: [String: LoadedFamily] = [:], loading: String? = nil, chip: String? = nil, workerError: String? = nil,
        refusal: TableRefusal? = nil, available: Bool = true
    ) {
        self.loaded = loaded; self.loading = loading; self.chip = chip; self.workerError = workerError; self.refusal = refusal; self.available = available
    }
}
