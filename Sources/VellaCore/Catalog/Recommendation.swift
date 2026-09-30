import Foundation

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
/// rule (lab/bench/fixtures/recommended_precision.py, cross-checked by CatalogTests).
public func recommendedPrecision(_ benchmark: FamilyBenchmark?, native: String, options: [String]? = nil) -> String? {
    guard let benchmark, let reference = benchmark.result(native)?.wer else { return nil }
    let tolerance = recommendationTolerance(benchmark)
    let measured: [(label: String, result: PrecisionResult)] = benchmark.precisions.compactMap { label, r in
        guard r.wer != nil, options?.contains(label) ?? true,
            passesGate(label, r, native: native, nativeWER: reference, tolerance: tolerance)
        else { return nil }
        return (label, r)
    }
    return measured.min(by: ranksBefore)?.label
}

public func recommendedPrecision(for family: ModelFamily, in benchmarks: BenchmarkFile) -> String? {
    recommendedPrecision(benchmarks.models[family.id], native: family.native, options: precisionOptions(family))
}
