import Foundation

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
    /// A caveat on how this baseline was measured (e.g. a pending rerun); shown briefly in the table, in full on the site.
    public var note: String?
    public init(wer: Double? = nil, format: Double? = nil, multilingual: MultilingualResult? = nil, speed_x: Double? = nil, j_per_min: Double? = nil,
                memory_mb: Double? = nil, latency_ms: LatencyResult? = nil, suite: String? = nil, date: String? = nil, hardware: String? = nil,
                note: String? = nil) {
        self.note = note
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
    /// Schema 2 (Benchmarks.swift): tier → Standard / Optimized Exact / Optimized Fast cells. Empty in a schema-1 file,
    /// whose `precisions` are then the only figures.
    public var tiers: [ModelTier: TierBenchmark] = [:]
    /// Codable covers the schema-1 fields; `decodeBenchmarks` reads the tiers.
    enum CodingKeys: String, CodingKey { case precisions, recommended, noise_pt, tolerance_pt }
    public init(precisions: [String: PrecisionResult], recommended: String? = nil, noise_pt: Double? = nil, tolerance_pt: Double? = nil,
                tiers: [ModelTier: TierBenchmark] = [:]) {
        self.precisions = precisions; self.recommended = recommended; self.noise_pt = noise_pt; self.tolerance_pt = tolerance_pt
        self.tiers = tiers
    }
    /// A schema-2 family: its tiers, with `precisions` derived for the per-precision readers.
    public init(tiers: [ModelTier: TierBenchmark], noise_pt: Double? = nil, tolerance_pt: Double? = nil) {
        self.init(precisions: legacyPrecisions(tiers), noise_pt: noise_pt, tolerance_pt: tolerance_pt, tiers: tiers)
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
        if let rawTiers = (value as? [String: Any])?["tiers"] as? [String: Any] {
            var tiers: [ModelTier: TierBenchmark] = [:]
            for (key, raw) in rawTiers { if let tier = ModelTier(rawValue: key), let t = decodeTier(raw) { tiers[tier] = t } }
            let entry = value as? [String: Any]
            file.models[id] = FamilyBenchmark(tiers: tiers, noise_pt: (entry?["noise_pt"] as? NSNumber)?.doubleValue,
                                              tolerance_pt: (entry?["tolerance_pt"] as? NSNumber)?.doubleValue)
            continue
        }
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
