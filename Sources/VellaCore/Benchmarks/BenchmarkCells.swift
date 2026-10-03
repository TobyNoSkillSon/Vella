import Foundation
import VellaWire

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

public enum GateStatus: String, Codable, Equatable {
    case pass, fail, borderline
    case notGated = "not_gated"
}

/// The recommendation gate's verdict for a tier (vs 16) or a cell. `loss`: the failed checks as bare losses vs 16
/// (`multilingual mean +0.55 pt`), stated in an offered-but-worse tier's tooltip.
public struct SegmentGate: Codable, Equatable {
    public var status: GateStatus
    public var reasons: [String]
    public var loss: [String]
    public var presence: TierPresence?
    public init(status: GateStatus, reasons: [String] = [], loss: [String] = [], presence: TierPresence? = nil) {
        self.status = status; self.reasons = reasons; self.loss = loss; self.presence = presence
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(GateStatus.self, forKey: .status)) ?? .fail
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
        loss = (try? c.decodeIfPresent([String].self, forKey: .loss)) ?? []
        presence = try? c.decodeIfPresent(TierPresence.self, forKey: .presence)
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
    public var notMeasuredReason: String?
    public init(result: PrecisionResult = PrecisionResult(), recipe: CellRecipe, measured: CellMeasured? = nil, gate: SegmentGate? = nil, notMeasuredReason: String? = nil) {
        self.result = result; self.recipe = recipe; self.measured = measured; self.gate = gate; self.notMeasuredReason = notMeasuredReason
    }
    public var isPending: Bool { measured == nil }
}

public struct TierBenchmark: Equatable {
    /// The catalog precision label of this tier (`BF16`, `FP16`, `8b`, `4b`).
    public var precision: String
    public var presence: TierPresence
    public var gate: SegmentGate
    public var cells: [Recipe: BenchmarkCell]
    public var displayCells: [Recipe: Recipe] = [:]
    public init(
        precision: String, presence: TierPresence = TierPresence(offered: true), gate: SegmentGate = SegmentGate(status: .pass),
        cells: [Recipe: BenchmarkCell]
    ) {
        self.precision = precision; self.presence = presence; self.gate = gate; self.cells = cells
    }
    public func cell(_ key: Recipe) -> BenchmarkCell? { cells[key] }
}

/// THE presence rule: a cell's gate owns its presence. Only a cell with no gate inherits tier presence.
/// An existing gate without a readable presence verdict fails closed, including JSON null. An unmeasured family shows pending cells.
public func cellPresent(_ benchmark: FamilyBenchmark?, tier: ModelTier, segment: Recipe) -> Bool {
    guard let benchmark, !benchmark.tiers.isEmpty else { return true }
    guard let t = benchmark.tiers[tier], let cell = t.cells[segment] else { return false }
    if let gate = cell.gate { return gate.presence?.offered ?? false }
    return t.presence.offered
}

/// Fast differs from Exact for this family: some offered tier's Fast recipe runs an inexact component. False greys the
/// Exact/Fast switch ("Fast measures the same as Exact").
public func fastDiffersFromExact(_ benchmark: FamilyBenchmark?) -> Bool {
    guard let benchmark else { return false }
    return benchmark.tiers.contains { tier, value in
        cellPresent(benchmark, tier: tier, segment: .optimized_fast) && !(value.cells[.optimized_fast]?.recipe.inexact.isEmpty ?? true)
    }
}

/// The cell a selection shows: its segment's cell; Fast without an inexact component is the Exact cell (the same recipe).
public func benchmarkCell(_ benchmark: FamilyBenchmark?, _ selection: ModelSelection) -> BenchmarkCell? {
    guard let tier = benchmark?.tiers[selection.tier] else { return nil }
    if let canonical = tier.displayCells[selection.segmentKey] { return tier.cells[canonical] }
    if selection.segmentKey == .optimized_fast, let fast = tier.cells[.optimized_fast], fast.recipe.inexact.isEmpty {
        // Equal recipes need not have equal measurement status (Whisper 2.0 withdrew Exact only).
        if let exact = tier.cells[.optimized_exact], !exact.isPending { return exact }
        return fast
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
    var cells: [Recipe: BenchmarkCell] = [:]
    for key in Recipe.allCases {
        guard let c = object[key.rawValue] as? [String: Any], var result = decode(PrecisionResult.self, c) else { continue }
        let measured = decode(CellMeasured.self, c["measured"])
        var gate = decode(SegmentGate.self, c["gate"])
        if c.keys.contains("gate"), gate?.presence == nil {
            let reason = "Unreadable cell presence verdict"
            NSLog("benchmarks: %@ %@ %@ gate has no readable presence verdict; cell not offered", precision, key.rawValue, gate == nil ? "malformed" : "decoded")
            gate = SegmentGate(status: .fail, reasons: [reason], presence: TierPresence(offered: false, reasons: [reason]))
        }
        result.suite = measured?.suite; result.audio_min = measured?.audio_min
        result.date = measured?.date; result.hardware = measured?.hardware
        result.gate = nil // the cell's gate has the schema-2 shape (below)
        cells[key] = BenchmarkCell(
            result: result, recipe: decode(CellRecipe.self, c["recipe"]) ?? CellRecipe(layers: [:]),
            measured: measured, gate: gate, notMeasuredReason: c["not_measured_reason"] as? String)
    }
    var tier = TierBenchmark(
        precision: precision, presence: decode(TierPresence.self, object["presence"]) ?? TierPresence(offered: true),
        gate: decode(SegmentGate.self, object["gate"]) ?? SegmentGate(status: .pass), cells: cells)
    for (requested, canonical) in object["display_cells"] as? [String: String] ?? [:] {
        if let from = Recipe(rawValue: requested), let to = Recipe(rawValue: canonical), cells[to] != nil { tier.displayCells[from] = to }
    }
    return tier
}

/// The per-precision view older consumers read (recommendation, sort keys, API, diagnostics): each offered tier's
/// shipping cell (Optimized · Fast, else Exact, else Standard) under its catalog label, with the Standard cell as
/// `stock` and the tier gate as `gate`.
func legacyPrecisions(_ tiers: [ModelTier: TierBenchmark]) -> [String: PrecisionResult] {
    var out: [String: PrecisionResult] = [:]
    for (key, tier) in tiers {
        let family = FamilyBenchmark(precisions: [:], tiers: tiers)
        let shipping = [Recipe.optimized_fast, .optimized_exact, .standard]
            .filter { cellPresent(family, tier: key, segment: $0) }
            .compactMap { tier.cells[tier.displayCells[$0] ?? $0] }.first { !$0.isPending }
        guard var r = shipping?.result else { continue }
        r.gate = GateResult(pass: tier.gate.status == .pass, reasons: tier.gate.reasons)
        if let s = tier.cells[.standard], !s.isPending {
            let x = s.result
            r.stock = StockBaseline(
                wer: x.wer, format: x.format, multilingual: x.multilingual, speed_x: x.speed_x, j_per_min: x.j_per_min,
                memory_mb: x.memory_mb, latency_ms: x.latency_ms, suite: x.suite, date: x.date, hardware: x.hardware)
        }
        out[tier.precision] = r
    }
    return out
}
