import Foundation
import VellaWire

/// The one rule for which tier × Standard/Optimized × Exact/Fast cells of a family exist and can run, over the catalog
/// (offered tiers) and the measured numbers (benchmarks.json). The Models table, the runtime's on-demand loads and the
/// API (and through it `vella`) all ask this, so a recorded selection that is no longer offered or not measured never
/// runs anywhere: it resolves to the cell the table shows. A loaded model is outside the rule (its cell stays
/// selectable where it is shown); callers check that first.
public struct SelectionRules {
    public let family: ModelFamily
    public let benchmark: FamilyBenchmark?
    public init(family: ModelFamily, benchmark: FamilyBenchmark?) { self.family = family; self.benchmark = benchmark }

    /// The same disabled-cell reason in the table and authenticated model controls.
    public func cellRefusal(_ s: ModelSelection, loaded: ModelSelection? = nil) -> String? {
        if s.path == .optimized, !hasOptimizedPath { return noOptimizedPathHelp }
        if !isPresent(s) {
            // Malformed gate data (no readable presence verdict) is the one data reason a cell is not offered.
            if let gate = benchmark?.tiers[s.tier]?.cells[s.segmentKey]?.gate, gate.presence == nil,
                let reason = gate.reasons.first, !reason.isEmpty
            {
                return "Not offered: " + reason
            }
            if s.path == .optimized, s.mode == .exact, precisions(.fast).contains(s.tier) {
                return exactRecipeMissingHelp(tierDTypeLabel(family, s.tier))
            }
            return tierAbsentHelp(benchmark, tier: s.tier)
        }
        if !measured(s), s != loaded { return unmeasuredReasonHelp(benchmarkCell(benchmark, s)) }
        return nil
    }

    var options: [String] { precisionOptions(family) }
    /// Offered tiers (catalog `tiers_offered`).
    var offeredTiers: [ModelTier] { ModelTier.allCases.filter { precisionLabel(family, tier: $0).map(options.contains) ?? false } }
    /// Tiers a row offers: the catalog's options whose cell is present (`cellPresent`, the one presence rule).
    public func tiers(_ path: EnginePath) -> [ModelTier] {
        let segment: Recipe = path == .standard ? .standard : .optimized_exact
        return offeredTiers.filter { cellPresent(benchmark, tier: $0, segment: segment) }
    }
    /// The Optimized row's segments for a switch position (family coupling rule): Exact offers the tiers with an
    /// Optimized Exact recipe (bit-identical to Standard), Fast those with an Optimized Fast one; where Fast = Exact
    /// (greyed switch) either recipe counts. A model without any Optimized recipe offers its Standard tiers.
    public func precisions(_ mode: OptimizedMode) -> [ModelTier] {
        guard hasOptimizedPath else { return tiers(.standard) }
        let keys: [Recipe] = !switchAvailable ? [.optimized_exact, .optimized_fast] : mode == .exact ? [.optimized_exact] : [.optimized_fast]
        return offeredTiers.filter { tier in keys.contains { cellPresent(benchmark, tier: tier, segment: $0) } }
    }
    /// A cell has numbers (family rule, 29 Sep: a cell or switch position without a measurement is unavailable, never a
    /// row of dashes). Families without tiers in the file (unmeasured catalog) count as measured, so they stay usable.
    public func measured(_ s: ModelSelection) -> Bool {
        guard let b = benchmark, !b.tiers.isEmpty else { return true }
        guard let cell = benchmarkCell(b, s) else { return false }
        return !cell.isPending
    }
    /// The model has an Optimized row (and so the Exact/Fast switch); every shipped Vella model does.
    public var hasOptimizedPath: Bool {
        offeredTiers.contains { tier in [Recipe.optimized_exact, .optimized_fast].contains { cellPresent(benchmark, tier: tier, segment: $0) } }
    }
    public func isPresent(_ s: ModelSelection) -> Bool {
        if benchmark?.tiers[s.tier]?.cells[s.segmentKey]?.gate != nil,
            !cellPresent(benchmark, tier: s.tier, segment: s.segmentKey)
        {
            return false
        }
        if s.path == .standard { return tiers(.standard).contains(s.tier) }
        return hasOptimizedPath && precisions(s.mode).contains(s.tier)
    }
    /// The Exact/Fast switch is live: some offered tier's Fast recipe runs an inexact component. Unmeasured families
    /// (no tiers in the file) keep it live.
    public var switchAvailable: Bool {
        guard let b = benchmark, !b.tiers.isEmpty else { return true }
        return fastDiffersFromExact(b)
    }
    /// `s` when its cell is present and measured, else the Optimized cell at its tier (its switch position, then the
    /// other), else Standard at that tier, then the same at 16, 8, 4; `s` itself when nothing qualifies.
    public func valid(_ s: ModelSelection) -> ModelSelection {
        let ok: (ModelSelection) -> Bool = { isPresent($0) && measured($0) }
        if ok(s) { return s }
        for tier in [s.tier] + ModelTier.allCases {
            for mode in [s.mode, s.mode == .fast ? .exact : .fast] {
                let optimized = ModelSelection(tier: tier, path: .optimized, mode: mode)
                if hasOptimizedPath, ok(optimized) { return optimized }
            }
            let standard = ModelSelection(tier: tier, path: .standard, mode: s.mode)
            if ok(standard) { return standard }
        }
        return s
    }
    /// What an unloaded family runs: the recorded selection (config.json `selections`) at the recorded precision (the
    /// mode's model or `lastLoaded`), else Optimized 16 · Fast, made valid. `available` (a precision's weights are on
    /// this Mac) keeps a working setup working: the valid cell when its weights are here, else the first valid cell whose
    /// weights are (the same order as `valid`). Installed weights never make a rejected cell runnable; when no offered
    /// cell's weights are available, return the valid choice and let the caller explain that Get or Load is needed.
    public func runnable(recorded: ModelSelection?, precision: String?, available: ((String) -> Bool)? = nil) -> ModelSelection {
        let candidate = precision.map { defaultSelection(recorded: recorded, precision: $0) } ?? recorded ?? .fallback
        let chosen = valid(candidate)
        guard let available, let label = self.precision(of: chosen), !available(label) else { return chosen }
        for tier in [candidate.tier] + ModelTier.allCases {
            var probe = candidate; probe.tier = tier
            let cell = valid(probe)
            if cell.tier == tier, let label = self.precision(of: cell), available(label) { return cell }
        }
        if let precision, available(precision), modelTier(ofPrecision: precision) == candidate.tier,
            isPresent(candidate), measured(candidate)
        {
            return candidate
        }
        return chosen
    }
    /// The catalog precision label that runs a selection (nil when its tier has no offered variant).
    public func precision(of s: ModelSelection) -> String? {
        precisionLabel(family, tier: s.tier).flatMap { options.contains($0) ? $0 : nil }
    }
}
