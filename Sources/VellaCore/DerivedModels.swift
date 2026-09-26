import Foundation

// Locally derived precisions (Toby, 26 Sep 2026: every offered model gets every level from its native precision down to
// 4 bits, made locally, no hosting). A derived variant names its source precision in the same family and a recipe:
//   cast:     {"id": "…", "derivedFrom": "FP32", "dtype": "bfloat16", "architecture": "parakeet"}
//   quantize: {"id": "…", "derivedFrom": "BF16", "bits": 8, "groupSize": 64, "architecture": "parakeet"}
// Get downloads only the source (the root of the chain). Load hands the worker a small directory holding
// `vella-derived.json` (source path + composed recipe); the worker derives the precision tensor by tensor at load.
// The model path therefore differs per precision, so the worker's identity, fast-path gate key and residency stay
// per precision.

/// The composed recipe from the downloadable root to a derived precision: an optional float cast, then an optional
/// affine quantization (always last; never twice).
public struct DerivationRecipe: Equatable {
    public var sourceLabel: String
    public var source: CatalogVariant
    public var dtype: String?
    public var bits: Int?
    public var groupSize: Int?
}

public enum DerivationError: Error, Equatable, CustomStringConvertible {
    case notDerived(String), missingSource(String), cycle(String), invalid(String)
    public var description: String {
        switch self {
        case .notDerived(let s): return "\(s) is not a derived precision."
        case .missingSource(let s): return "The source precision of \(s) is not in the catalog."
        case .cycle(let s): return "Derivation cycle at \(s)."
        case .invalid(let s): return s
        }
    }
}

public let derivedQuantizationBits: Set<Int> = [4, 8]
public let derivedGroupSizes: Set<Int> = [32, 64, 128]
/// Cast targets and the exact label each must carry (BF16 ≠ FP16).
public let derivedCastLabels: [String: String] = ["bfloat16": "BF16", "float16": "FP16"]

public extension ModelFamily {
    /// True when the precision is derived locally rather than downloaded.
    func isDerived(_ label: String) -> Bool { variants[label]?.isDerived == true }

    /// The downloadable variant a precision comes from (itself when downloaded). Get downloads this id; the derived
    /// precision counts as downloaded exactly when this one is installed.
    func downloadSource(of label: String) -> (label: String, variant: CatalogVariant)? {
        (try? derivation(label)).map { ($0.sourceLabel, $0.source) } ?? variants[label].flatMap { $0.isDerived ? nil : (label, $0) }
    }

    /// Bytes on disk for a precision: a derived precision stores nothing of its own, so it is its source's files.
    func diskBytes(_ label: String) -> Int64? { downloadSource(of: label)?.variant.downloadBytes }

    /// Resolves and validates a derived precision's chain to its downloadable root.
    func derivation(_ label: String) throws -> DerivationRecipe {
        guard let start = variants[label], start.isDerived else { throw DerivationError.notDerived(label) }
        var steps: [(String, CatalogVariant)] = []
        var seen: Set<String> = []
        var current = label
        while let v = variants[current], v.isDerived {
            guard seen.insert(current).inserted else { throw DerivationError.cycle(current) }
            steps.append((current, v))
            guard let from = v.derivedFrom, variants[from] != nil else { throw DerivationError.missingSource(current) }
            current = from
        }
        guard let root = variants[current] else { throw DerivationError.missingSource(label) }
        var recipe = DerivationRecipe(sourceLabel: current, source: root)
        var bitsSoFar = labelBits(current) ?? 0
        // Apply from the root outwards.
        for (stepLabel, v) in steps.reversed() {
            guard v.architecture == root.architecture else { throw DerivationError.invalid("\(stepLabel): architecture differs from its source.") }
            guard let targetBits = labelBits(stepLabel), targetBits < bitsSoFar else {
                throw DerivationError.invalid("\(stepLabel): derived precisions only go down in bits (never upscale).")
            }
            switch (v.dtype, v.bits) {
            case let (dtype?, nil):
                guard derivedCastLabels[dtype] == stepLabel, v.groupSize == nil else { throw DerivationError.invalid("\(stepLabel): cast \(dtype) must be labelled \(derivedCastLabels[dtype] ?? "?").") }
                guard recipe.bits == nil else { throw DerivationError.invalid("\(stepLabel): cannot cast a quantized model.") }
                recipe.dtype = dtype
            case let (nil, bits?):
                guard derivedQuantizationBits.contains(bits), stepLabel == "\(bits)b" else { throw DerivationError.invalid("\(stepLabel): quantization must be 4 or 8 bits and labelled so.") }
                guard let g = v.groupSize, derivedGroupSizes.contains(g) else { throw DerivationError.invalid("\(stepLabel): group size must be 32, 64 or 128.") }
                guard recipe.bits == nil else { throw DerivationError.invalid("\(stepLabel): cannot quantize twice.") }
                recipe.bits = bits; recipe.groupSize = g
            default:
                throw DerivationError.invalid("\(stepLabel): a derived variant is either a cast (dtype) or a quantization (bits, groupSize).")
            }
            bitsSoFar = targetBits
        }
        return recipe
    }

    /// Every problem with the family's derived variants (empty = valid). Used by catalog tests.
    func derivationProblems() -> [String] {
        variants.keys.sorted().compactMap { label in
            guard isDerived(label) else { return nil }
            do { _ = try derivation(label); return nil } catch { return "\(id) \(label): \(error)" }
        }
    }
}

// MARK: Worker manifest

/// The file a derived model directory holds instead of weights. Keys mirror the worker's parser
/// (Worker/Sources/MLXAudioSTT/DerivedPrecision.swift); keep them in step.
public struct DerivedModelManifest: Codable, Equatable {
    public static let fileName = "vella-derived.json"
    public var schema: Int
    public var family: String
    public var precision: String
    /// Absolute path of the installed source model directory.
    public var source: String
    public var sourceVariant: String
    public var sourcePrecision: String
    public var dtype: String?
    public var bits: Int?
    public var groupSize: Int?
}

/// Writes (idempotently) `<modelsDirectory>/<derived id>/vella-derived.json` for a derived precision whose source is
/// installed at `sourcePath`, and returns that directory's path: the model path to hand the worker for Load/Reload.
public func prepareDerivedModel(family: ModelFamily, precision: String, sourcePath: String, modelsDirectory: URL) throws -> String {
    guard let variant = family.variants[precision], variant.isDerived else { throw DerivationError.notDerived(precision) }
    let recipe = try family.derivation(precision)
    guard sourcePath.hasPrefix("/") else { throw DerivationError.invalid("The source path must be absolute.") }
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: source.appendingPathComponent("config.json").path) else {
        throw DerivationError.invalid("The source model of \(family.name) \(precision) is not installed.")
    }
    let manifest = DerivedModelManifest(schema: 1, family: family.id, precision: precision, source: source.path, sourceVariant: recipe.source.id,
                                        sourcePrecision: recipe.sourceLabel, dtype: recipe.dtype, bits: recipe.bits, groupSize: recipe.groupSize)
    let directory = modelsDirectory.appendingPathComponent(variant.id, isDirectory: true).standardizedFileURL
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    // Never mix a manifest into a directory holding anything else (a real install must not be shadowed).
    let others = try fm.contentsOfDirectory(atPath: directory.path).filter { $0 != DerivedModelManifest.fileName && $0 != ".DS_Store" }
    guard others.isEmpty else { throw DerivationError.invalid("\(directory.path) is not a derived model directory.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    let file = directory.appendingPathComponent(DerivedModelManifest.fileName)
    if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
    return directory.path
}

/// Reads a derived model directory's manifest (nil when the directory is not a derived model).
public func derivedModelManifest(at directory: URL) -> DerivedModelManifest? {
    (try? Data(contentsOf: directory.appendingPathComponent(DerivedModelManifest.fileName))).flatMap { try? JSONDecoder().decode(DerivedModelManifest.self, from: $0) }
}

/// Deletes the derived model directories whose source is `sourcePath` (call after deleting that source). Only
/// directories holding nothing but the manifest are removed. Returns the removed paths.
@discardableResult
public func removeDerivedModels(sourcePath: String, modelsDirectory: URL) -> [String] {
    let fm = FileManager.default
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
    guard let entries = try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else { return [] }
    return entries.compactMap { dir in
        guard let manifest = derivedModelManifest(at: dir), manifest.source == source,
              let files = try? fm.contentsOfDirectory(atPath: dir.path),
              files.allSatisfy({ $0 == DerivedModelManifest.fileName || $0 == ".DS_Store" }),
              (try? fm.removeItem(at: dir)) != nil else { return nil }
        return modelsDirectory.appendingPathComponent(dir.lastPathComponent).standardizedFileURL.path
    }
}

// MARK: Memory estimate for admission

/// Memory for admission: the measured figure when benchmarks.json has one, else an estimate scaled by weight size from
/// a measured precision of the same family (`measured` false, `note` says so). Nil when no precision is measured.
public struct MemoryEstimate: Equatable {
    public var mb: Double
    public var measured: Bool
    public var note: String?
}

/// Share of a checkpoint's weight bytes held by quantizable Linear/Embedding layers. Parakeet v3/Ultra and
/// Nemotron 0.6B measure ≈ 0.85–0.9 (the published Nemotron 8b is 0.592 of its BF16 source; this gives 0.599).
public let quantizableWeightShare = 0.85

/// Estimated weight bytes of a precision: published → its download; derived → the source scaled by bits per weight
/// (quantized: bits + 32/groupSize for 16-bit scales and biases) over the quantizable share.
public func estimatedWeightBytes(_ family: ModelFamily, _ label: String) -> Double? {
    guard let v = family.variants[label] else { return nil }
    if !v.isDerived { return Double(v.downloadBytes) }
    guard let recipe = try? family.derivation(label), let rootBits = labelBits(recipe.sourceLabel) else { return nil }
    let root = Double(recipe.source.downloadBytes)
    let floatBits = recipe.dtype.flatMap { derivedCastLabels[$0] }.flatMap(labelBits) ?? rootBits
    let floatBytes = root * floatBits / rootBits
    guard let bits = recipe.bits, let g = recipe.groupSize else { return floatBytes }
    let quantBits = Double(bits) + 32 / Double(g)
    return floatBytes * (quantizableWeightShare * quantBits / floatBits + (1 - quantizableWeightShare))
}

public func estimatedMemory(family: ModelFamily, precision: String, benchmarks: BenchmarkFile) -> MemoryEstimate? {
    let results = benchmarks.models[family.id]
    if let mb = results?.result(precision)?.memory_mb { return MemoryEstimate(mb: mb, measured: true, note: nil) }
    guard let target = estimatedWeightBytes(family, precision) else { return nil }
    // Reference: the derivation's source if measured, else the measured precision closest in bits.
    let measured = (results?.precisions ?? [:]).compactMap { label, r -> (String, Double)? in
        guard let mb = r.memory_mb, family.variants[label] != nil else { return nil }
        return (label, mb)
    }
    let root = family.downloadSource(of: precision)?.label
    let targetBits = labelBits(precision) ?? 0
    guard let reference = measured.first(where: { $0.0 == root }) ?? measured.min(by: {
        abs((labelBits($0.0) ?? 0) - targetBits) < abs((labelBits($1.0) ?? 0) - targetBits)
    }), let referenceBytes = estimatedWeightBytes(family, reference.0), referenceBytes > 0 else { return nil }
    let mb = reference.1 * target / referenceBytes
    return MemoryEstimate(mb: mb, measured: false,
                          note: String(format: "Estimated from the measured %@ memory (%.0f MB) scaled by weight size; %@ not measured.", reference.0, reference.1, precision))
}
