import Foundation
import VellaWire

/// Frozen full-measure defaults, selected per checkpoint and recipe. Unknown cells stay off.
/// Overrides are lab-only: 1 on, 0 off, unset (or another value) uses the default.
public struct KeptLevers: Equatable, Sendable {
    public static let switches = ["VELLA_PARAKEET_INT8", "VELLA_PARAKEET_INT4", "VELLA_PARAKEET_TAILBLOCK",
                                 "VELLA_NEMO_KEEPCACHE", "VELLA_NEMO_JOINTBATCH"]
    public let enabled: Set<String>
    public func contains(_ name: String) -> Bool { enabled.contains(name) }

    public init(family: String, precision: String, recipe: Recipe, environment: [String: String] = [:], forcedStock: Bool = false) {
        var defaults: Set<String> = []
        var applicable: Set<String> = []
        let parakeet = ["parakeet-v3", "parakeet-v3-ultra"].contains(family)
        let nemotron = family == "nemotron-3.5-streaming-0.6b"
        if parakeet {
            applicable = Set(Self.switches.prefix(3))
            if recipe == .optimized_fast {
                if precision == "8b" { defaults.insert(Self.switches[0]) }
                if precision == "4b" { defaults.insert(Self.switches[1]) }
            }
            if family == "parakeet-v3-ultra", ["BF16", "8b", "4b"].contains(precision) { defaults.insert(Self.switches[2]) }
        }
        if nemotron {
            applicable = Set(Self.switches.suffix(2))
            if ["BF16", "8b", "4b"].contains(precision) { defaults.insert(Self.switches[3]) }
            if precision == "BF16", recipe == .optimized_fast { defaults.insert(Self.switches[4]) }
        }
        var selected = Set(applicable.filter { name in
            switch environment[name] {
            case "1": return true
            case "0": return false
            default: return defaults.contains(name)
            }
        })
        if recipe == .optimized_exact { selected.subtract([Self.switches[0], Self.switches[1], Self.switches[4]]) }
        if forcedStock || recipe == .standard { selected.removeAll() }
        enabled = selected
    }

    /// Derived manifests carry the catalog family; native checkpoints use the catalog's installed variant identity.
    /// The lab uses the same source identities. Never infer Ultra from its architecture (v3 has the same config).
    public static func checkpoint(_ path: URL, derived: DerivedPrecision? = nil) throws -> (family: String, precision: String) {
        let derived = try derived ?? DerivedPrecision.resolve(path)
        let source = derived?.source ?? path
        let name = source.lastPathComponent.lowercased()
        let family: String
        if let declared = derived?.family { family = declared }
        else if name.hasPrefix("parakeet-ultra-") { family = "parakeet-v3-ultra" }
        else if name.hasPrefix("parakeet-v3-") || name.hasPrefix("parakeet-tdt-0.6b-v3-") { family = "parakeet-v3" }
        else if name.hasPrefix("nemotron-3.5-streaming-") || name.hasPrefix("nemotron-3.5-asr-streaming-0.6b-") { family = "nemotron-3.5-streaming-0.6b" }
        else { family = "" }
        if let derived { return (family, derived.precision) }
        let configURL = source.appendingPathComponent("config.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] ?? [:]
        let quant = (config["quantization"] ?? config["quantization_config"]) as? [String: Any]
        if let bits = quant?["bits"] as? Int { return (family, "\(bits)b") }
        let precision = name.hasSuffix("-bf16") ? "BF16" : name.hasSuffix("-fp16") ? "FP16" : "unknown"
        return (family, precision)
    }
    public static func resolve(_ path: URL, derived: DerivedPrecision? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> KeptLevers {
        let cell = try checkpoint(path, derived: derived)
        let recipe = environment[Recipe.variable].flatMap(Recipe.init(rawValue:)) ?? .optimized_fast
        let stock = ["VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK"].contains { environment[$0].map { !$0.isEmpty && $0 != "0" } ?? false }
        return KeptLevers(family: cell.family, precision: cell.precision, recipe: recipe, environment: environment,
                          forcedStock: stock || environment["VELLA_MLX_DEVICE"] == "cpu")
    }
}
