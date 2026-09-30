import Foundation
import VellaWire

// What a model runs: tier (precision kept) × path (Standard = stock MLX, Optimized = our kernels) × the Exact/Fast
// switch. Shared by the Models table (VellaCore/Benchmarks cells), config.json (`selections`, written by a successful
// Load/Reload) and the runtime (ModelRef.selection → the worker's recipe). lab/notes/models-table-ROUND.md.

/// How much precision is kept: 16 (the checkpoint's own bf16/fp16), 8 (affine-8 g64), 4 (affine-4 g64 or vendor
/// QAT 4-bit). fp32 is never a tier.
public enum ModelTier: String, Codable, CaseIterable, Comparable, Sendable {
    case t16 = "16", t8 = "8", t4 = "4"
    public var bits: Int { Int(rawValue)! }
    public static func < (a: ModelTier, b: ModelTier) -> Bool { a.bits > b.bits }   // 16 first
}

/// The segment row: Standard (stock MLX, any Apple-silicon Mac) or Optimized (per-layer recipe + our kernels).
public enum EnginePath: String, Codable, CaseIterable, Sendable { case standard, optimized }

/// The Exact/Fast switch: Exact = only kernels whose output is identical to Standard; Fast = adds gate-passing
/// inexact kernels.
public enum OptimizedMode: String, Codable, CaseIterable, Sendable { case exact, fast }

/// A benchmarks.json cell key within a tier.

public struct ModelSelection: Codable, Equatable, Hashable, Sendable {
    public var tier: ModelTier
    public var path: EnginePath
    /// The switch position; kept on a Standard selection too (the switch is per model, independent of the row).
    public var mode: OptimizedMode
    public init(tier: ModelTier, path: EnginePath, mode: OptimizedMode) { self.tier = tier; self.path = path; self.mode = mode }
    /// Nothing chosen yet: Optimized 16 · Fast (family ruling: fresh installs and on-demand loads never land on Standard;
    /// the table falls back to Standard 16 only where no Optimized 16 cell exists).
    public static let fallback = ModelSelection(tier: .t16, path: .optimized, mode: .fast)
    /// The benchmarks.json cell this selection runs.
    public var segmentKey: Recipe {
        path == .standard ? .standard : mode == .exact ? .optimized_exact : .optimized_fast
    }
}

/// The tier of a catalog precision label: a 16-bit float (`BF16`, `FP16`) → 16, `8b` → 8, `4b` → 4; FP32 and anything
/// else → nil (not a tier).
public func modelTier(ofPrecision label: String) -> ModelTier? {
    switch label.uppercased() {
    case "BF16", "FP16", "F16": return .t16
    case "8B": return .t8
    case "4B": return .t4
    default: return nil
    }
}

/// The family's precision label for a tier: its 16-bit variant (native first, else BF16, else FP16) for 16, `8b`, `4b`.
/// Nil when the catalog has no such variant.
public func precisionLabel(_ family: ModelFamily, tier: ModelTier) -> String? {
    switch tier {
    case .t16:
        return [family.native, "BF16", "FP16"].first { family.variants[$0] != nil && modelTier(ofPrecision: $0) == .t16 }
    case .t8: return family.variants["8b"] != nil ? "8b" : nil
    case .t4: return family.variants["4b"] != nil ? "4b" : nil
    }
}
