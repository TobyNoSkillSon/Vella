import Foundation

// MARK: Catalog (models.json v2)

/// One precision of a model family. `id` is the variant's stable install id (the key in models-installed.json);
/// older catalogs used it as the row id.
///
/// A variant is either downloaded (pinned `repository`/`revision`/`downloadBytes`) or derived locally from another
/// precision of the same family (`derivedFrom` = source label): a cast (`dtype`, e.g. `bfloat16`) or an affine
/// quantization (`bits` 4/8, `groupSize`). A derived variant downloads nothing itself: repository and revision are
/// empty and downloadBytes 0; see DerivedModels.swift for its source, disk size and the worker manifest.
public struct CatalogVariant: Codable, Equatable {
    public var id: String
    public var repository: String
    public var revision: String
    public var downloadBytes: Int64
    public var architecture: String
    public var processorSource: ProcessorSource?
    /// Source precision label within the family; nil for a downloaded variant.
    public var derivedFrom: String?
    /// Affine quantization of the source (never below 4 bits).
    public var bits: Int?
    public var groupSize: Int?
    /// Float cast of the source (`bfloat16` or `float16`).
    public var dtype: String?
    /// A mixed per-layer quantization (only with `bits`): module-path prefixes, as the architecture's worker loader names
    /// them (Whisper `model.encoder`), whose layers keep the source's float weights. Nil = the uniform recipe.
    public var floatModules: [String]?
    /// Share of the source checkpoint's weight bytes held by quantizable layers inside `floatModules` (0…1), for the
    /// size and memory estimate (`estimatedWeightBytes`). Measured from the source's safetensors header.
    public var floatShare: Double?
    /// A cast made ONCE at Get and stored as a real checkpoint (Parakeet v3: the FP32 download is converted to BF16 and
    /// only the BF16 weights are kept). Nil/false: derived at each load from a manifest (DerivedModels.swift).
    public var stored: Bool?
    /// Earlier registry ids whose files are this variant in this exact format (an import from before the catalog had
    /// it); the launch migration re-keys them to `id` (ModelLibrary.migrateRegistry).
    public var legacyIDs: [String]?
    public init(id: String, repository: String, revision: String, downloadBytes: Int64, architecture: String, processorSource: ProcessorSource? = nil) {
        self.id = id; self.repository = repository; self.revision = revision; self.downloadBytes = downloadBytes
        self.architecture = architecture; self.processorSource = processorSource
    }
    /// A locally derived variant.
    public init(id: String, architecture: String, derivedFrom: String, bits: Int? = nil, groupSize: Int? = nil, dtype: String? = nil) {
        self.init(id: id, repository: "", revision: "", downloadBytes: 0, architecture: architecture)
        self.derivedFrom = derivedFrom; self.bits = bits; self.groupSize = groupSize; self.dtype = dtype
    }
    public var isDerived: Bool { derivedFrom != nil }
    /// Converted once at Get and kept as weights (see `stored`).
    public var isStored: Bool { derivedFrom != nil && stored == true }
    enum CodingKeys: String, CodingKey {
        case id, repository, revision, downloadBytes, architecture, processorSource, derivedFrom, bits, groupSize, dtype, floatModules, floatShare, stored, legacyIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        architecture = try c.decode(String.self, forKey: .architecture)
        derivedFrom = try c.decodeIfPresent(String.self, forKey: .derivedFrom)
        bits = try c.decodeIfPresent(Int.self, forKey: .bits)
        groupSize = try c.decodeIfPresent(Int.self, forKey: .groupSize)
        dtype = try c.decodeIfPresent(String.self, forKey: .dtype)
        floatModules = try c.decodeIfPresent([String].self, forKey: .floatModules)
        floatShare = try c.decodeIfPresent(Double.self, forKey: .floatShare)
        stored = try c.decodeIfPresent(Bool.self, forKey: .stored)
        legacyIDs = try c.decodeIfPresent([String].self, forKey: .legacyIDs)
        processorSource = try c.decodeIfPresent(ProcessorSource.self, forKey: .processorSource)
        if derivedFrom == nil {
            repository = try c.decode(String.self, forKey: .repository)
            revision = try c.decode(String.self, forKey: .revision)
            downloadBytes = try c.decode(Int64.self, forKey: .downloadBytes)
        } else {
            repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? ""
            revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
            downloadBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadBytes) ?? 0
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !isDerived {
            try c.encode(repository, forKey: .repository); try c.encode(revision, forKey: .revision)
            try c.encode(downloadBytes, forKey: .downloadBytes)
        }
        try c.encode(architecture, forKey: .architecture)
        try c.encodeIfPresent(processorSource, forKey: .processorSource)
        try c.encodeIfPresent(derivedFrom, forKey: .derivedFrom); try c.encodeIfPresent(bits, forKey: .bits)
        try c.encodeIfPresent(groupSize, forKey: .groupSize); try c.encodeIfPresent(dtype, forKey: .dtype)
        try c.encodeIfPresent(floatModules, forKey: .floatModules); try c.encodeIfPresent(floatShare, forKey: .floatShare)
        try c.encodeIfPresent(stored, forKey: .stored); try c.encodeIfPresent(legacyIDs, forKey: .legacyIDs)
    }
}

/// Tokenizer/processor files fetched from another pinned repository (a quantized conversion without them).
public struct ProcessorSource: Codable, Equatable {
    public var repository: String
    public var revision: String
    public var files: [String]
    public init(repository: String, revision: String, files: [String]) { self.repository = repository; self.revision = revision; self.files = files }
}

/// What Get downloads for a family (models.json `download`): always the 16-bit checkpoint, or for an fp32-only model
/// its fp32 source, converted at Get. `convert_to` are the tiers made on this Mac from it; `vendor_quant_repo` a vendor's
/// quantization-aware 4-bit, downloaded as-is (none today).
public struct CatalogDownload: Codable, Equatable {
    public var repo: String
    public var revision: String
    public var bytes: Int64
    public var convert_to: [String]
    public var vendor_quant_repo: String?
    public init(repo: String, revision: String, bytes: Int64, convert_to: [String], vendor_quant_repo: String? = nil) {
        self.repo = repo; self.revision = revision; self.bytes = bytes; self.convert_to = convert_to; self.vendor_quant_repo = vendor_quant_repo
    }
}

/// One row of the Models table: a model with its precisions.
public struct ModelFamily: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mode: RecognitionMode
    public var languages: [String]
    public var params: String
    public var license: String
    /// The checkpoint's own precision (`BF16`, `FP16`, `FP32`, or a native low-bit format such as ternary).
    public var native: String
    /// Precision label (`4b`, `8b`, `BF16`, `FP16`, `FP32`, …) → pinned download.
    public var variants: [String: CatalogVariant]
    /// Only offered families appear in the app; the others exist for the published benchmark table.
    public var offered: Bool
    /// Free-form note: the API's `recommendation` and the benchmark site. Not tooltip text (the table assembles its
    /// lines from the structured fields below).
    public var notes: String?
    /// The Model tooltip's facts (TableHelp.swift): who released the model, the year, the licence's display name
    /// (`license` stays the upstream card's metadata id), and one plain sentence on what it does and does not do.
    /// Each is optional; an unknown fact is left out of the tooltip.
    public var publisher: String?
    public var released: Int?
    public var licence: String?
    public var summary: String?
    /// The checkpoint's own dtype (`bfloat16`, `float16`, `float32`); models.json `native_dtype`.
    public var nativeDType: String?
    /// Tiers the app offers ("16", "8", "4"): the tiers present in benchmarks.json (a tier is absent only when it breaks,
    /// lab/notes/models-table-ROUND.md). Nil (older catalogs, fixtures): every catalogued precision down to 4 bits.
    public var tiersOffered: [String]?
    /// What Get downloads and which tiers are made locally from it.
    public var download: CatalogDownload?
    enum CodingKeys: String, CodingKey {
        case id, name, mode, languages, params, license, native, variants, offered, notes, publisher, released, licence, summary
        case nativeDType = "native_dtype", tiersOffered = "tiers_offered", download
    }
    public init(
        id: String, name: String, mode: RecognitionMode, languages: [String], params: String, license: String, native: String,
        variants: [String: CatalogVariant], offered: Bool = true, notes: String? = nil, publisher: String? = nil,
        released: Int? = nil, licence: String? = nil, summary: String? = nil, nativeDType: String? = nil,
        tiersOffered: [String]? = nil, download: CatalogDownload? = nil
    ) {
        self.id = id; self.name = name; self.mode = mode; self.languages = languages; self.params = params; self.license = license
        self.native = native; self.variants = variants; self.offered = offered; self.notes = notes
        self.publisher = publisher; self.released = released; self.licence = licence; self.summary = summary
        self.nativeDType = nativeDType; self.tiersOffered = tiersOffered; self.download = download
    }
    /// The family's variant whose install id is `variantID`.
    public func precision(ofVariant variantID: String) -> String? { variants.first { $0.value.id == variantID }?.key }
    /// The precision whose earlier registry id (`legacyIDs`) is `id`.
    public func precision(ofLegacyID id: String) -> String? { variants.first { $0.value.legacyIDs?.contains(id) == true }?.key }
}

public struct ModelCatalog: Codable, Equatable {
    public var schema: Int
    public var families: [ModelFamily]
    public init(schema: Int = 2, families: [ModelFamily]) { self.schema = schema; self.families = families }
    public func family(_ id: String) -> ModelFamily? { families.first { $0.id == id } }
    /// The family and precision that own an install id.
    public func locate(variant id: String) -> (family: ModelFamily, precision: String)? {
        for family in families { if let p = family.precision(ofVariant: id) { return (family, p) } }
        return nil
    }
    /// Offered families of a mode, in catalog order.
    public func offered(_ mode: RecognitionMode) -> [ModelFamily] { families.filter { $0.offered && $0.mode == mode } }
}

/// Decodes models.json (schema 2: families with their variants).
public func decodeCatalog(_ data: Data) throws -> ModelCatalog {
    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
    guard catalog.schema >= 2 else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "models.json schema \(catalog.schema) is not supported"))
    }
    return catalog
}

/// Every variant of a catalog as the downloader's flat record (one per precision). `quantization` keeps the
/// downloader's legacy spelling (`4-bit`, `8-bit`, `BF16`) that `NativeModelDownload.validate` checks against config.json.
/// Locally derived variants are not downloads and are skipped (Get downloads their source).
public func catalogVariants(_ catalog: ModelCatalog) -> [ModelRecommendation] {
    catalog.families.flatMap { family in
        orderedPrecisions(Array(family.variants.keys)).compactMap { label -> ModelRecommendation? in
            guard let v = family.variants[label] else { return nil }
            // A stored conversion downloads its source's repository into its own folder, then converts it in place
            // (ModelLibrary.download); the record carries the source's pin and size.
            if v.isStored, let from = v.derivedFrom, let source = family.variants[from], !source.isDerived {
                return ModelRecommendation(
                    id: v.id, name: family.name, quantization: legacyQuantization(label), repository: source.repository,
                    revision: source.revision, downloadBytes: source.downloadBytes, architecture: v.architecture,
                    license: family.license, recommendation: family.notes ?? "", recommended: family.offered)
            }
            guard !v.isDerived else { return nil }
            return ModelRecommendation(
                id: v.id, name: family.name, quantization: legacyQuantization(label), repository: v.repository,
                revision: v.revision, downloadBytes: v.downloadBytes, architecture: v.architecture, license: family.license,
                recommendation: family.notes ?? "", recommended: family.offered)
        }
    }
}
/// Reads a catalog file as flat variant records.
public func catalogVariants(contentsOf url: URL) throws -> [ModelRecommendation] { catalogVariants(try decodeCatalog(Data(contentsOf: url))) }
/// The pinned processor recipe for an install id, if any.
public func processorSource(variant id: String, catalogURL: URL) throws -> ProcessorSource? {
    try decodeCatalog(Data(contentsOf: catalogURL)).locate(variant: id).flatMap { $0.family.variants[$0.precision]?.processorSource }
}
