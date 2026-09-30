import os
import AppKit
import Combine
import Foundation
import VellaCore

/// What the Models table asks the runtime to do. The app's runtime (Backend) implements it; without one, Load falls
/// back to selecting the model for its mode (the pre-residency behaviour) and Unload is unavailable.
@MainActor protocol ModelRuntimeActions: AnyObject {
    /// Menu Load: select for its mode and keep hot (manual residency, joins the launch set).
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection)
    /// Menu Reload: same family at another precision, in place of the loaded one.
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection)
    /// Menu Unload: free its memory; it stays downloaded and leaves the launch set.
    func unload(family: ModelFamily)
    /// Delete, ordered after unload: unload these files if they are the loaded ones and wait for the
    /// worker to exit, then run `delete`; only when it succeeded drop the launch-set entry for these files (loaded or
    /// already evicted). A failed deletion keeps the launch set and reloads a manual model it unloaded.
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool
}

/// The Models table's state: catalog families of both modes, measured numbers, what is downloaded (the two mode
/// libraries) and what is loaded (the runtime).
///
/// ONE state per model (Toby, 26 Sep 2026): a row shows what is loaded (tier × Standard/Optimized × Exact/Fast); a
/// cell the user picks or a switch flip is a transient preview (its numbers, deltas vs Standard 16 and the green
/// Reload) that closing the menu discards; an unloaded row shows what it was last loaded with (config.json
/// `selections`), else Standard 16. Only Load/Reload changes what dictation uses, and only while the model is not in
/// use. Every download asks first (`confirmDownload`).
@MainActor final class ModelsController: ObservableObject {
    let dictation: ModelLibrary
    let streaming: ModelLibrary
    @Published var catalog: ModelCatalog
    @Published var benchmarks: BenchmarkFile
    /// Family id → previewed selection (a segment click or a switch flip, not yet loaded); never persisted.
    @Published private(set) var previews: [String: ModelSelection] = [:]
    /// Family id → the selection a confirmed download will load when it finishes.
    @Published private(set) var pendingSelections: [String: ModelSelection] = [:]
    /// Render harness: draw every row as in use (segments and switch disabled).
    var previewInUse = false
    /// Render harness: the family whose action cell is drawn hovered.
    var previewHover: String?
    /// Capabilities filter: show only models with every capability in it (empty = every model). Kept while Vella runs.
    @Published var capabilityFilter: Set<Capability> = []
    /// The filter strip under the header is open (a click on the Capabilities header toggles it).
    @Published var filterOpen = false
    /// Family id → the precision a flip to Exact moved the preview away from (Exact offers fewer precisions); the
    /// name's second line says so while the preview lasts.
    @Published private(set) var couplingNotes: [String: ModelTier] = [:]
    /// The table's height changed (filter strip, filtered rows): the menu resizes its item view.
    var onLayoutChange: (() -> Void)?
    /// Family id → the precision whose confirmed download is running; it loads when the download finishes.
    @Published private(set) var pendingLoads: [String: String] = [:]
    /// config.json as last read: the modes' models and `lastLoaded`. Nil without one (isolated tests, renders).
    @Published private(set) var config: Configuration?
    /// Runtime state from the worker status; nil = no runtime attached (loaded = the mode's selected model).
    @Published var runtime: TableRuntime?
    @Published var lastError: String?
    /// True in the render harness: nothing is written, no worker is asked.
    var previewing = false
    weak var actions: ModelRuntimeActions?
    /// The app's config.json (the runtime's); nil = none.
    var configURL: URL?
    /// Asks before a download: shows the prompt and answers with an approval only when the user chose Download.
    /// Without a presenter nothing downloads.
    var confirmDownload: ((DownloadPrompt, @escaping (DownloadApproval?) -> Void) -> Void)?
    private var forwarding: [AnyCancellable] = []

    init(dictation: ModelLibrary? = nil, streaming: ModelLibrary? = nil, benchmarksURL: URL? = nil, configURL: URL? = nil) {
        let dictation = dictation ?? ModelLibrary(mode: .dictation)
        self.dictation = dictation
        self.streaming = streaming ?? (dictation.registryURL == ModelLibrary.registry ? ModelLibrary(mode: .streaming)
            : ModelLibrary(mode: .streaming, resources: dictation.resources, registryURL: dictation.registryURL))
        self.configURL = configURL ?? (dictation.registryURL == ModelLibrary.registry ? Backend.configURL : nil)
        catalog = (try? decodeCatalog(Data(contentsOf: dictation.resources.appendingPathComponent("models.json")))) ?? ModelCatalog(families: [])
        benchmarks = decodeBenchmarks(try? Data(contentsOf: benchmarksURL ?? Self.benchmarksURL(resources: dictation.resources)))
        // Download progress and registry changes redraw the table.
        for library in [self.dictation, self.streaming] {
            forwarding.append(library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        reloadConfig()
    }

    /// `VELLA_BENCHMARKS` (a fixture for renders and tests), else the bundled Resources/benchmarks.json.
    static func benchmarksURL(resources: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment["VELLA_BENCHMARKS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return resources.appendingPathComponent("benchmarks.json")
    }

    func reload() {
        dictation.reload(); streaming.reload()
        if let catalog = try? decodeCatalog(Data(contentsOf: dictation.resources.appendingPathComponent("models.json"))) { self.catalog = catalog }
        reloadConfig()
    }
    /// Rereads config.json (after a Load, and when the menu opens).
    func reloadConfig() {
        guard !previewing, let configURL else { return }
        config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
    }
    /// Render harness: a config without touching disk.
    func previewConfig(_ config: Configuration?) { self.config = config }

    /// The family and precision of a model path: a registered download, or a precision made on this Mac (its
    /// directory holds only the derivation manifest).
    func identify(path: String, mode: RecognitionMode) -> (family: ModelFamily, precision: String)? {
        guard !path.isEmpty else { return nil }
        if let id = library(mode).installed.first(where: { $0.value.path == path })?.key, let found = catalog.locate(variant: id),
           found.family.mode == mode { return found }
        guard let manifest = derivedModelManifest(at: URL(fileURLWithPath: path)), let family = catalog.family(manifest.family),
              family.mode == mode, family.variants[manifest.precision]?.isDerived == true else { return nil }
        return (family, manifest.precision)
    }
    /// The precision the family was last loaded at: the mode's model (what the next dictation loads) when it is this
    /// family, else config.json's `lastLoaded`.
    func lastLoaded(_ f: ModelFamily) -> String? {
        let path = config.map { f.mode == .dictation ? $0.model : $0.streamingModel } ?? ""
        if let (family, precision) = identify(path: path, mode: f.mode), family.id == f.id { return precision }
        return config?.lastLoaded[f.id]
    }

    /// Launch migration: a mode's model in config.json that is not a catalog precision on this Mac (a folder outside
    /// the catalog, or one whose registry entry the registry migration dropped) is cleared, so that mode's next
    /// session offers Get like a fresh install instead of loading a model Vella no longer supports. Files are never
    /// touched. Needs a readable registry (otherwise nothing can be identified and nothing changes). Returns the
    /// cleared paths.
    @discardableResult
    func clearSelectionsOutsideTheCatalog() -> [String] {
        guard !previewing, let configURL, dictation.registryReadable,
              let data = try? Data(contentsOf: configURL), var edited = try? JSONDecoder().decode(Configuration.self, from: data) else { return [] }
        var cleared: [String] = []
        for mode in RecognitionMode.allCases {
            let path = mode == .dictation ? edited.model : edited.streamingModel
            guard !path.isEmpty, identify(path: path, mode: mode) == nil else { continue }
            edited.selectModel("", for: mode)
            cleared.append(path)
        }
        guard !cleared.isEmpty else { return [] }
        do { try JSONEncoder().encode(edited).write(to: configURL, options: .atomic) } catch { return [] }
        reloadConfig()
        return cleared
    }

    func library(_ mode: RecognitionMode) -> ModelLibrary { mode == .dictation ? dictation : streaming }

    /// Rows of one section: offered families, plus any other family with downloaded weights so it stays manageable.
    func families(_ mode: RecognitionMode) -> [ModelFamily] {
        catalog.families.filter { $0.mode == mode && ($0.offered || $0.variants.values.contains { library(mode).installed[$0.id] != nil }) }
    }
    /// Cloud reference rows of a section (estimated WER only; no controls). Shown only beside local models.
    func references(_ mode: RecognitionMode) -> [ReferenceEntry] { families(mode).isEmpty ? [] : benchmarks.references(mode) }
    /// Rows the table shows: the families with every filtered capability; cloud rows only without a filter (their
    /// capabilities are not known).
    func visibleFamilies(_ mode: RecognitionMode) -> [ModelFamily] { families(mode).filter { hasCapabilities($0, capabilityFilter) } }
    func visibleReferences(_ mode: RecognitionMode) -> [ReferenceEntry] { capabilityFilter.isEmpty ? references(mode) : [] }
    var rowCount: Int { RecognitionMode.allCases.reduce(0) { $0 + visibleFamilies($1).count + visibleReferences($1).count } }
    var sectionCount: Int { [RecognitionMode.dictation, .streaming].filter { !visibleFamilies($0).isEmpty }.count }
    /// The filter strip's checkboxes: capabilities some models have and others lack.
    var filterableCapabilities: [Capability] { VellaCore.filterableCapabilities(RecognitionMode.allCases.flatMap { families($0) }) }
    func toggleFilterStrip() { filterOpen.toggle(); onLayoutChange?() }
    func toggleFilter(_ c: Capability) {
        if capabilityFilter.contains(c) { capabilityFilter.remove(c) } else { capabilityFilter.insert(c) }
        onLayoutChange?()
    }

    func options(_ f: ModelFamily) -> [String] { precisionOptions(f) }
    /// The precision a derived one is made from, nil for a published precision.
    func derivedSource(_ f: ModelFamily, _ precision: String) -> String? { f.variants[precision]?.derivedFrom }
    /// On disk for a precision: a published download's pinned size, else the measured size (`\u{2014}` otherwise).
    func disk(_ f: ModelFamily, _ precision: String) -> Int64? { tableDiskBytes(f, precision, result(f, precision)) }

    func recommended(_ f: ModelFamily) -> String? { recommendedPrecision(for: f, in: benchmarks) }
    /// What the first dictation without a model offers: the catalog's first offered family at 16 (the default
    /// selection is Standard 16; no precision is recommended), else native.
    func firstOffered(_ mode: RecognitionMode) -> (family: ModelFamily, precision: String)? {
        guard let family = catalog.offered(mode).first else { return nil }
        let precision = precisionLabel(family, tier: .t16) ?? family.native
        return family.variants[precision] != nil ? (family, precision) : family.variants[family.native] != nil ? (family, family.native) : nil
    }
    /// The Get row's download: the offered precision's own weights, or for a precision made on this Mac its source's.
    func firstOffer(_ mode: RecognitionMode) -> Model.ModelOffer? {
        guard let (family, precision) = firstOffered(mode), let source = family.downloadSource(of: precision) else { return nil }
        return Model.ModelOffer(id: source.variant.id, name: family.name, downloadBytes: source.variant.downloadBytes, mode: mode)
    }
    /// The precision the row returns to without a preview: the committed selection's tier.
    /// ONE state: a loaded model shows its loaded precision, an unloaded one what it was last loaded at (what dictation
    /// loads for its mode's model), offered or not; else the committed selection's tier.
    func committed(_ f: ModelFamily) -> String {
        if let loaded = loaded(f)?.precision { return effectivePrecision(stored: loaded, native: f.native) }
        if let last = lastLoaded(f).map({ effectivePrecision(stored: $0, native: f.native) }), f.variants[last] != nil,
           !options(f).contains(last) { return last }
        return label(f, committedSelection(f))
    }
    /// The precision the row shows: a running confirmed download's, else the preview, else the committed one.
    func selected(_ f: ModelFamily) -> String {
        if let pending = pendingLoads[f.id] { return pending }
        if previews[f.id] == nil { return committed(f) }
        return label(f, currentSelection(f))
    }
    /// The cell the row's segments mark: the shown selection when it is the shown precision's tier (a loaded or
    /// last-used precision whose tier is no longer offered marks none).
    func shownCell(_ f: ModelFamily) -> ModelSelection? {
        let s = currentSelection(f)
        return precisionLabel(f, tier: s.tier) == selected(f) && isPresent(f, s) ? s : nil
    }
    func isPreviewing(_ f: ModelFamily) -> Bool { previews[f.id] != nil }

    // MARK: Tier × path × Exact/Fast (TierControl, ExactFastSwitch)

    func benchmark(_ f: ModelFamily) -> FamilyBenchmark? { benchmarks.models[f.id] }
    /// The catalog precision of a selection's tier; the committed precision rule when the catalog has none.
    func label(_ f: ModelFamily, _ s: ModelSelection) -> String {
        if let l = precisionLabel(f, tier: s.tier), options(f).contains(l) { return l }
        return shownPrecision(preview: nil, loaded: loaded(f)?.precision, lastLoaded: lastLoaded(f), recommended: nil, family: f)
    }
    /// Tiers a row offers: the catalog's options whose cell is present (`cellPresent`, the one presence rule).
    func tiers(_ f: ModelFamily, _ path: EnginePath) -> [ModelTier] {
        let segment: SegmentKey = path == .standard ? .standard : .optimized_exact
        return ModelTier.allCases.filter { tier in
            guard let l = precisionLabel(f, tier: tier), options(f).contains(l) else { return false }
            return cellPresent(benchmark(f), tier: tier, segment: segment)
        }
    }
    /// The Optimized row's segments for a switch position (family coupling rule): Exact offers the tiers with an
    /// Optimized Exact recipe (bit-identical to Standard), Fast those with an Optimized Fast one; where Fast = Exact
    /// (greyed switch) either recipe counts. A model without any Optimized recipe offers its Standard tiers.
    func precisions(_ f: ModelFamily, _ mode: OptimizedMode) -> [ModelTier] {
        guard hasOptimizedPath(f) else { return tiers(f, .standard) }
        let keys: [SegmentKey] = !switchAvailable(f) ? [.optimized_exact, .optimized_fast] : mode == .exact ? [.optimized_exact] : [.optimized_fast]
        return offeredTiers(f).filter { tier in keys.contains { cellPresent(benchmark(f), tier: tier, segment: $0) } }
    }
    /// A cell has numbers (family rule, 29 Sep: a cell or switch position without a measurement is unavailable, never a
    /// row of dashes). Families without tiers in the file (unmeasured catalog) count as measured, so they stay usable.
    func measured(_ f: ModelFamily, _ s: ModelSelection) -> Bool {
        guard let b = benchmark(f), !b.tiers.isEmpty else { return true }
        guard let cell = benchmarkCell(b, s) else { return false }
        return !cell.isPending
    }
    /// Tiers of the Optimized row for a switch position that have a measurement.
    func measuredPrecisions(_ f: ModelFamily, _ mode: OptimizedMode) -> [ModelTier] {
        precisions(f, mode).filter { measured(f, ModelSelection(tier: $0, path: .optimized, mode: mode)) }
    }
    /// The Exact position can be chosen: some Exact recipe is measured (where Fast = Exact the switch is pinned anyway).
    func exactAvailable(_ f: ModelFamily) -> Bool { !switchAvailable(f) || !measuredPrecisions(f, .exact).isEmpty }
    /// The Optimized row's segments as the row shows them (the current switch position).
    func precisions(_ f: ModelFamily) -> [ModelTier] { precisions(f, currentSelection(f).mode) }
    /// The model has an Optimized row (and so the Exact/Fast switch); every shipped Vella model does.
    func hasOptimizedPath(_ f: ModelFamily) -> Bool {
        offeredTiers(f).contains { tier in [SegmentKey.optimized_exact, .optimized_fast].contains { cellPresent(benchmark(f), tier: tier, segment: $0) } }
    }
    private func offeredTiers(_ f: ModelFamily) -> [ModelTier] {
        ModelTier.allCases.filter { precisionLabel(f, tier: $0).map(options(f).contains) ?? false }
    }
    func isPresent(_ f: ModelFamily, _ s: ModelSelection) -> Bool {
        s.path == .standard || !hasOptimizedPath(f) ? tiers(f, .standard).contains(s.tier) : precisions(f, s.mode).contains(s.tier)
    }
    /// The Exact/Fast switch is live: some offered tier's Fast recipe runs an inexact component. Unmeasured families
    /// (no tiers in the file) keep it live.
    func switchAvailable(_ f: ModelFamily) -> Bool {
        guard let b = benchmark(f), !b.tiers.isEmpty else { return true }
        return fastDiffersFromExact(b)
    }
    /// The loaded model's selection: as the worker reports it, else from the engine (optimized → Optimized with the
    /// remembered switch, default Fast; anything else → Standard) at the loaded tier.
    func loadedSelection(_ f: ModelFamily) -> ModelSelection? {
        guard let loaded = loaded(f) else { return nil }
        if let s = loaded.selection { return s }
        let tier = modelTier(ofPrecision: loaded.precision) ?? .t16
        let stored = config?.selections[f.id]
        let optimized = loaded.engine == nil || loaded.engine == "optimized"
        if let stored, stored.tier == tier, optimized == (stored.path == .optimized) { return stored }
        return ModelSelection(tier: tier, path: optimized ? .optimized : .standard, mode: stored?.mode ?? (optimized ? .fast : .exact))
    }
    /// What the row returns to without a preview (ONE state): the loaded selection; else the last used (config.json
    /// `selections`, or a legacy `lastLoaded` precision on the path it then ran: Optimized · Fast); else Optimized 16 ·
    /// Fast where that cell exists, else Standard 16 (`valid`).
    /// An unloaded selection whose cell is no longer present falls back to Standard at its tier, then Standard 16.
    func committedSelection(_ f: ModelFamily) -> ModelSelection {
        if let s = loadedSelection(f) { return s }
        // Same rule as the runtime's on-demand loads (VellaCore `defaultSelection`).
        let stored = config?.selections[f.id]
        let candidate = lastLoaded(f).map { defaultSelection(recorded: stored, precision: $0) } ?? stored ?? .fallback
        return valid(f, candidate)
    }
    /// `s` when its cell is present, else the Optimized cell at its tier (its switch position, then the other), else
    /// Optimized 16, else the first present cell; Standard only for a model without an Optimized path.
    func valid(_ f: ModelFamily, _ s: ModelSelection) -> ModelSelection {
        // A selectable cell: present and measured (an unmeasured cell is greyed, never the row's selection).
        let ok: (ModelSelection) -> Bool = { self.isPresent(f, $0) && self.measured(f, $0) }
        if ok(s) { return s }
        for tier in [s.tier] + ModelTier.allCases {
            for mode in [s.mode, s.mode == .fast ? .exact : .fast] {
                let optimized = ModelSelection(tier: tier, path: .optimized, mode: mode)
                if hasOptimizedPath(f), ok(optimized) { return optimized }
            }
            let standard = ModelSelection(tier: tier, path: .standard, mode: s.mode)
            if ok(standard) { return standard }
        }
        return isPresent(f, s) ? s : s
    }
    /// What the row shows: a running confirmed download's selection, else the preview, else the committed one.
    func currentSelection(_ f: ModelFamily) -> ModelSelection { pendingSelections[f.id] ?? previews[f.id] ?? committedSelection(f) }
    /// A segment click: preview that cell (its numbers, deltas and button). Picking the committed cell ends the preview.
    static let log = Logger(subsystem: "dev.vella.dictation", category: "models-table")
    func select(_ f: ModelFamily, tier: ModelTier, path: EnginePath) {
        Self.log.notice("segment click \(f.id, privacy: .public) \(tier.rawValue, privacy: .public) \(path == .standard ? "standard" : "optimized", privacy: .public)")
        let s = ModelSelection(tier: tier, path: path, mode: currentSelection(f).mode)
        guard measured(f, s) || s == loadedSelection(f) else { Self.log.notice("click refused (not measured)"); return }
        guard setPreview(f, s) else { return }
        couplingNotes[f.id] = nil
    }
    /// A precision pick without a row (API, tests): the Optimized cell at that tier (Standard only for a model without
    /// an Optimized path). The table's segments call `select(_:tier:path:)` with their row.
    func select(_ f: ModelFamily, tier: ModelTier) { select(f, tier: tier, path: hasOptimizedPath(f) ? .optimized : .standard) }
    /// A switch flip: the Optimized cell of the shown tier in that mode (from a Standard cell too). Exact offers only
    /// the tiers with an Exact recipe: a tier without one moves to 16 (else the first Exact tier), and the row says
    /// which tier it left. Applies at the next load, like a segment click.
    func setMode(_ f: ModelFamily, _ mode: OptimizedMode) {
        Self.log.notice("switch click \(f.id, privacy: .public) \(mode == .fast ? "fast" : "exact", privacy: .public)")
        let current = currentSelection(f)
        var next = ModelSelection(tier: current.tier, path: .optimized, mode: mode)
        var moved: ModelTier?
        if mode == .exact, switchAvailable(f), !exactAvailable(f) { Self.log.notice("switch refused (Exact not measured)"); return }
        if !isPresent(f, next) || !measured(f, next) {
            let offered = measuredPrecisions(f, mode).isEmpty ? precisions(f, mode) : measuredPrecisions(f, mode)
            if hasOptimizedPath(f), let tier = offered.contains(.t16) ? .t16 : offered.first { moved = current.tier; next.tier = tier }
            else { next.path = current.path }
        }
        guard setPreview(f, next) else { return }
        couplingNotes[f.id] = moved
    }
    /// The name's second line after a flip to Exact moved the precision: `Exact: 16 only, was 8`.
    func couplingNote(_ f: ModelFamily) -> String? {
        guard let from = couplingNotes[f.id] else { return nil }
        let offered = precisions(f, .exact).map(\.rawValue)
        return "Exact: " + (offered.count == 1 ? "\(offered[0]) only" : offered.joined(separator: "/")) + ", was \(from.rawValue)"
    }
    @discardableResult private func setPreview(_ f: ModelFamily, _ s: ModelSelection) -> Bool {
        guard !inUse(f) else {
            let loading = runtime?.loading ?? "-"
            Self.log.notice("click refused (in use): preview \(self.previewInUse, privacy: .public) loadingFamily \(self.isLoading(f), privacy: .public) runtimeLoading \(loading, privacy: .public) mayChange \(self.library(f.mode).mayChangeModel(), privacy: .public)")
            return false
        }
        previews[f.id] = s == committedSelection(f) ? nil : s
        return true
    }
    /// In use: recording, dictating, streaming or loading (segments and switch disabled; a change applies at the next
    /// load, and the no-change-during-recording safety still guards the commit).
    func inUse(_ f: ModelFamily) -> Bool {
        previewInUse || isLoading(f) || runtime?.loading != nil || !library(f.mode).mayChangeModel()
    }
    /// The shown cell's figures: schema 2 → the selection's cell; a schema-1 file → the precision's result.
    func shownResult(_ f: ModelFamily) -> PrecisionResult? {
        guard let b = benchmark(f), !b.tiers.isEmpty, let cell = shownCell(f) else { return result(f, selected(f)) }
        return benchmarkCell(b, cell)?.result
    }
    /// The deltas' base: Standard 16 (schema 2); the recommended precision in a schema-1 file.
    func baseResult(_ f: ModelFamily) -> PrecisionResult? {
        guard let b = benchmark(f), !b.tiers.isEmpty else { return result(f, base(f)) }
        return b.tiers[.t16]?.cells[.standard].flatMap { $0.isPending ? nil : $0.result }
    }
    /// Deltas show unless the row shows Standard 16 itself.
    func showsDeltas(_ f: ModelFamily) -> Bool {
        guard let b = benchmark(f), !b.tiers.isEmpty else { return selected(f) != base(f) }
        let s = currentSelection(f)
        return !(s.tier == .t16 && s.path == .standard)
    }
    func tierHelp(_ f: ModelFamily, tier: ModelTier, path: EnginePath) -> String {
        let mode = currentSelection(f).mode
        let segment: SegmentKey = path == .standard ? .standard : mode == .exact ? .optimized_exact : .optimized_fast
        return tierCellHelp(f, benchmark(f), tier: tier, segment: segment)
    }
    /// The deltas' base in a schema-1 file (no tiers): the recommended precision, else native.
    func base(_ f: ModelFamily) -> String { recommended(f) ?? f.native }
    func result(_ f: ModelFamily, _ precision: String) -> PrecisionResult? { benchmarks.models[f.id]?.result(precision) }
    func installed(_ f: ModelFamily, _ precision: String) -> InstalledModel? {
        f.variants[precision].flatMap { library(f.mode).installed[$0.id] }
    }
    /// The downloadable precision a derived one resolves to (itself when published).
    func downloadRoot(_ f: ModelFamily, _ precision: String) -> String? { f.downloadSource(of: precision)?.label }
    /// Whether the precision can load without a download: its own weights, or (derived) its source's.
    func available(_ f: ModelFamily, _ precision: String) -> Bool {
        precisionAvailable(f, precision) { self.library(f.mode).installed[$0]?.path }
    }
    /// Any downloaded precision of the family (its partial downloads too), for the trash button.
    func localPath(_ f: ModelFamily, _ precision: String) -> String? { f.variants[precision].flatMap { library(f.mode).modelFilePath($0.id) } }

    /// The loaded precision: from the runtime, or without one the variant selected for the family's mode.
    func loaded(_ f: ModelFamily) -> LoadedFamily? {
        if let runtime { return runtime.loaded[f.id] }
        let lib = library(f.mode)
        guard !lib.activeModelPath.isEmpty,
              let precision = f.variants.first(where: { lib.installed[$0.value.id]?.path == lib.activeModelPath })?.key else { return nil }
        return LoadedFamily(precision: precision)
    }
    /// The header's model label for a mode (`Parakeet v3 4-bit`): the model selected for the mode if known (a download
    /// or a precision made on this Mac, loaded or not), else the first loaded model of that mode.
    func activeLabel(_ mode: RecognitionMode) -> String? {
        let lib = library(mode)
        if let (family, precision) = identify(path: lib.activeModelPath, mode: mode) { return "\(family.name) \(precisionInProse(precision))" }
        guard let (id, loaded) = runtime?.loaded.filter({ catalog.family($0.key)?.mode == mode }).sorted(by: { $0.key < $1.key }).first,
              let family = catalog.family(id) else { return lib.activeModelLabel }
        return "\(family.name) \(precisionInProse(loaded.precision))"
    }
    func isLoading(_ f: ModelFamily) -> Bool {
        runtime?.loading == f.id || f.variants.values.contains { library(f.mode).downloadingID == $0.id }
    }
    var anyBusy: Bool { dictation.busy || streaming.busy || runtime?.loading != nil }
    var runtimeAvailable: Bool { runtime?.available ?? true }

    /// Unload when the row shows what is loaded, Reload when it shows another cell (tier, row or switch), else
    /// Load or Get.
    func action(_ f: ModelFamily) -> LoadAction {
        let precision = selected(f)
        guard let loadedNow = loadedSelection(f) else { return available(f, precision) ? .load : .get }
        let shown = currentSelection(f)
        let same = previews[f.id] == nil || (shown.tier == loadedNow.tier && shown.segmentKey == loadedNow.segmentKey
            && effectivePrecision(stored: loaded(f)?.precision ?? "", native: f.native) == precision)
        return same ? .unload : .reload
    }
    /// Whether the row's button starts a download (after the confirmation popup).
    func needsDownload(_ f: ModelFamily) -> Bool { action(f) != .unload && !available(f, selected(f)) }

    /// A precision pick (API, tests): preview that tier on the shown row and switch. Nothing is written; only
    /// Load/Reload changes the model.
    func preview(_ f: ModelFamily, _ precision: String) {
        guard let tier = modelTier(ofPrecision: precision) else { return }
        let current = currentSelection(f)
        previews[f.id] = { let s = ModelSelection(tier: tier, path: current.path, mode: current.mode); return s == committedSelection(f) ? nil : s }()
    }
    /// The menu closed: previews end without effect.
    func discardPreviews() {
        if !previews.isEmpty { previews = [:] }
        if !couplingNotes.isEmpty { couplingNotes = [:] }
    }
    /// Render harness: previews without a click.
    func previewSelections(_ values: [String: ModelSelection], couplingNotes notes: [String: ModelTier] = [:]) { previews = values; couplingNotes = notes }

    /// The row button. Unload goes to the runtime; Get/Load/Reload of weights on disk load now; anything that needs a
    /// download first asks in the confirmation popup, then downloads and loads.
    func perform(_ f: ModelFamily) {
        guard !previewing else { return }
        lastError = nil
        let precision = selected(f)
        guard f.variants[precision] != nil else { return }
        let action = action(f)
        if action == .unload { actions?.unload(family: f); return }
        guard let source = f.downloadSource(of: precision) else { lastError = "\(f.name) at \(precisionFormatName(precision)) has no source in the catalog."; return }
        if available(f, precision) { commit(f, precision, action); return }
        requestDownload(f, precision, sourceID: source.variant.id)
    }

    /// The confirmation popup for what `precision` needs; on Download the download starts and the model loads when it
    /// finishes. Cancel changes nothing.
    func requestDownload(_ f: ModelFamily, _ precision: String, sourceID: String) {
        let lib = library(f.mode)
        let loadedNow = loaded(f)?.precision
        guard let prompt = downloadPrompt(family: f, precision: precision, followUp: loadedNow.map { .reload(from: $0) } ?? .load,
                                          freeBytes: freeDiskBytes(at: lib.modelsDirectory)) else {
            lastError = "\(f.name) at \(precisionFormatName(precision)) has no download in the catalog."; return
        }
        guard let confirmDownload else { lastError = "Downloads need confirmation; reopen Models and try again."; return }
        confirmDownload(prompt) { [weak self] approval in
            guard let self, let approval, approval.variantID == sourceID else { return }
            self.startDownload(f, precision, sourceID: sourceID, approval: approval)
        }
    }
    private func startDownload(_ f: ModelFamily, _ precision: String, sourceID: String, approval: DownloadApproval) {
        let lib = library(f.mode)
        lib.selectedID = sourceID
        pendingLoads[f.id] = precision
        pendingSelections[f.id] = currentSelection(f)
        let started = lib.download(approval: approval, calibrate: false) { [weak self] installed in
            guard let self else { return }
            // A failure or cancellation stays in the footer (the library's error line).
            guard installed, self.available(f, precision) else { self.pendingLoads[f.id] = nil; self.pendingSelections[f.id] = nil; return }
            self.commitWhenIdle(f, precision)
        }
        if !started { pendingLoads[f.id] = nil; pendingSelections[f.id] = nil; lastError = lib.downloadError ?? lib.message }
    }

    /// After a confirmed download: load once no dictation is recording or transcribing. A recording that started
    /// during the download keeps the model it started with; the new one loads (and becomes the selection) after it.
    private func commitWhenIdle(_ f: ModelFamily, _ precision: String) {
        let lib = library(f.mode)
        guard lib.mayChangeModel() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePollSeconds) { [weak self] in
                guard let self, self.pendingLoads[f.id] == precision else { return }
                self.commitWhenIdle(f, precision)
            }
            return
        }
        let selection = pendingSelections[f.id]
        pendingLoads[f.id] = nil; pendingSelections[f.id] = nil
        commit(f, precision, loaded(f) == nil ? .load : .reload, selection: selection)
    }
    static var idlePollSeconds = 0.2

    /// Load or Reload weights that are on disk. The runtime makes the model its mode's model once it loaded.
    private func commit(_ f: ModelFamily, _ precision: String, _ action: LoadAction, selection: ModelSelection? = nil) {
        let selection = selection ?? selectionToCommit(f, precision)
        guard let variant = f.variants[precision] else { return }
        let lib = library(f.mode)
        // Its own checkpoint loads as is; a precision made at load gets its manifest (the worker reads the root).
        let path: String
        do {
            guard let resolved = try precisionLoadPath(f, precision, installedPath: { lib.installed[$0]?.path }, modelsDirectory: lib.modelsDirectory) else { return }
            path = resolved
        } catch { lastError = "Could not prepare \(f.name) at \(precisionFormatName(precision)): \(error)"; return }
        if let actions {
            action == .reload ? actions.reload(family: f, precision: precision, variant: variant, path: path, selection: selection)
                              : actions.load(family: f, precision: precision, variant: variant, path: path, selection: selection)
        } else if lib.installed[variant.id] == nil {
            lastError = "\(f.name) at \(precisionFormatName(precision)) needs the recognition worker; use Start Worker (or Restart Worker) in Vella's menu and try again."
        } else {
            lib.selectedID = variant.id
            if !lib.useSelected() { lastError = lib.downloadError }
            reloadConfig()
        }
    }
    /// The selection a Load/Reload of `precision` carries: the shown one (its tier is `precision`'s).
    func selectionToCommit(_ f: ModelFamily, _ precision: String) -> ModelSelection {
        var s = currentSelection(f)
        if let tier = modelTier(ofPrecision: precision) { s.tier = tier }
        return s
    }
    func cancelDownloads() { dictation.cancel(); streaming.cancel() }
}
