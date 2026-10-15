import Foundation
import VellaWire

// What a model runs: tier (precision kept) × the Exact/Fast switch, on the optimized path. Shared by the Models table
// (VellaCore/Benchmarks cells), config.json (`selections`, written by a successful Load/Reload) and the runtime
// (ModelRef.selection → the worker's recipe). Since 2.1 the path is not a choice (Toby, 15 Oct: "we should just have
// the lightning option"): every request is Optimized and the worker's gate falls back to stock MLX by itself when the
// self-test fails or the GPU lacks the kernels' family. `path` survives only to describe what a fallen-back worker
// actually runs (`effectiveSelection`) and to keep config.json readable by the previous version.

/// How much precision is kept: 16 (the checkpoint's own bf16/fp16), 8 (affine-8 g64), 4 (affine-4 g64 or vendor
/// QAT 4-bit). fp32 is never a tier.
public enum ModelTier: String, Codable, CaseIterable, Comparable, Sendable {
    case t16 = "16", t8 = "8", t4 = "4"
    public var bits: Int { Int(rawValue)! }
    public static func < (a: ModelTier, b: ModelTier) -> Bool { a.bits > b.bits } // 16 first
}

/// What actually runs: Optimized (per-layer recipe + our kernels, the only request) or Standard (stock MLX, what a worker
/// runs after its gate fell back). Never chosen by the user, the API or the CLI.
public enum EnginePath: String, Codable, CaseIterable, Sendable { case standard, optimized }

/// The Exact/Fast switch: Exact = only kernels whose output is identical to Standard; Fast = adds gate-passing
/// inexact kernels.
public enum OptimizedMode: String, Codable, CaseIterable, Sendable { case exact, fast }

/// A benchmarks.json cell key within a tier.

public struct ModelSelection: Codable, Equatable, Hashable, Sendable {
    public var tier: ModelTier
    /// `.optimized` for every request; `.standard` only on an effective selection (`effectiveSelection`).
    public var path: EnginePath
    /// The switch position.
    public var mode: OptimizedMode
    public init(tier: ModelTier, path: EnginePath, mode: OptimizedMode) { self.tier = tier; self.path = path; self.mode = mode }
    /// A request: the optimized path at this tier and switch position.
    public init(tier: ModelTier, mode: OptimizedMode) { self.init(tier: tier, path: .optimized, mode: mode) }
    /// Nothing chosen yet: 16 · Fast.
    public static let fallback = ModelSelection(tier: .t16, mode: .fast)
    /// The request this selection stands for: the same tier and switch position on the optimized path.
    public var request: ModelSelection { ModelSelection(tier: tier, mode: mode) }

    enum CodingKeys: String, CodingKey { case tier, path, mode }
    /// Every stored selection is a request (config.json `selections`, the launch set, worker status), so decoding
    /// always yields the optimized path: a 2.0 Standard choice migrates to the optimized request at the same tier and
    /// switch position, and the worker's gate still falls back to stock MLX where it must. A missing or unknown `path`
    /// decodes the same way.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decode(ModelTier.self, forKey: .tier)
        mode = try c.decode(OptimizedMode.self, forKey: .mode)
        path = .optimized
    }
    /// `path` stays in the file (always `optimized` for a request) so the previous version still reads config.json.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tier, forKey: .tier); try c.encode(path, forKey: .path); try c.encode(mode, forKey: .mode)
    }
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
