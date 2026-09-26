import Foundation

// Models catalog (Resources/models.json v2), measured numbers (Resources/benchmarks.json v1) and the Models table's
// UI-free logic: precision options, the recommended precision, deltas, formatters and the hardware note.
// Rule and formatter shapes follow the Verdict-family reference (Verdict 95ddba5, Sources/VerdictCore/Core.swift).

// MARK: Catalog (models.json v2)

/// One precision of a model family. `id` is the variant's stable install id (the key in models-installed.json);
/// older catalogs used it as the row id.
///
/// A variant is either downloaded (pinned `repository`/`revision`/`downloadBytes`) or derived locally from another
/// precision of the same family (`derivedFrom` = source label): a cast (`dtype`, e.g. `bfloat16`) or an affine
/// quantization (`bits` 4/8, `groupSize`). A derived variant downloads nothing itself: repository and revision are
/// empty and downloadBytes 0; see DerivedModels.swift for its source, disk size and the worker manifest.
public struct CatalogVariant: Codable, Equatable {
    public var id: String
    public var repository: String
    public var revision: String
    public var downloadBytes: Int64
    public var architecture: String
    public var processorSource: ProcessorSource?
    /// Source precision label within the family; nil for a downloaded variant.
    public var derivedFrom: String?
    /// Affine quantization of the source (never below 4 bits).
    public var bits: Int?
    public var groupSize: Int?
    /// Float cast of the source (`bfloat16` or `float16`).
    public var dtype: String?
    public init(id: String, repository: String, revision: String, downloadBytes: Int64, architecture: String, processorSource: ProcessorSource? = nil) {
        self.id = id; self.repository = repository; self.revision = revision; self.downloadBytes = downloadBytes
        self.architecture = architecture; self.processorSource = processorSource
    }
    /// A locally derived variant.
    public init(id: String, architecture: String, derivedFrom: String, bits: Int? = nil, groupSize: Int? = nil, dtype: String? = nil) {
        self.init(id: id, repository: "", revision: "", downloadBytes: 0, architecture: architecture)
        self.derivedFrom = derivedFrom; self.bits = bits; self.groupSize = groupSize; self.dtype = dtype
    }
    public var isDerived: Bool { derivedFrom != nil }
    enum CodingKeys: String, CodingKey { case id, repository, revision, downloadBytes, architecture, processorSource, derivedFrom, bits, groupSize, dtype }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        architecture = try c.decode(String.self, forKey: .architecture)
        derivedFrom = try c.decodeIfPresent(String.self, forKey: .derivedFrom)
        bits = try c.decodeIfPresent(Int.self, forKey: .bits)
        groupSize = try c.decodeIfPresent(Int.self, forKey: .groupSize)
        dtype = try c.decodeIfPresent(String.self, forKey: .dtype)
        processorSource = try c.decodeIfPresent(ProcessorSource.self, forKey: .processorSource)
        if derivedFrom == nil {
            repository = try c.decode(String.self, forKey: .repository)
            revision = try c.decode(String.self, forKey: .revision)
            downloadBytes = try c.decode(Int64.self, forKey: .downloadBytes)
        } else {
            repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? ""
            revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
            downloadBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadBytes) ?? 0
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !isDerived {
            try c.encode(repository, forKey: .repository); try c.encode(revision, forKey: .revision)
            try c.encode(downloadBytes, forKey: .downloadBytes)
        }
        try c.encode(architecture, forKey: .architecture)
        try c.encodeIfPresent(processorSource, forKey: .processorSource)
        try c.encodeIfPresent(derivedFrom, forKey: .derivedFrom); try c.encodeIfPresent(bits, forKey: .bits)
        try c.encodeIfPresent(groupSize, forKey: .groupSize); try c.encodeIfPresent(dtype, forKey: .dtype)
    }
}

/// Tokenizer/processor files fetched from another pinned repository (a quantized conversion without them).
public struct ProcessorSource: Codable, Equatable {
    public var repository: String
    public var revision: String
    public var files: [String]
    public init(repository: String, revision: String, files: [String]) { self.repository = repository; self.revision = revision; self.files = files }
}

/// One row of the Models table: a model with its precisions.
public struct ModelFamily: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mode: RecognitionMode
    public var languages: [String]
    public var params: String
    public var license: String
    /// The checkpoint's own precision (`BF16`, `FP16`, `FP32`, or a native low-bit format such as ternary).
    public var native: String
    /// Precision label (`4b`, `8b`, `BF16`, `FP16`, `FP32`, …) → pinned download.
    public var variants: [String: CatalogVariant]
    /// Only offered families appear in the app; the others exist for the published benchmark table.
    public var offered: Bool
    public var notes: String?
    public init(id: String, name: String, mode: RecognitionMode, languages: [String], params: String, license: String, native: String,
                variants: [String: CatalogVariant], offered: Bool = true, notes: String? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.languages = languages; self.params = params; self.license = license
        self.native = native; self.variants = variants; self.offered = offered; self.notes = notes
    }
    /// The family's variant whose install id is `variantID`.
    public func precision(ofVariant variantID: String) -> String? { variants.first { $0.value.id == variantID }?.key }
}

public struct ModelCatalog: Codable, Equatable {
    public var schema: Int
    public var families: [ModelFamily]
    public init(schema: Int = 2, families: [ModelFamily]) { self.schema = schema; self.families = families }
    public func family(_ id: String) -> ModelFamily? { families.first { $0.id == id } }
    /// The family and precision that own an install id.
    public func locate(variant id: String) -> (family: ModelFamily, precision: String)? {
        for family in families { if let p = family.precision(ofVariant: id) { return (family, p) } }
        return nil
    }
    /// Offered families of a mode, in catalog order.
    public func offered(_ mode: RecognitionMode) -> [ModelFamily] { families.filter { $0.offered && $0.mode == mode } }
}

/// Decodes models.json v2. A pre-v2 flat array of variants (one entry per precision) is grouped into families by name
/// so older catalogs and fixtures still load.
public func decodeCatalog(_ data: Data) throws -> ModelCatalog {
    if let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data), catalog.schema >= 2 { return catalog }
    let legacy = try JSONDecoder().decode([LegacyEntry].self, from: data)
    var families: [ModelFamily] = []
    for entry in legacy {
        let precision = precisionLabel(legacyQuantization: entry.quantization)
        let variant = CatalogVariant(id: entry.id, repository: entry.repository, revision: entry.revision, downloadBytes: entry.downloadBytes,
                                     architecture: entry.architecture, processorSource: entry.processorSource)
        if let index = families.firstIndex(where: { $0.name == entry.name && $0.variants[precision] == nil }) {
            families[index].variants[precision] = variant
            if entry.recommended == true { families[index].offered = true }
        } else {
            let mode: RecognitionMode = ["nemotron_asr", "voxtral_realtime"].contains(entry.architecture) ? .streaming : .dictation
            families.append(ModelFamily(id: entry.id, name: entry.name, mode: mode, languages: [], params: "", license: entry.license,
                                        native: precision, variants: [precision: variant], offered: entry.recommended ?? true, notes: entry.recommendation))
        }
    }
    return ModelCatalog(schema: 2, families: families)
}
private struct LegacyEntry: Decodable {
    let id: String, name: String, quantization: String, repository: String, revision: String
    let downloadBytes: Int64, architecture: String, license: String, recommendation: String?
    let recommended: Bool?, processorSource: ProcessorSource?
}

/// Every variant of a catalog as the downloader's flat record (one per precision). `quantization` keeps the
/// downloader's legacy spelling (`4-bit`, `8-bit`, `BF16`) that `NativeModelDownload.validate` checks against config.json.
/// Locally derived variants are not downloads and are skipped (Get downloads their source).
public func catalogVariants(_ catalog: ModelCatalog) -> [ModelRecommendation] {
    catalog.families.flatMap { family in
        orderedPrecisions(Array(family.variants.keys)).compactMap { label -> ModelRecommendation? in
            guard let v = family.variants[label], !v.isDerived else { return nil }
            return ModelRecommendation(id: v.id, name: family.name, quantization: legacyQuantization(label), repository: v.repository,
                                       revision: v.revision, downloadBytes: v.downloadBytes, architecture: v.architecture, license: family.license,
                                       recommendation: family.notes ?? "", recommended: family.offered)
        }
    }
}
/// Reads a catalog file (v2 or legacy) as flat variant records.
public func catalogVariants(contentsOf url: URL) throws -> [ModelRecommendation] { catalogVariants(try decodeCatalog(Data(contentsOf: url))) }
/// The pinned processor recipe for an install id, if any.
public func processorSource(variant id: String, catalogURL: URL) throws -> ProcessorSource? {
    try decodeCatalog(Data(contentsOf: catalogURL)).locate(variant: id).flatMap { $0.family.variants[$0.precision]?.processorSource }
}

// MARK: Precision labels

/// `4-bit` → `4b`; exact float labels (`BF16`, `FP16`, `FP32`) stay. BF16 and FP16 are different formats.
public func precisionLabel(legacyQuantization q: String) -> String {
    if q.hasSuffix("-bit"), let bits = Int(q.dropLast(4)) { return "\(bits)b" }
    if q.lowercased() == "unquantized" { return "FP32" }
    return q
}
/// `4b` → `4-bit` (the downloader's spelling); other labels unchanged.
public func legacyQuantization(_ label: String) -> String {
    if label.hasSuffix("b"), let bits = Int(label.dropLast()) { return "\(bits)-bit" }
    return label
}
/// Bits per weight of a precision label, for ordering and the 4-bit floor: `4b` 4, `BF16`/`FP16` 16, `FP32` 32,
/// `ternary` 1.58. Nil for an unknown label.
public func labelBits(_ label: String) -> Double? {
    switch label.uppercased() {
    case "FP32", "F32": return 32
    case "BF16", "FP16", "F16": return 16
    case "TERNARY", "1.58B": return 1.58
    default:
        if label.lowercased().hasSuffix("b"), let bits = Double(label.dropLast()) { return bits }
        return nil
    }
}
/// Highest precision first; FP16 before BF16 at equal bits so the order is stable.
public func orderedPrecisions(_ labels: [String]) -> [String] {
    labels.sorted { a, b in
        let x = labelBits(a) ?? 0, y = labelBits(b) ?? 0
        return x == y ? a > b : x > y
    }
}
/// Offered precisions for a family, highest first: every catalogued variant, never below 4 bits unless that is the
/// model's native format (a natively ternary model is its own option, not a quantization).
public func precisionOptions(_ family: ModelFamily) -> [String] {
    orderedPrecisions(family.variants.keys.filter { $0 == family.native || (labelBits($0) ?? 0) >= 4 })
}

// MARK: Measured numbers (benchmarks.json v1)

public struct MultilingualResult: Codable, Equatable {
    public var mean: Double?
    public var coverage: Int?
    public var by_language: [String: Double]?
    public init(mean: Double? = nil, coverage: Int? = nil, by_language: [String: Double]? = nil) {
        self.mean = mean; self.coverage = coverage; self.by_language = by_language
    }
}

/// Measured figures for one family at one precision. Every field is optional: absent = not measured (`—`).
/// `wer` and `format` are percentages (5.12 = 5.12 %).
public struct PrecisionResult: Codable, Equatable {
    public var wer: Double?
    public var format: Double?
    public var multilingual: MultilingualResult?
    public var speed_x: Double?
    public var j_per_min: Double?
    public var memory_mb: Double?
    public var disk_mb: Double?
    public var suite: String?
    public var audio_min: Double?
    public var date: String?
    public var hardware: String?
    public var engine: String?
    public var note: String?
    public init(wer: Double? = nil, format: Double? = nil, multilingual: MultilingualResult? = nil, speed_x: Double? = nil, j_per_min: Double? = nil,
                memory_mb: Double? = nil, disk_mb: Double? = nil, suite: String? = nil, audio_min: Double? = nil, date: String? = nil,
                hardware: String? = nil, engine: String? = nil, note: String? = nil) {
        self.wer = wer; self.format = format; self.multilingual = multilingual; self.speed_x = speed_x; self.j_per_min = j_per_min
        self.memory_mb = memory_mb; self.disk_mb = disk_mb; self.suite = suite; self.audio_min = audio_min; self.date = date
        self.hardware = hardware; self.engine = engine; self.note = note
    }
    public init(from decoder: Decoder) throws {
        // A wrongly typed field is treated as not measured rather than dropping the whole result.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wer = try? c.decodeIfPresent(Double.self, forKey: .wer); format = try? c.decodeIfPresent(Double.self, forKey: .format)
        multilingual = try? c.decodeIfPresent(MultilingualResult.self, forKey: .multilingual)
        speed_x = try? c.decodeIfPresent(Double.self, forKey: .speed_x); j_per_min = try? c.decodeIfPresent(Double.self, forKey: .j_per_min)
        memory_mb = try? c.decodeIfPresent(Double.self, forKey: .memory_mb); disk_mb = try? c.decodeIfPresent(Double.self, forKey: .disk_mb)
        suite = try? c.decodeIfPresent(String.self, forKey: .suite); audio_min = try? c.decodeIfPresent(Double.self, forKey: .audio_min)
        date = try? c.decodeIfPresent(String.self, forKey: .date); hardware = try? c.decodeIfPresent(String.self, forKey: .hardware)
        engine = try? c.decodeIfPresent(String.self, forKey: .engine); note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
}

public struct FamilyBenchmark: Codable, Equatable {
    public var precisions: [String: PrecisionResult]
    /// The recommended precision as the catalog script computed it (cross-checked against `recommendedPrecision`).
    public var recommended: String?
    public init(precisions: [String: PrecisionResult], recommended: String? = nil) { self.precisions = precisions; self.recommended = recommended }
    public func result(_ precision: String) -> PrecisionResult? { precisions[precision] }
}

public struct SuiteInfo: Codable, Equatable {
    public var id: String?
    public var hash: String?
    public var audio_min: Double?
}

public struct BenchmarkFile: Codable, Equatable {
    public var schema: Int
    public var hardware: String?
    public var suites: [String: SuiteInfo]?
    public var models: [String: FamilyBenchmark]
    public init(schema: Int = 1, hardware: String? = nil, suites: [String: SuiteInfo]? = nil, models: [String: FamilyBenchmark] = [:]) {
        self.schema = schema; self.hardware = hardware; self.suites = suites; self.models = models
    }
}

/// Decodes benchmarks.json; a malformed family is skipped, a missing or unreadable file is empty (every figure `—`).
public func decodeBenchmarks(_ data: Data?) -> BenchmarkFile {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return BenchmarkFile() }
    var file = BenchmarkFile(schema: object["schema"] as? Int ?? 1, hardware: object["hardware"] as? String)
    if let suites = object["suites"], JSONSerialization.isValidJSONObject(suites), let bytes = try? JSONSerialization.data(withJSONObject: suites) {
        file.suites = try? JSONDecoder().decode([String: SuiteInfo].self, from: bytes)
    }
    for (id, value) in object["models"] as? [String: Any] ?? [:] {
        guard let precisions = (value as? [String: Any])?["precisions"] as? [String: Any] else { continue }
        var results: [String: PrecisionResult] = [:]
        for (label, raw) in precisions {
            // isValidJSONObject first: a non-container value would raise an Objective-C exception, not a Swift error.
            guard JSONSerialization.isValidJSONObject(raw), let bytes = try? JSONSerialization.data(withJSONObject: raw), let r = try? JSONDecoder().decode(PrecisionResult.self, from: bytes) else { continue }
            results[label] = r
        }
        file.models[id] = FamilyBenchmark(precisions: results, recommended: (value as? [String: Any])?["recommended"] as? String)
    }
    return file
}

// MARK: Recommended precision

/// WER margin (percentage points, absolute) a precision may lose against the native precision.
public let recommendationMarginPoints = 0.5

/// The recommended precision: among measured precisions (WER present) whose WER is at most the NATIVE precision's
/// WER + 0.5 points, the lowest J / min; ties → faster (higher × real time); then higher bits. The native precision is
/// the reference, so benchmark noise at a lossy setting cannot move the bar. A precision without energy (or speed)
/// ranks after those with it. `options` limits candidates to offered precisions. Nil when native WER is not measured.
/// lab/bench/measure_catalog.py mirrors this rule (cross-checked by CatalogTests).
public func recommendedPrecision(_ benchmark: FamilyBenchmark?, native: String, options: [String]? = nil) -> String? {
    guard let benchmark, let reference = benchmark.result(native)?.wer else { return nil }
    let measured: [(label: String, result: PrecisionResult)] = benchmark.precisions.compactMap { label, r in
        guard let wer = r.wer, options?.contains(label) ?? true,
              // 1e-9 absorbs float error: 5.62 − 5.12 is not exactly 0.5.
              wer <= reference + recommendationMarginPoints + 1e-9 else { return nil }
        return (label, r)
    }
    func lower(_ a: Double?, _ b: Double?) -> Bool? {
        switch (a, b) {
        case let (x?, y?): return x == y ? nil : x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
    return measured.min { a, b in
        lower(a.result.j_per_min, b.result.j_per_min)
            ?? lower(a.result.speed_x.map { -$0 }, b.result.speed_x.map { -$0 })
            ?? ((labelBits(a.label) ?? 0) != (labelBits(b.label) ?? 0) ? (labelBits(a.label) ?? 0) > (labelBits(b.label) ?? 0) : a.label > b.label)
    }?.label
}

public func recommendedPrecision(for family: ModelFamily, in benchmarks: BenchmarkFile) -> String? {
    recommendedPrecision(benchmarks.models[family.id], native: family.native, options: precisionOptions(family))
}

/// Selection records store the native precision as `native`, so a native label change keeps the user's choice.
public let nativeSelection = "native"
public func storedPrecision(_ label: String, native: String) -> String { label == native ? nativeSelection : label }
public func effectivePrecision(stored: String, native: String) -> String { stored == nativeSelection ? native : stored }

/// The selected precision: the user's stored choice if still offered, else the loaded precision (a model loaded
/// on demand is not a pending change), else the recommended one, else native, else the highest offered.
public func selectedPrecision(stored: String?, loaded: String? = nil, recommended: String?, family: ModelFamily) -> String {
    let options = precisionOptions(family)
    if let stored { let p = effectivePrecision(stored: stored, native: family.native); if options.contains(p) { return p } }
    if let loaded, options.contains(loaded) { return loaded }
    if let recommended { return recommended }
    if options.contains(family.native) { return family.native }
    return options.first ?? family.native
}

/// Tooltip of the recommended segment: states which criterion chose it, energy only when energy was measured.
public func recommendationHelp(_ benchmark: FamilyBenchmark?, recommended: String, native: String) -> String {
    let within = "within 0.5 pt WER of the native precision (\(native))"
    if benchmark?.result(recommended)?.j_per_min != nil { return "Recommended: lowest energy per audio minute \(within)." }
    return "Recommended: fastest measured precision \(within); energy not measured."
}

/// What the row's button does for the selected precision given the loaded one (nil = not loaded).
public enum LoadAction: Equatable { case get, load, unload, reload }
public func loadAction(selected: String, loaded: String?, native: String, downloaded: Bool) -> LoadAction {
    guard let loaded else { return downloaded ? .load : .get }
    // Reload downloads the selected precision first when needed; the button stays the green pending-apply Reload.
    return effectivePrecision(stored: loaded, native: native) == effectivePrecision(stored: selected, native: native) ? .unload : .reload
}

// MARK: Deltas vs the recommended precision

public enum DeltaTone: Equatable { case better, worse, neutral }
public struct Delta: Equatable {
    public var text: String
    public var tone: DeltaTone
    public init(_ text: String, _ tone: DeltaTone) { self.text = text; self.tone = tone }
}
private let minus = "\u{2212}"
private func signed(_ value: Double, _ format: String) -> String { (value < 0 ? minus : "+") + String(format: format, abs(value)) }

/// An error rate in percent (WER or format CER) → `+0.4 pt`; lower is better. Under 0.05 points reads `±0.0 pt`.
public func errorRateDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base else { return nil }
    let points = value - base
    if abs(points) < 0.05 { return Delta("±0.0 pt", .neutral) }
    return Delta(signed(points, "%.1f") + " pt", points < 0 ? .better : .worse)
}

/// Speed in × real time → `35% faster` / `20% slower`; from 2× on `2.4× faster`. Under 1 % reads `same`.
public func speedDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base, value > 0, base > 0 else { return nil }
    let faster = value > base
    let ratio = faster ? value / base : base / value
    if ratio - 1 < 0.01 { return Delta("same", .neutral) }
    let amount = ratio >= 2 ? String(format: "%.1f×", ratio) : String(format: "%.0f%%", (ratio - 1) * 100)
    if amount == "0%" { return Delta("same", .neutral) }
    return Delta("\(amount) \(faster ? "faster" : "slower")", faster ? .better : .worse)
}

/// Energy per audio minute → `20% less` / `15% more`; from 2× the base on `2.9× more`. Under 0.5 % reads `same`.
public func energyDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base, base > 0 else { return nil }
    let change = value / base - 1
    if abs(change) < 0.005 { return Delta("same", .neutral) }
    if change >= 1 { return Delta(String(format: "%.1f× more", value / base), .worse) }
    return Delta(String(format: "%.0f%%", abs(change) * 100) + (change < 0 ? " less" : " more"), change < 0 ? .better : .worse)
}

/// Memory → `40% less` / `1.8× more`, like energy.
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
/// `en` for one or two languages (`en, pl`), else the count (`25`).
public func formatLanguages(_ codes: [String]) -> String {
    codes.isEmpty ? "—" : codes.count <= 2 ? codes.joined(separator: ", ") : String(codes.count)
}
/// Under ~20× real time a model is very slow for dictation.
public let slowSpeedFloor = 20.0

// MARK: Engine label

/// `Optimized · M5 Max` on the optimized path (self-tested at load, no runtime fallback), else `MLX`.
public func engineLabel(engine: String?, chip: String?) -> String {
    guard engine == "optimized" else { return "MLX" }
    guard let chip = displayChip(chip) else { return "Optimized" }
    return "Optimized \u{00b7} " + chip
}
/// Tooltip for the engine label: which path answers, the optimized components as the worker reports them
/// (component → active) and, off the optimized path, the worker's reason. Never invents a cause.
public func engineHelp(engine: String?, reason: String?, optimizations: [String: Bool]?, chip: String?, precision: String) -> String {
    var lines: [String] = []
    let active = (optimizations ?? [:]).filter(\.value).keys.sorted()
    let stock = (optimizations ?? [:]).filter { !$0.value }.keys.sorted()
    let why = reason.map { " Why: \($0)." } ?? ""
    if engine == "optimized" {
        lines.append("Optimized path, self-tested at load on this Mac" + (displayChip(chip).map { " (\($0))" } ?? "") + ".")
        if !active.isEmpty { lines.append("Optimized: " + active.joined(separator: ", ") + (stock.isEmpty ? "." : "; stock: " + stock.joined(separator: ", ") + ".")) }
    } else if !active.isEmpty {
        lines.append("Partly optimized \u{2014} optimized: " + active.joined(separator: ", ") + "; stock: " + (stock.isEmpty ? "none" : stock.joined(separator: ", ")) + "." + why)
    } else {
        lines.append("Stock MLX path: the same model without Vella's optimizations; slower." + why)
    }
    lines.append("Precision: \(precision)")
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
                  chipGeneration(chip) != nil else { continue }
            counts[chip, default: 0] += 1
        }
    }
    if let top = counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first { return top.key }
    return file.hardware.flatMap { displayChip($0.split(separator: ",").first.map(String.init)) }.flatMap { chipGeneration($0) != nil ? $0 : nil }
}
/// The footer note when this Mac is not in the measurement chip's generation (M5 Pro and M5 Max count as the same).
public func hardwareNote(thisChip: String?, measuredOn: String?) -> (text: String, help: String)? {
    guard let this = displayChip(thisChip), let measured = displayChip(measuredOn),
          let a = chipGeneration(this), let b = chipGeneration(measured), a != b else { return nil }
    return ("Benchmarks measured on \(measured)",
            "Speed, energy and memory were measured on \(measured); they differ on this Mac (\(this)). Error rates are the same.")
}

// MARK: Runtime state the table shows

/// A loaded model as the table needs it (the worker status reduced to what is drawn).
public struct LoadedFamily: Equatable {
    public var precision: String
    public var engine: String?
    public var engineReason: String?
    public var optimizations: [String: Bool]?
    public var residency: String?
    public init(precision: String, engine: String? = nil, engineReason: String? = nil, optimizations: [String: Bool]? = nil, residency: String? = nil) {
        self.precision = precision; self.engine = engine; self.engineReason = engineReason; self.optimizations = optimizations; self.residency = residency
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
    public init(loaded: [String: LoadedFamily] = [:], loading: String? = nil, chip: String? = nil, workerError: String? = nil,
                refusal: TableRefusal? = nil, available: Bool = true) {
        self.loaded = loaded; self.loading = loading; self.chip = chip; self.workerError = workerError; self.refusal = refusal; self.available = available
    }
}
