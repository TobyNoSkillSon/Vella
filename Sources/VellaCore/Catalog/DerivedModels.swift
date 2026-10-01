import Foundation

// Locally derived precisions (Toby, 29 Sep 2026: always download the 16-bit checkpoint, or the fp32 source of an
// fp32-only model, converted to 16-bit at Get; 8 and 4 are made locally with mx.quantize g64; never quantize from a
// quantized source). A derived variant names its source precision in the same family and a recipe:
//   stored cast: {"id": "…", "derivedFrom": "FP32", "dtype": "bfloat16", "stored": true, "architecture": "parakeet"}
//   quantize:    {"id": "…", "derivedFrom": "BF16", "bits": 8, "groupSize": 64, "architecture": "parakeet"}
// A stored cast is made once at Get (StoredConversion.swift) and kept as a real checkpoint: it is the root that later
// quantizations read. A quantization is one stored manifest per precision: Load hands the worker a small directory
// holding `vella-derived.json` (source path + recipe) and the worker quantizes tensor by tensor at load. The model
// path therefore differs per precision, so the worker's identity, fast-path gate key and residency stay per precision.
// A checkpoint of the variant's exact format already registered under the variant's own id (an earlier download of
// the published quantization) counts as installed and loads directly (`precisionLoadPath`).

/// The composed recipe from the downloadable root to a derived precision: an optional float cast, then an optional
/// affine quantization (always last; never twice).
public struct DerivationRecipe: Equatable {
    public var sourceLabel: String
    public var source: CatalogVariant
    public var dtype: String?
    public var bits: Int?
    public var groupSize: Int?
    /// Float-kept module prefixes of a mixed quantization (empty = uniform).
    public var floatModules: [String] = []
}

/// A mixed recipe's module prefixes: 1–16 unique plain paths (letters, digits, `_`, `.`), the worker's own rule
/// (Worker/Sources/MLXAudioSTT/Precision/DerivedPrecision.swift).
public func validFloatModules(_ list: [String]) -> Bool {
    !list.isEmpty && list.count <= 16 && Set(list).count == list.count
        && list.allSatisfy { p in
            !p.isEmpty && p.count <= 128 && !p.hasPrefix(".") && !p.hasSuffix(".")
                && p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        }
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

    /// The variant Get fetches for a precision (itself when downloaded or stored): the root of its derivation. A stored
    /// root downloads its own source repository and converts it (`catalogVariants`). The derived precision counts as
    /// available when this one is installed.
    func downloadSource(of label: String) -> (label: String, variant: CatalogVariant)? {
        (try? derivation(label)).map { ($0.sourceLabel, $0.source) } ?? variants[label].flatMap { !$0.isDerived || $0.isStored ? (label, $0) : nil }
    }

    /// What Get actually transfers for a precision: the published repository, and for a stored conversion the cast it
    /// applies once after the download (`convert` = target dtype). Nil when nothing in the catalog is downloadable.
    func acquisition(of label: String) -> (root: String, download: CatalogVariant, convert: String?)? {
        guard let root = downloadSource(of: label), let variant = variants[root.label] else { return nil }
        if variant.isStored {
            guard let from = variant.derivedFrom, let source = variants[from], !source.isDerived, let dtype = variant.dtype else { return nil }
            return (root.label, source, dtype)
        }
        return (root.label, variant, nil)
    }

    /// Bytes on disk for a precision: a derived precision stores nothing of its own, so it is its source's files; a
    /// stored conversion is its converted size.
    func diskBytes(_ label: String) -> Int64? {
        guard let root = downloadSource(of: label) else { return nil }
        return root.variant.isStored ? estimatedWeightBytes(self, root.label).map { Int64($0) } : root.variant.downloadBytes
    }

    /// Resolves and validates a derived-at-load precision's chain to its root: the first variant with files of its own
    /// (downloaded, or a stored conversion). A stored conversion is itself a root, not a derivation.
    func derivation(_ label: String) throws -> DerivationRecipe {
        guard let start = variants[label], start.isDerived, !start.isStored else { throw DerivationError.notDerived(label) }
        var steps: [(String, CatalogVariant)] = []
        var seen: Set<String> = []
        var current = label
        while let v = variants[current], v.isDerived, !v.isStored {
            guard seen.insert(current).inserted else { throw DerivationError.cycle(current) }
            steps.append((current, v))
            guard let from = v.derivedFrom, variants[from] != nil else { throw DerivationError.missingSource(current) }
            current = from
        }
        guard let root = variants[current] else { throw DerivationError.missingSource(label) }
        // Never quantize from a quantized source: every chain starts at 16-bit float or wider.
        guard (labelBits(current) ?? 0) >= 16 else { throw DerivationError.invalid("\(label): the source \(current) is quantized.") }
        var recipe = DerivationRecipe(sourceLabel: current, source: root)
        var bitsSoFar = labelBits(current) ?? 0
        // Apply from the root outwards.
        for (stepLabel, v) in steps.reversed() {
            guard v.architecture == root.architecture else { throw DerivationError.invalid("\(stepLabel): architecture differs from its source.") }
            guard let targetBits = labelBits(stepLabel), targetBits < bitsSoFar else {
                throw DerivationError.invalid("\(stepLabel): derived precisions only go down in bits (never upscale).")
            }
            if v.floatModules != nil || v.floatShare != nil {
                // A mixed quantization: float-kept prefixes and their measured share, together, with a quantization.
                guard v.bits != nil, let modules = v.floatModules, validFloatModules(modules), let share = v.floatShare,
                    share > 0, share < 1
                else {
                    throw DerivationError.invalid("\(stepLabel): floatModules (1–16 module paths) and floatShare (0…1) go together, on a quantization.")
                }
            }
            switch (v.dtype, v.bits) {
            case let (dtype?, nil):
                guard derivedCastLabels[dtype] == stepLabel, v.groupSize == nil else {
                    throw DerivationError.invalid("\(stepLabel): cast \(dtype) must be labelled \(derivedCastLabels[dtype] ?? "?").")
                }
                guard recipe.bits == nil else { throw DerivationError.invalid("\(stepLabel): cannot cast a quantized model.") }
                recipe.dtype = dtype
            case let (nil, bits?):
                guard derivedQuantizationBits.contains(bits), stepLabel == "\(bits)b" else {
                    throw DerivationError.invalid("\(stepLabel): quantization must be 4 or 8 bits and labelled so.")
                }
                guard let g = v.groupSize, derivedGroupSizes.contains(g) else { throw DerivationError.invalid("\(stepLabel): group size must be 32, 64 or 128.") }
                guard recipe.bits == nil else { throw DerivationError.invalid("\(stepLabel): cannot quantize twice.") }
                recipe.bits = bits; recipe.groupSize = g
                recipe.floatModules = v.floatModules ?? []
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
            guard let v = variants[label], v.isDerived else { return nil }
            if v.isStored {
                // A stored conversion: a float cast of a downloaded float source to a narrower float, labelled exactly.
                guard let from = v.derivedFrom, let source = variants[from], !source.isDerived, !source.repository.isEmpty,
                    let dtype = v.dtype, derivedCastLabels[dtype] == label, v.bits == nil, v.groupSize == nil,
                    source.architecture == v.architecture, (labelBits(from) ?? 0) > (labelBits(label) ?? 0)
                else {
                    return "\(id) \(label): a stored variant is a float cast of a downloaded float source."
                }
                return nil
            }
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
    /// A mixed recipe's float-kept module prefixes; absent for uniform recipes (their manifests stay byte-identical).
    public var floatModules: [String]?
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
    let manifest = DerivedModelManifest(
        schema: 1, family: family.id, precision: precision, source: source.path, sourceVariant: recipe.source.id,
        sourcePrecision: recipe.sourceLabel, dtype: recipe.dtype, bits: recipe.bits, groupSize: recipe.groupSize,
        floatModules: recipe.floatModules.isEmpty ? nil : recipe.floatModules)
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

/// Whether a precision can load without a download: a checkpoint registered under its own id (downloaded, stored
/// conversion, or an earlier download of exactly this format), or for a precision made at load its root's files.
/// `installedPath` maps a variant id to its registered folder. Never another tier's files.
public func precisionAvailable(_ family: ModelFamily, _ precision: String, installedPath: (String) -> String?) -> Bool {
    guard let variant = family.variants[precision] else { return false }
    if installedPath(variant.id) != nil { return true }
    guard variant.isDerived, !variant.isStored, let root = family.downloadSource(of: precision) else { return false }
    return installedPath(root.variant.id) != nil
}

/// The folder to hand the worker for a precision, preparing its manifest when it is made at load; nil when a Get is
/// needed first. Its own registered checkpoint wins (it loads as is); a derived-at-load precision reads its root.
public func precisionLoadPath(
    _ family: ModelFamily, _ precision: String, installedPath: (String) -> String?,
    modelsDirectory: URL
) throws -> String? {
    guard let variant = family.variants[precision] else { return nil }
    // A mixed recipe (float-kept modules) has no published equivalent: it is made from its root whenever the root is
    // installed. A checkpoint registered under its id (an earlier import of the uniform quantization, re-keyed by
    // `legacyIDs`) loads only while the root is absent, so an existing install keeps working until the root is fetched.
    let rootPath = variant.isDerived && !variant.isStored ? family.downloadSource(of: precision).flatMap { installedPath($0.variant.id) } : nil
    if let own = installedPath(variant.id), variant.floatModules == nil || rootPath == nil { return own }
    guard let source = rootPath else { return nil }
    return try prepareDerivedModel(family: family, precision: precision, sourcePath: source, modelsDirectory: modelsDirectory)
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
            (try? fm.removeItem(at: dir)) != nil
        else { return nil }
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
/// (quantized: bits + 32/groupSize for 16-bit scales and biases) over the quantizable share; a mixed recipe keeps its
/// `floatShare` of the source at the float width.
public func estimatedWeightBytes(_ family: ModelFamily, _ label: String) -> Double? {
    guard let v = family.variants[label] else { return nil }
    if !v.isDerived { return Double(v.downloadBytes) }
    if v.isStored {
        // A stored cast: the source's float bytes scaled to the narrower float (every tensor is cast).
        guard let from = v.derivedFrom, let source = family.variants[from], !source.isDerived,
            let sourceBits = labelBits(from), let bits = labelBits(label), sourceBits > 0
        else { return nil }
        return Double(source.downloadBytes) * bits / sourceBits
    }
    guard let recipe = try? family.derivation(label), let rootBits = labelBits(recipe.sourceLabel),
        let root = estimatedWeightBytes(family, recipe.sourceLabel)
    else { return nil }
    let floatBits = recipe.dtype.flatMap { derivedCastLabels[$0] }.flatMap(labelBits) ?? rootBits
    let floatBytes = root * floatBits / rootBits
    guard let bits = recipe.bits, let g = recipe.groupSize else { return floatBytes }
    let quantBits = Double(bits) + 32 / Double(g)
    let kept = Swift.min(Swift.max(v.floatShare ?? 0, 0), quantizableWeightShare)
    return floatBytes * ((quantizableWeightShare - kept) * quantBits / floatBits + kept + (1 - quantizableWeightShare))
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
    guard
        let reference = measured.first(where: { $0.0 == root })
            ?? measured.min(by: {
                abs((labelBits($0.0) ?? 0) - targetBits) < abs((labelBits($1.0) ?? 0) - targetBits)
            }), let referenceBytes = estimatedWeightBytes(family, reference.0), referenceBytes > 0
    else { return nil }
    let mb = reference.1 * target / referenceBytes
    return MemoryEstimate(
        mb: mb, measured: false,
        note: String(format: "Estimated from the measured %@ memory (%.0f MB) scaled by weight size; %@ not measured.", reference.0, reference.1, precision))
}
