import Foundation

// Models catalog (Resources/models.json v2), measured numbers (Resources/benchmarks.json v1) and the Models table's
// UI-free logic: precision options, the recommended precision, deltas, formatters and the hardware note.

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
    /// Free-form note: the API's `recommendation` and the benchmark site. Not tooltip text (the table assembles its
    /// lines from the structured fields below).
    public var notes: String?
    /// The Model tooltip's facts (TableHelp.swift): who released the model, the year, the licence's display name
    /// (`license` stays the upstream card's metadata id), and one plain sentence on what it does and does not do.
    /// Each is optional; an unknown fact is left out of the tooltip.
    public var publisher: String?
    public var released: Int?
    public var licence: String?
    public var summary: String?
    public init(id: String, name: String, mode: RecognitionMode, languages: [String], params: String, license: String, native: String,
                variants: [String: CatalogVariant], offered: Bool = true, notes: String? = nil, publisher: String? = nil,
                released: Int? = nil, licence: String? = nil, summary: String? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.languages = languages; self.params = params; self.license = license
        self.native = native; self.variants = variants; self.offered = offered; self.notes = notes
        self.publisher = publisher; self.released = released; self.licence = licence; self.summary = summary
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
/// The Q column's bare width for a precision: `FP32` → `32`, `BF16` → `16`, `8b` → `8`, `4b` → `4`, ternary → `1.58`.
/// Nil for an unknown label.
public func precisionWidth(_ label: String) -> String? {
    guard let bits = labelBits(label) else { return nil }
    return bits == bits.rounded() ? String(Int(bits)) : String(format: "%g", bits)
}
/// Segment labels for a family's options: bare widths (`32 16 8 4`). A bare 16 always means BF16, as the Q heading
/// says, so an FP16 option (Whisper) keeps its exact label `FP16`. If two options ever share a
/// width, every segment falls back to its exact label.
public func precisionSegmentLabels(_ options: [String]) -> [String] {
    let widths = options.map { precisionWidth($0) }
    let unique = Set(widths.compactMap { $0 }).count == options.count && !widths.contains(nil)
    guard unique else { return options }
    return zip(options, widths).map { ["FP16", "F16"].contains($0.uppercased()) ? "FP16" : $1! }
}
/// A precision in prose (menu header, messages): quantized `4-bit`, `8-bit`; float formats exact (`BF16`, `FP32`).
public func precisionInProse(_ label: String) -> String { legacyQuantization(label) }
/// The exact format of a precision label, for tooltips: `BF16 (bfloat16)`, `FP16 (float16)`, `FP32 (float32)`,
/// `4-bit quantized`, `ternary (1.58-bit)`.
public func precisionFormatName(_ label: String) -> String {
    switch label.uppercased() {
    case "FP32", "F32": return "FP32 (float32)"
    case "BF16": return "BF16 (bfloat16)"
    case "FP16", "F16": return "FP16 (float16)"
    case "TERNARY", "1.58B": return "ternary (1.58-bit)"
    default:
        if label.lowercased().hasSuffix("b"), let bits = Int(label.dropLast()) { return "\(bits)-bit quantized" }
        return label
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

/// Reply-time percentiles in milliseconds (lab/bench/vbench.py). Dictation (`kind` segment): the wait for each sent
/// segment's text, the last one being the wait after Finish. Streaming (`kind` packet): every 100-ms packet's reply;
/// `chunk_*` are the packets that run an encoder chunk (the slowest 1 in 3.2).
public struct LatencyResult: Codable, Equatable {
    public var p50: Double?
    public var p95: Double?
    public var n: Int?
    public var kind: String?
    public var chunk_p50: Double?
    public var chunk_p95: Double?
    public init(p50: Double? = nil, p95: Double? = nil, n: Int? = nil, kind: String? = nil, chunk_p50: Double? = nil, chunk_p95: Double? = nil) {
        self.p50 = p50; self.p95 = p95; self.n = n; self.kind = kind; self.chunk_p50 = chunk_p50; self.chunk_p95 = chunk_p95
    }
}

/// The stock-MLX baseline of a precision: the same model with every Vella optimization off (plain MLX), which is what
/// any Apple-silicon Mac runs when its load-time self-test does not qualify the fast path. Measured in the same session
/// as the optimized figures, on the recommended precision only.
public struct StockBaseline: Codable, Equatable {
    public var wer: Double?
    public var format: Double?
    public var multilingual: MultilingualResult?
    public var speed_x: Double?
    public var j_per_min: Double?
    public var memory_mb: Double?
    public var latency_ms: LatencyResult?
    public var suite: String?
    public var date: String?
    public var hardware: String?
    public init(wer: Double? = nil, format: Double? = nil, multilingual: MultilingualResult? = nil, speed_x: Double? = nil, j_per_min: Double? = nil,
                memory_mb: Double? = nil, latency_ms: LatencyResult? = nil, suite: String? = nil, date: String? = nil, hardware: String? = nil) {
        self.wer = wer; self.format = format; self.multilingual = multilingual; self.speed_x = speed_x; self.j_per_min = j_per_min
        self.memory_mb = memory_mb; self.latency_ms = latency_ms; self.suite = suite; self.date = date; self.hardware = hardware
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wer = try? c.decodeIfPresent(Double.self, forKey: .wer); format = try? c.decodeIfPresent(Double.self, forKey: .format)
        multilingual = try? c.decodeIfPresent(MultilingualResult.self, forKey: .multilingual)
        speed_x = try? c.decodeIfPresent(Double.self, forKey: .speed_x); j_per_min = try? c.decodeIfPresent(Double.self, forKey: .j_per_min)
        memory_mb = try? c.decodeIfPresent(Double.self, forKey: .memory_mb); latency_ms = try? c.decodeIfPresent(LatencyResult.self, forKey: .latency_ms)
        suite = try? c.decodeIfPresent(String.self, forKey: .suite); date = try? c.decodeIfPresent(String.self, forKey: .date)
        hardware = try? c.decodeIfPresent(String.self, forKey: .hardware)
    }
}

/// Measured figures for one family at one precision. Every field is optional: absent = not measured (`—`).
/// `wer` and `format` are percentages (5.12 = 5.12 %).
/// The quality-gate verdict of a lower precision against the native one (lab/notes/GATE-REVISION.md), written per
/// precision by the benchmark tools (lab/bench/gate_check.py). `reasons` are short, user-readable: why it failed, or
/// on what grounds it passed when that needs saying (e.g. a streaming model passing on speed).
public struct GateResult: Codable, Equatable {
    public var pass: Bool
    public var reasons: [String]
    public init(pass: Bool, reasons: [String] = []) { self.pass = pass; self.reasons = reasons }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pass = try c.decode(Bool.self, forKey: .pass)
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
    }
}

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
    /// The quality gate against the native precision; nil in files written before the gate (then the English-WER
    /// tolerance decides, see `recommendedPrecision`).
    public var gate: GateResult?
    /// Reply-time percentiles of the optimized run (same quick-suite run as speed and energy).
    public var latency_ms: LatencyResult?
    /// The stock-MLX baseline measured beside this precision (recommended precisions only).
    public var stock: StockBaseline?
    public init(wer: Double? = nil, format: Double? = nil, multilingual: MultilingualResult? = nil, speed_x: Double? = nil, j_per_min: Double? = nil,
                memory_mb: Double? = nil, disk_mb: Double? = nil, suite: String? = nil, audio_min: Double? = nil, date: String? = nil,
                hardware: String? = nil, engine: String? = nil, note: String? = nil, gate: GateResult? = nil,
                latency_ms: LatencyResult? = nil, stock: StockBaseline? = nil) {
        self.wer = wer; self.format = format; self.multilingual = multilingual; self.speed_x = speed_x; self.j_per_min = j_per_min
        self.memory_mb = memory_mb; self.disk_mb = disk_mb; self.suite = suite; self.audio_min = audio_min; self.date = date
        self.hardware = hardware; self.engine = engine; self.note = note; self.gate = gate
        self.latency_ms = latency_ms; self.stock = stock
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
        gate = try? c.decodeIfPresent(GateResult.self, forKey: .gate)
        latency_ms = try? c.decodeIfPresent(LatencyResult.self, forKey: .latency_ms)
        stock = try? c.decodeIfPresent(StockBaseline.self, forKey: .stock)
    }
}

public struct FamilyBenchmark: Codable, Equatable {
    public var precisions: [String: PrecisionResult]
    /// The recommended precision as the catalog script computed it (cross-checked against `recommendedPrecision`).
    public var recommended: String?
    /// The family's measured noise floor N in WER points (lab/notes/GATE-REVISION.md); absent when not measured.
    public var noise_pt: Double?
    /// The family's WER tolerance T = min(0.2, max(0.1, N + 0.05)) points; absent → 0.1.
    public var tolerance_pt: Double?
    public init(precisions: [String: PrecisionResult], recommended: String? = nil, noise_pt: Double? = nil, tolerance_pt: Double? = nil) {
        self.precisions = precisions; self.recommended = recommended; self.noise_pt = noise_pt; self.tolerance_pt = tolerance_pt
    }
    public func result(_ precision: String) -> PrecisionResult? { precisions[precision] }
}

public struct SuiteInfo: Codable, Equatable {
    public var id: String?
    public var hash: String?
    public var audio_min: Double?
}

/// A cloud API shown for perspective (benchmarks.json `references`, written by the maintainer's benchmark tools). Its WER on
/// v2 is ESTIMATED from a public leaderboard, never measured by us: nothing is sent to it, and it has no download,
/// precision, speed, energy or memory. `range` is the estimate's spread [low, high] in percent.
public struct ReferenceEntry: Codable, Equatable, Identifiable {
    public var id: String = ""
    public var name: String
    public var provider: String?
    public var mode: RecognitionMode
    public var reference: Bool?
    public var estimated: Bool?
    public var wer: Double?
    public var range: [Double]?
    public var multilingual: MultilingualResult?
    public var source: String?
    public var method: String?
    public var date: String?
    public init(id: String, name: String, provider: String? = nil, mode: RecognitionMode = .dictation, wer: Double?, range: [Double]? = nil,
                multilingual: MultilingualResult? = nil, source: String? = nil, method: String? = nil, date: String? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.mode = mode; self.reference = true; self.estimated = true
        self.wer = wer; self.range = range; self.multilingual = multilingual; self.source = source; self.method = method; self.date = date
    }
    enum CodingKeys: String, CodingKey { case name, provider, mode, reference, estimated, wer, range, multilingual, source, method, date }
}

public struct BenchmarkFile: Codable, Equatable {
    public var schema: Int
    public var hardware: String?
    public var suites: [String: SuiteInfo]?
    public var models: [String: FamilyBenchmark]
    /// Cloud API reference rows, id → entry (estimated; see ReferenceEntry).
    public var references: [String: ReferenceEntry]
    public init(schema: Int = 1, hardware: String? = nil, suites: [String: SuiteInfo]? = nil, models: [String: FamilyBenchmark] = [:],
                references: [String: ReferenceEntry] = [:]) {
        self.schema = schema; self.hardware = hardware; self.suites = suites; self.models = models; self.references = references
    }
    /// Reference rows of a mode, in id order (the table sorts them with the models).
    public func references(_ mode: RecognitionMode) -> [ReferenceEntry] {
        references.values.filter { $0.mode == mode }.sorted { $0.id < $1.id }
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
        let entry = value as? [String: Any]
        file.models[id] = FamilyBenchmark(precisions: results, recommended: entry?["recommended"] as? String,
                                          noise_pt: (entry?["noise_pt"] as? NSNumber)?.doubleValue,
                                          tolerance_pt: (entry?["tolerance_pt"] as? NSNumber)?.doubleValue)
    }
    // Only entries marked both reference and estimated are shown; anything else is ignored rather than passed off as measured.
    for (id, raw) in object["references"] as? [String: Any] ?? [:] {
        guard JSONSerialization.isValidJSONObject(raw), let bytes = try? JSONSerialization.data(withJSONObject: raw),
              var entry = try? JSONDecoder().decode(ReferenceEntry.self, from: bytes),
              entry.reference == true, entry.estimated == true else { continue }
        entry.id = id
        file.references[id] = entry
    }
    return file
}

// MARK: Table sort keys

public enum TableMetric: CaseIterable { case wer, format, speed, energy, memory, disk }

/// Published = downloadable from a pinned repository (derived precisions are made on this Mac and have none).
public func isPublished(_ family: ModelFamily, _ label: String) -> Bool {
    guard let v = family.variants[label], !v.isDerived else { return false }
    return !v.repository.isEmpty && v.downloadBytes > 0
}

/// The table's On disk for a precision in bytes: a published download's pinned size, else the measured size; nil =
/// `—`. Unlike `ModelFamily.diskBytes`, a derived precision never borrows its source's size.
public func tableDiskBytes(_ family: ModelFamily, _ label: String, _ result: PrecisionResult?) -> Int64? {
    if isPublished(family, label), let v = family.variants[label] { return v.downloadBytes }
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
/// in either direction; ties keep catalog order.
public func sortedFamilies(_ families: [ModelFamily], by metric: TableMetric?, ascending: Bool, benchmarks: BenchmarkFile) -> [ModelFamily] {
    guard let metric else { return families.sorted { ascending ? $0.name < $1.name : $0.name > $1.name } }
    let keyed = families.enumerated().map { ($0.offset, $0.element, tableSortKey(metric, family: $0.element, benchmark: benchmarks.models[$0.element.id])) }
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
        switch self { case .family(let f): return f.id; case .reference(let r): return "reference:" + r.id }
    }
    public var name: String {
        switch self { case .family(let f): return f.name; case .reference(let r): return r.name }
    }
}

/// A reference row's sort key: its estimated WER for the WER column; nothing else applies (it sorts last there).
public func referenceSortKey(_ metric: TableMetric, _ reference: ReferenceEntry) -> Double? { metric == .wer ? reference.wer : nil }

/// Families and reference rows of one section sorted together, by the same rule as `sortedFamilies`: best value first
/// when ascending, rows without a value last in either direction, ties in input order (families first).
public func sortedRows(_ families: [ModelFamily], references: [ReferenceEntry], by metric: TableMetric?, ascending: Bool,
                       benchmarks: BenchmarkFile) -> [ModelTableRow] {
    let rows = families.map(ModelTableRow.family) + references.map(ModelTableRow.reference)
    guard let metric else { return rows.sorted { ascending ? $0.name < $1.name : $0.name > $1.name } }
    let keyed = rows.enumerated().map { index, row -> (Int, ModelTableRow, Double?) in
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

// MARK: Recommended precision

/// WER tolerance (percentage points, absolute) a precision may lose against the native precision when the family's
/// noise floor is unmeasured, and the cap for any family (lab/notes/GATE-REVISION.md: T = min(0.2, max(0.1, N + 0.05))).
public let defaultRecommendationTolerancePoints = 0.1
public let maximumRecommendationTolerancePoints = 0.2

/// The family's tolerance: benchmarks.json `tolerance_pt`, kept within 0.1–0.2 points; 0.1 when absent.
public func recommendationTolerance(_ benchmark: FamilyBenchmark?) -> Double {
    guard let t = benchmark?.tolerance_pt, t.isFinite else { return defaultRecommendationTolerancePoints }
    return min(maximumRecommendationTolerancePoints, max(defaultRecommendationTolerancePoints, t))
}

/// Candidate order: lowest J / min; ties → faster (higher × real time); then more bits. Missing energy (or speed) ranks
/// after present values.
private func ranksBefore(_ a: (label: String, result: PrecisionResult), _ b: (label: String, result: PrecisionResult)) -> Bool {
    func lower(_ x: Double?, _ y: Double?) -> Bool? {
        switch (x, y) {
        case let (x?, y?): return x == y ? nil : x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
    return lower(a.result.j_per_min, b.result.j_per_min)
        ?? lower(a.result.speed_x.map { -$0 }, b.result.speed_x.map { -$0 })
        ?? ((labelBits(a.label) ?? 0) != (labelBits(b.label) ?? 0) ? (labelBits(a.label) ?? 0) > (labelBits(b.label) ?? 0) : a.label > b.label)
}

/// Whether a measured precision may be recommended: the native precision always; another one when its quality gate
/// against native passed (`gate.pass`), or, in a file without a gate verdict for it, when its WER is at most the
/// native WER + the family's tolerance. The thresholds live in the benchmark tools, not here.
func passesGate(_ label: String, _ r: PrecisionResult, native: String, nativeWER: Double, tolerance: Double) -> Bool {
    if label == native { return true }
    if let gate = r.gate { return gate.pass }
    guard let wer = r.wer else { return false }
    // 1e-9 absorbs float error: 5.22 − 5.12 is not exactly 0.1.
    return wer <= nativeWER + tolerance + 1e-9
}

/// The recommended precision: among the native precision and the measured precisions (WER present) that pass the
/// quality gate against it (`passesGate`), the lowest J / min; ties → faster (higher × real time); then higher bits.
/// A precision without energy (or speed) ranks after those with it. `options` limits candidates to offered
/// precisions. Nil when native WER is not measured. The benchmark script that writes benchmarks.json applies the same
/// rule (lab/fixtures/recommended_precision.py, cross-checked by CatalogTests).
public func recommendedPrecision(_ benchmark: FamilyBenchmark?, native: String, options: [String]? = nil) -> String? {
    guard let benchmark, let reference = benchmark.result(native)?.wer else { return nil }
    let tolerance = recommendationTolerance(benchmark)
    let measured: [(label: String, result: PrecisionResult)] = benchmark.precisions.compactMap { label, r in
        guard r.wer != nil, options?.contains(label) ?? true,
              passesGate(label, r, native: native, nativeWER: reference, tolerance: tolerance) else { return nil }
        return (label, r)
    }
    return measured.min(by: ranksBefore)?.label
}

public func recommendedPrecision(for family: ModelFamily, in benchmarks: BenchmarkFile) -> String? {
    recommendedPrecision(benchmarks.models[family.id], native: family.native, options: precisionOptions(family))
}

/// The retired model-precision.json stored the native precision as `native`; read once by the migration.
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

/// The precision a row returns to without a preview: loaded, else last loaded, else recommended (see shownPrecision).
public func committedPrecision(loaded: String?, lastLoaded: String?, recommended: String?, family: ModelFamily) -> String {
    shownPrecision(preview: nil, loaded: loaded, lastLoaded: lastLoaded, recommended: recommended, family: family)
}

/// `0.1`, `0.15`, `0.2`: a tolerance in points without trailing zeros.
func formatPoints(_ value: Double) -> String {
    var text = String(format: "%.2f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// Tooltip of the recommended segment: which criterion chose it (energy only when energy was measured); on what
/// grounds the recommended precision passed when its gate says so; and, for every offered precision that would have
/// ranked first but failed, the trade with the file's numbers and the gate's reasons, e.g. `4-bit uses 28% less
/// energy (55 J vs 75 J per audio minute) but fails the quality gate: multilingual mean +0.48 pt (limit 0.10).`
public func recommendationHelp(_ benchmark: FamilyBenchmark?, recommended: String, native: String, options: [String]? = nil) -> String {
    let tolerance = recommendationTolerance(benchmark)
    let gated = benchmark?.precisions.contains { $0.key != native && $0.value.gate != nil } ?? false
    let criterion = gated ? "among the precisions that pass the quality gate against the native precision (\(native))"
                          : "within \(formatPoints(tolerance)) pt WER of the native precision (\(native))"
    guard let benchmark, let chosen = benchmark.result(recommended), chosen.j_per_min != nil else {
        return "Recommended: fastest measured precision \(criterion)\nEnergy not measured"
    }
    // One line per statement (the tooltip format): the rule, then at most one line per rejected precision, each
    // naming its gain and its first two gate reasons.
    var lines = ["Recommended: lowest energy per audio minute \(criterion)"]
    if recommended != native, let gate = chosen.gate, gate.pass, !gate.reasons.isEmpty {
        lines.append("\(precisionInProse(recommended)): \(gate.reasons.prefix(2).joined(separator: "; "))")
    }
    var text: String { lines.joined(separator: "\n") }
    guard let nativeWER = benchmark.result(native)?.wer else { return text }
    let rejected = benchmark.precisions.filter { label, r in
        guard label != recommended, options?.contains(label) ?? true, r.wer != nil else { return false }
        return !passesGate(label, r, native: native, nativeWER: nativeWER, tolerance: tolerance) && ranksBefore((label, r), (recommended, chosen))
    }.sorted { ranksBefore(($0.key, $0.value), ($1.key, $1.value)) }
    for (label, r) in rejected {
        guard let wer = r.wer else { continue }
        let gain: String
        if let e = energyDelta(r.j_per_min, base: chosen.j_per_min), e.tone == .better, let a = formatEnergy(r.j_per_min), let b = formatEnergy(chosen.j_per_min) {
            gain = "uses \(e.text) energy (\(a) vs \(b) per audio minute)"
        } else if let x = speedDelta(r.speed_x, base: chosen.speed_x), x.tone == .better, let a = formatSpeed(r.speed_x), let b = formatSpeed(chosen.speed_x) {
            gain = "is \(x.text) (\(a) vs \(b) real time)"
        } else { continue }
        let why: String
        if let gate = r.gate {
            let more = gate.reasons.count > 2 ? " (+\(gate.reasons.count - 2) more)" : ""
            why = "fails the quality gate" + (gate.reasons.isEmpty ? "" : ": " + gate.reasons.prefix(2).joined(separator: "; ") + more)
        } else {
            why = "has \(String(format: "%.2f", wer - (chosen.wer ?? nativeWER))) pt more word errors "
                + "(\(String(format: "%.2f", wer - nativeWER)) pt over \(precisionInProse(native)); limit \(formatPoints(tolerance)) pt)"
        }
        lines.append("\(precisionInProse(label)) \(gain) but \(why)")
    }
    return text
}

/// What the row's button does for the shown precision given the loaded one (nil = not loaded). Without a preview a
/// loaded row shows its loaded precision, so it offers Unload; a previewed other precision offers the green Reload.
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
public func engineHelp(engine: String?, reason: String?, optimizations: [String: Bool]?, chip: String?, precision: String, stock baseline: String? = nil) -> String {
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
    lines.append("Precision: \(precisionInProse(precision))")
    if let baseline { lines.append(baseline) }   // stockLine(_:) of the loaded precision
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
