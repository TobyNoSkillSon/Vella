import Foundation

public struct ModelRecommendation: Codable, Identifiable {
    public var id: String
    public var name: String
    public var quantization: String
    public var repository: String
    public var revision: String
    public var downloadBytes: Int64
    public var architecture: String
    public var license: String
    public var recommendation: String
    public var recommended: Bool?
    public init(id: String, name: String, quantization: String, repository: String, revision: String, downloadBytes: Int64, architecture: String, license: String, recommendation: String, recommended: Bool? = nil) {
        self.id = id; self.name = name; self.quantization = quantization; self.repository = repository
        self.revision = revision; self.downloadBytes = downloadBytes; self.architecture = architecture
        self.license = license; self.recommendation = recommendation; self.recommended = recommended
    }
}
public struct InstalledModel: Codable {
    public var path: String
    public var revision: String?
    public var name: String?
    public var quantization: String?
    public init(path: String, revision: String? = nil, name: String? = nil, quantization: String? = nil) {
        self.path = path; self.revision = revision; self.name = name; self.quantization = quantization
    }
}
public struct BenchmarkClip: Codable, Identifiable {
    public let id: String
    public let reference: String
    public let lexicalReference: String?
    public let transcript: String
    public let duration: Double
    public let seconds: Double
    public let errors: Int
    public let referenceWords: Int
    public let allSeconds: [Double]
    public let repeatTextIdentical: Bool
}
public struct BenchmarkResult: Codable, Identifiable {
    public var id: String { modelID }
    public let modelID: String
    public let modelFingerprint: String
    public let modelName: String
    public let quantization: String
    public let suiteID: String
    public let suiteHash: String
    public let machine: String
    public let machineMemoryBytes: Int64
    public let mlxAudioVersion: String
    public let mlxVersion: String
    public let measuredAt: String
    public let repeats: Int
    public let audioSeconds: Double
    public let transcriptionSeconds: Double
    public let realtimeFactor: Double
    public let wordErrorRate: Double
    public let peakProcessBytes: Int64
    public let peakMLXBytes: Int64?
    public let runtimePeakMLXBytes: Int64?
    public let clips: [BenchmarkClip]
    public let note: String
    public let formatting: FormattingResult?
    /// Legacy records are batch/dictation. Streaming needs its own measured path.
    public let recognitionMode: RecognitionMode?
    public let streamingQualified: Bool?
    public let streamingWorkerSHA256: String?
    public let complete: Bool?
    public let measurementKind: String?
    /// An estimate for this benchmark range only; never a real completion percentage.
    public func estimatedSeconds(for audioSeconds: Double) -> Double? {
        guard !clips.isEmpty, audioSeconds > 0,
              let minLength = clips.map(\.duration).min(), let maxLength = clips.map(\.duration).max(),
              audioSeconds >= minLength, audioSeconds <= maxLength else { return nil }
        let n = Double(clips.count)
        let meanX = clips.map(\.duration).reduce(0, +) / n
        let meanY = clips.map(\.seconds).reduce(0, +) / n
        let denominator = clips.map { pow($0.duration - meanX, 2) }.reduce(0, +)
        guard denominator > 0 else { return nil }
        let slope = max(0, clips.map { ($0.duration - meanX) * ($0.seconds - meanY) }.reduce(0, +) / denominator)
        return max(0.05, max(0, meanY - slope * meanX) + slope * audioSeconds)
    }
}

public enum ModelSortColumn: String, CaseIterable {
    case name, quantization, errorRate, formattedError, speed, memory
}
/// Missing measurements always sort last, in either direction.
public func sortedRecommendations(_ models: [ModelRecommendation], results: [String: BenchmarkResult], column: ModelSortColumn, ascending: Bool) -> [ModelRecommendation] {
    models.sorted { a, b in
        let left = results[a.id], right = results[b.id]
        func compare(_ x: Double?, _ y: Double?) -> Bool {
            if x == nil || y == nil {
                if x == nil && y == nil { return a.id < b.id }
                return x != nil
            }
            if x == y { return a.id < b.id }
            return ascending ? x! < y! : x! > y!
        }
        switch column {
        case .name:
            let x = a.name + a.quantization, y = b.name + b.quantization
            return x == y ? a.id < b.id : ascending ? x < y : x > y
        case .quantization: return ascending ? a.quantization < b.quantization : a.quantization > b.quantization
        case .errorRate: return compare(left?.wordErrorRate, right?.wordErrorRate)
        case .formattedError: return compare(left?.formatting?.formattedCharacterErrorRate, right?.formatting?.formattedCharacterErrorRate)
        case .speed: return compare(left?.realtimeFactor, right?.realtimeFactor)
        case .memory: return compare(left?.runtimePeakMLXBytes.map(Double.init), right?.runtimePeakMLXBytes.map(Double.init))
        }
    }
}

/// Exact chip, nearest tier in its generation, then the measured M5 Max baseline.
/// Hardware provenance remains unchanged, including for fallback results.
public func preferredBenchmark(_ candidates: [BenchmarkResult], processor: String) -> BenchmarkResult? {
    func normalized(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "apple ", with: "").trimmingCharacters(in: .whitespaces) }
    func generation(_ value: String) -> String? {
        let value = normalized(value)
        guard let range = value.range(of: #"\bm[0-9]+\b"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }
    func tier(_ value: String) -> Int {
        let value = normalized(value)
        return value.contains("ultra") ? 3 : value.contains("max") ? 2 : value.contains("pro") ? 1 : 0
    }
    func rank(_ value: String) -> Int {
        if normalized(value) == normalized(processor) { return 0 }
        if let target = generation(processor), generation(value) == target { return 10 + abs(tier(value) - tier(processor)) }
        if normalized(value) == "m5 max" { return 20 }
        return 30
    }
    return candidates.filter { rank($0.machine) < 30 }.sorted {
        if rank($0.machine) != rank($1.machine) { return rank($0.machine) < rank($1.machine) }
        if $0.repeats != $1.repeats { return $0.repeats > $1.repeats }
        if $0.audioSeconds != $1.audioSeconds { return $0.audioSeconds > $1.audioSeconds }
        if $0.measuredAt != $1.measuredAt { return $0.measuredAt > $1.measuredAt }
        return $0.machine < $1.machine
    }.first
}

public struct FormattingResult: Codable {
    public let scoringVersion: String
    public let scorerSHA256: String?
    public let lexicalNormalizerSHA256: String?
    public let matchedWordCoverage: Double?
    public let boundaryCoverage: Double?
    public let punctuationCoverage: Double?
    public let formattedCharacterErrorRate: Double
    public let capitalizationAccuracy: Double?
    public let punctuationF1: Double?
    public let quotationF1: Double?
    public let quotedReferenceClips: Int
}

// MARK: benchmarks.json schema 2: tiers × Standard / Optimized Exact / Optimized Fast (models-table round, 29 Sep)
//
// models.<id>.tiers.<"16"|"8"|"4"> = { precision, presence {offered, reasons}, gate {status, reasons, loss},
//                                      standard, optimized_exact, optimized_fast }
// Written by lab/bench/measure_catalog.py from gate_check.py's verdicts. A cell without `measured` is "measure pending".

/// Whether a tier is offered at all (presence gate, separate from the recommendation gate): absent only when it breaks
/// against 16 (lost clips, errors, +5 pt English or multilingual-mean WER, +10 pt in one language).
public struct TierPresence: Codable, Equatable {
    public var offered: Bool
    public var reasons: [String]
    public init(offered: Bool, reasons: [String] = []) { self.offered = offered; self.reasons = reasons }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offered = try c.decode(Bool.self, forKey: .offered)
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
    }
}

public enum GateStatus: String, Codable, Equatable { case pass, fail, borderline }

/// The recommendation gate's verdict for a tier (vs 16) or a cell. `loss`: the failed checks as bare losses vs 16
/// (`multilingual mean +0.55 pt`), stated in an offered-but-worse tier's tooltip.
public struct SegmentGate: Codable, Equatable {
    public var status: GateStatus
    public var reasons: [String]
    public var loss: [String]
    public init(status: GateStatus, reasons: [String] = [], loss: [String] = []) { self.status = status; self.reasons = reasons; self.loss = loss }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(GateStatus.self, forKey: .status)) ?? .fail
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
        loss = (try? c.decodeIfPresent([String].self, forKey: .loss)) ?? []
    }
}

/// What a cell runs: per-layer-group formats (`all` → `bf16`, `affine-8 g64`, …), the optimized components and which of
/// them are inexact, the gate revision (`stock` for Standard), and the source dtype of a converted 16 tier.
public struct CellRecipe: Codable, Equatable {
    public var layers: [String: String]
    public var kernels: [String]
    public var inexact: [String]
    public var gate_revision: String?
    public var converted_from: String?
    public init(layers: [String: String], kernels: [String] = [], inexact: [String] = [], gate_revision: String? = nil, converted_from: String? = nil) {
        self.layers = layers; self.kernels = kernels; self.inexact = inexact; self.gate_revision = gate_revision; self.converted_from = converted_from
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = (try? c.decodeIfPresent([String: String].self, forKey: .layers)) ?? [:]
        kernels = (try? c.decodeIfPresent([String].self, forKey: .kernels)) ?? []
        inexact = (try? c.decodeIfPresent([String].self, forKey: .inexact)) ?? []
        gate_revision = try? c.decodeIfPresent(String.self, forKey: .gate_revision)
        converted_from = try? c.decodeIfPresent(String.self, forKey: .converted_from)
    }
}

public struct CellMeasured: Codable, Equatable {
    public var hardware: String?
    public var date: String?
    public var suite: String?
    public var audio_min: Double?
    public var performance_suite: String?
    public init(hardware: String? = nil, date: String? = nil, suite: String? = nil, audio_min: Double? = nil, performance_suite: String? = nil) {
        self.hardware = hardware; self.date = date; self.suite = suite; self.audio_min = audio_min; self.performance_suite = performance_suite
    }
}

/// One cell: its figures (a PrecisionResult carrying the metric set, provenance and note), recipe, provenance and gate.
/// `measured == nil` = measure pending (every figure `—`).
public struct BenchmarkCell: Equatable {
    public var result: PrecisionResult
    public var recipe: CellRecipe
    public var measured: CellMeasured?
    public var gate: SegmentGate?
    public init(result: PrecisionResult = PrecisionResult(), recipe: CellRecipe, measured: CellMeasured? = nil, gate: SegmentGate? = nil) {
        self.result = result; self.recipe = recipe; self.measured = measured; self.gate = gate
    }
    public var isPending: Bool { measured == nil }
}

public struct TierBenchmark: Equatable {
    /// The catalog precision label of this tier (`BF16`, `FP16`, `8b`, `4b`).
    public var precision: String
    public var presence: TierPresence
    public var gate: SegmentGate
    public var cells: [SegmentKey: BenchmarkCell]
    public init(precision: String, presence: TierPresence = TierPresence(offered: true), gate: SegmentGate = SegmentGate(status: .pass),
                cells: [SegmentKey: BenchmarkCell]) {
        self.precision = precision; self.presence = presence; self.gate = gate; self.cells = cells
    }
    public func cell(_ key: SegmentKey) -> BenchmarkCell? { cells[key] }
}

/// THE presence rule of the Models table (one function, data-driven; ROUND file, family-wide): a cell shows when its
/// tier's `presence.offered` is true and the file has that cell (its recipe exists). A tier that breaks against 16 is
/// absent on both rows; absent cells are omitted, never greyed. A family the file does not describe at all (no tiers:
/// an unmeasured build) shows every cell as pending.
public func cellPresent(_ benchmark: FamilyBenchmark?, tier: ModelTier, segment: SegmentKey) -> Bool {
    guard let benchmark, !benchmark.tiers.isEmpty else { return true }
    guard let t = benchmark.tiers[tier], t.presence.offered else { return false }
    return t.cells[segment] != nil
}

/// Fast differs from Exact for this family: some offered tier's Fast recipe runs an inexact component. False greys the
/// Exact/Fast switch ("Fast measures the same as Exact").
public func fastDiffersFromExact(_ benchmark: FamilyBenchmark?) -> Bool {
    guard let benchmark else { return false }
    return benchmark.tiers.values.contains { $0.presence.offered && !($0.cells[.optimized_fast]?.recipe.inexact.isEmpty ?? true) }
}

/// The cell a selection shows: its segment's cell; Fast without an inexact component is the Exact cell (the same recipe).
public func benchmarkCell(_ benchmark: FamilyBenchmark?, _ selection: ModelSelection) -> BenchmarkCell? {
    guard let tier = benchmark?.tiers[selection.tier] else { return nil }
    if selection.segmentKey == .optimized_fast, let fast = tier.cells[.optimized_fast], fast.recipe.inexact.isEmpty {
        return tier.cells[.optimized_exact] ?? fast
    }
    return tier.cells[selection.segmentKey]
}

/// Decodes one schema-2 tier; nil when malformed.
func decodeTier(_ raw: Any) -> TierBenchmark? {
    guard let object = raw as? [String: Any], let precision = object["precision"] as? String else { return nil }
    func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    var cells: [SegmentKey: BenchmarkCell] = [:]
    for key in SegmentKey.allCases {
        guard let c = object[key.rawValue] as? [String: Any], var result = decode(PrecisionResult.self, c) else { continue }
        let measured = decode(CellMeasured.self, c["measured"])
        result.suite = measured?.suite; result.audio_min = measured?.audio_min
        result.date = measured?.date; result.hardware = measured?.hardware
        result.gate = nil   // the cell's gate has the schema-2 shape (below)
        cells[key] = BenchmarkCell(result: result, recipe: decode(CellRecipe.self, c["recipe"]) ?? CellRecipe(layers: [:]),
                                   measured: measured, gate: decode(SegmentGate.self, c["gate"]))
    }
    return TierBenchmark(precision: precision, presence: decode(TierPresence.self, object["presence"]) ?? TierPresence(offered: true),
                         gate: decode(SegmentGate.self, object["gate"]) ?? SegmentGate(status: .pass), cells: cells)
}

/// The per-precision view older consumers read (recommendation, sort keys, API, diagnostics): each offered tier's
/// shipping cell (Optimized · Fast, else Exact, else Standard) under its catalog label, with the Standard cell as
/// `stock` and the tier gate as `gate`.
func legacyPrecisions(_ tiers: [ModelTier: TierBenchmark]) -> [String: PrecisionResult] {
    var out: [String: PrecisionResult] = [:]
    for tier in tiers.values where tier.presence.offered {
        let shipping = [SegmentKey.optimized_fast, .optimized_exact, .standard].compactMap { tier.cells[$0] }.first { !$0.isPending }
        guard var r = shipping?.result else { continue }
        r.gate = GateResult(pass: tier.gate.status == .pass, reasons: tier.gate.reasons)
        if let s = tier.cells[.standard], !s.isPending {
            let x = s.result
            r.stock = StockBaseline(wer: x.wer, format: x.format, multilingual: x.multilingual, speed_x: x.speed_x, j_per_min: x.j_per_min,
                                    memory_mb: x.memory_mb, latency_ms: x.latency_ms, suite: x.suite, date: x.date, hardware: x.hardware)
        }
        out[tier.precision] = r
    }
    return out
}
