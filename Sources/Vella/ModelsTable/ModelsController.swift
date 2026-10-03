import os
import AppKit
import Combine
import Foundation
import VellaCore
import VellaWire

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

/// Awaitable form of the same runtime actions; the API must not report success before a load/refusal completes.
@MainActor protocol AsyncModelRuntimeActions: ModelRuntimeActions {
    func loadForControl(family: ModelFamily, precision: String, path: String, selection: ModelSelection) async throws
    func unloadForControl(family: ModelFamily) async throws
}

/// The same confirmation snapshot for the table and authenticated Delete. No caller supplies a filesystem path.
struct ModelDeletionPlan {
    let familyID: String
    let precision: String
    let variantID: String
    let path: String
    let wasInstalled: Bool
    let bytes: Int64
    let title: String
    var earlierDownload = false
    var body: String {
        if earlierDownload {
            return
                "Moves these unused earlier weights to the Trash. They cannot be downloaded again from Vella’s catalog. No recipe files depend on them. Recordings and transcripts are kept. Size: "
                + formatBytes(bytes) + " (" + formatExactBytes(bytes) + ")."
        }
        return "Moves its downloaded weights to the Trash. If it is loaded it is unloaded first. You can download it again later. Recordings and transcripts are kept. "
            + "Size: " + formatBytes(bytes) + " (" + formatExactBytes(bytes) + "). Precisions made from these weights lose their recipe files too."
    }
}

/// The Models table's state: catalog families of both modes, measured numbers, what is downloaded (the two mode
/// libraries) and what is loaded (the runtime).
///
/// ONE state per model (Toby, 26 Sep 2026): a row shows what is loaded (tier × Standard/Optimized × Exact/Fast); a
/// cell the user picks or a switch flip is a transient preview (its numbers, deltas vs Standard 16 and the green
/// Reload) that closing the menu discards; an unloaded row shows what it was last loaded with (config.json
/// `selections`), else Optimized 16 Fast. Only Load/Reload changes what dictation uses, and only while the model is not in
/// use. Every download asks first (`confirmDownload`).
@MainActor final class ModelsController: ObservableObject {
    var previousModelNames: [String: String] = [:]
    var benchmarkHardware = HostInfo.benchmarkHardware
    let dictation: ModelLibrary
    let streaming: ModelLibrary
    @Published var catalog: ModelCatalog
    @Published var benchmarks: BenchmarkFile
    /// Family id → previewed selection (a segment click or a switch flip, not yet loaded); never persisted.
    @Published private(set) var previews: [String: ModelSelection] = [:]
    /// Family id → the selection a confirmed download will load when it finishes.
    @Published private(set) var pendingSelections: [String: ModelSelection] = [:]
    /// Controls serialize commits against other API operations and table actions.
    @Published private(set) var controlOperations: Set<String> = []
    /// Render harness: draw every row as in use (segments and switch disabled).
    var previewInUse = false
    /// Render harness: the family whose action cell is drawn hovered.
    var previewHover: String?
    /// Family id → the precision a flip to Exact moved the preview away from (Exact offers fewer precisions); the
    /// name's second line says so while the preview lasts.
    @Published private(set) var couplingNotes: [String: ModelTier] = [:]
    /// Family id → the precision whose confirmed download is running; it loads when the download finishes.
    @Published private(set) var pendingLoads: [String: String] = [:]
    /// config.json as last read: the modes' models and `lastLoaded`. Nil without one (isolated tests, renders).
    @Published private(set) var config: Configuration?
    /// Runtime state from the worker status; nil = no runtime attached (loaded = the mode's selected model).
    @Published var runtime: TableRuntime?
    @Published var lastError: String?
    @Published private(set) var migrationNotices: [String] = []
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
        self.streaming =
            streaming
            ?? (dictation.registryURL == ModelLibrary.registry
                ? ModelLibrary(mode: .streaming)
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
        if let id = library(mode).installed.first(where: { sameFiles($0.value.path, path) })?.key, let found = catalog.locate(variant: id),
            found.family.mode == mode
        {
            // A checkpoint registered under a mixed tier's id is not that recipe: it identifies as nothing.
            return installed(found.family, found.precision) == nil ? nil : found
        }
        guard let manifest = derivedModelManifest(at: URL(fileURLWithPath: path)), let family = catalog.family(manifest.family),
            family.mode == mode, family.variants[manifest.precision]?.isDerived == true,
            // Only while the precision resolves (its source is registered): a stale manifest whose source is not in
            // this library identifies as nothing, like the table's Get.
            available(family, manifest.precision)
        else { return nil }
        return (family, manifest.precision)
    }
    /// The precision the family was last loaded at: the mode's model (what the next dictation loads) when it is this
    /// family, else config.json's `lastLoaded`.
    func lastLoaded(_ f: ModelFamily) -> String? {
        let path = config.map { f.mode == .dictation ? $0.model : $0.streamingModel } ?? ""
        if let (family, precision) = identify(path: path, mode: f.mode), family.id == f.id { return precision }
        return config?.lastLoaded[f.id]
    }

    /// Launch migration: a legacy published quant moves to its measured local tier from the installed root;
    /// an unoffered tier moves to that root. Missing roots/unsupported selections are cleared with a reason.
    /// No downloads or weight deletion. A preparation failure keeps the selection for retry. Requires a readable
    /// existing registry; otherwise nothing changes. Returns cleared paths; notices include every changed selection.
    @discardableResult
    func clearSelectionsOutsideTheCatalog() -> [String] {
        migrationNotices = []
        guard !previewing, let configURL, dictation.registryReadable,
            FileManager.default.fileExists(atPath: dictation.registryURL.path),
            let data = try? Data(contentsOf: configURL), var edited = try? JSONDecoder().decode(Configuration.self, from: data)
        else { return [] }
        var cleared: [String] = []
        var notices: [String] = []
        var changed = false
        for mode in RecognitionMode.allCases {
            let path = mode == .dictation ? edited.model : edited.streamingModel
            guard !path.isEmpty, identify(path: path, mode: mode) == nil else { continue }
            let lib = library(mode)
            if let id = lib.installed.first(where: { sameFiles($0.value.path, path) })?.key,
                let found = catalog.locate(variant: id), found.family.mode == mode,
                found.family.variants[found.precision]?.isDerived == true
            {
                let precision = options(found.family).contains(found.precision) ? found.precision : (precisionLabel(found.family, tier: .t16) ?? found.family.native)
                do {
                    if let derived = try precisionLoadPath(found.family, precision, installedPath: { lib.installed[$0]?.path }, modelsDirectory: lib.modelsDirectory) {
                        edited.selectModel(derived, for: mode)
                        var selection = edited.selections[found.family.id] ?? ModelSelection(tier: .t16, path: .optimized, mode: .fast)
                        selection.tier = modelTier(ofPrecision: precision) ?? .t16
                        edited.selections[found.family.id] = selection
                        changed = true
                        let notice =
                            precision != found.precision
                            ? "\(mode.title) now uses \(found.family.name) at \(tierDTypeLabel(found.family, modelTier(ofPrecision: precision) ?? .t16)) from its installed source because the earlier precision is no longer offered; earlier files are kept."
                            : "\(mode.title) now uses \(found.family.name) at \(tierDTypeLabel(found.family, modelTier(ofPrecision: precision) ?? .t16)) made on this Mac from its \(precisionInProse(found.family.downloadSource(of: precision)?.label ?? "16-bit")) source; the earlier download is kept."
                        notices.append(notice)
                        lastError = notice
                        continue
                    }
                } catch {
                    lastError =
                        "Could not prepare the local replacement for \(found.family.name): \(error.localizedDescription) The current selection is unchanged. Check the model folder and try Load again in Models…."
                    continue
                }
                lastError =
                    "\(found.family.name)'s legacy published quantization is kept on disk but no longer used. Get its 16-bit source in Models \(options(found.family).contains(found.precision) ? "to prepare the measured local tier" : "(this precision is no longer offered)")."
            } else {
                let oldName = previousModelNames[path] ?? lib.installed.values.first { sameFiles($0.path, path) }?.name
                lastError =
                    (oldName.map { "\(mode.title) no longer supports \($0)." } ?? "The previous \(mode.title) model is no longer supported.")
                    + " Its files are kept. Open Models… and choose Get or Load for a \(mode.title) model."
            }
            edited.clearedSelectionReasons[mode.rawValue] = lastError
            notices.append("\(mode.title): " + (lastError ?? "Choose a model in Models."))
            edited.selectModel("", for: mode)
            changed = true
            cleared.append(path)
        }
        guard changed else { return [] }
        do { try JSONEncoder().encode(edited).write(to: configURL, options: .atomic) } catch { return [] }
        migrationNotices = notices
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
    /// Rows the table shows: every family and cloud row of both sections.
    var rowCount: Int { RecognitionMode.allCases.reduce(0) { $0 + families($1).count + references($1).count } }
    var sectionCount: Int { [RecognitionMode.dictation, .streaming].filter { !families($0).isEmpty }.count }

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
    func firstOffer(_ mode: RecognitionMode) -> DictationController.ModelOffer? {
        guard let (family, precision) = firstOffered(mode), let source = family.downloadSource(of: precision) else { return nil }
        return DictationController.ModelOffer(id: source.variant.id, name: family.name, downloadBytes: source.variant.downloadBytes, mode: mode)
    }
    /// The precision the row returns to without a preview: the committed selection's tier.
    /// ONE state: a loaded model shows its loaded precision (offered or not); an unloaded one the committed selection's
    /// tier, which is what its next load runs: a last-loaded precision no longer offered resolves to a valid one
    /// (`SelectionRules.runnable`), here and in the runtime and the API alike.
    func committed(_ f: ModelFamily) -> String {
        if let loaded = loaded(f)?.precision { return effectivePrecision(stored: loaded, native: f.native) }
        let s = committedSelection(f)
        // A recorded precision no longer offered that `runnable` kept (no offered precision's weights are here).
        if let last = lastLoaded(f), !options(f).contains(last), modelTier(ofPrecision: last) == s.tier { return last }
        return label(f, s)
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
        return precisionLabel(f, tier: s.tier) == selected(f) && (isPresent(f, s) || s == loadedSelection(f)) ? s : nil
    }
    /// An optimized request is still remembered, but the worker is actually running Standard.
    func fellBack(_ f: ModelFamily) -> Bool {
        guard let loaded = loaded(f), loaded.engine == "mlx" else { return false }
        return (loaded.selection ?? config?.selections[f.id])?.path == .optimized
    }
    func loadedEngineHelp(_ f: ModelFamily) -> String {
        guard let loaded = loaded(f) else { return "" }
        if fellBack(f) { return fallbackEngineHelp(reason: loaded.engineReason) }
        return engineHelp(engine: loaded.engine, reason: loaded.engineReason, optimizations: loaded.optimizations, chip: runtime?.chip, precision: loaded.precision)
    }

    func isPreviewing(_ f: ModelFamily) -> Bool { previews[f.id] != nil }

    // MARK: Tier × path × Exact/Fast (TierControl, ExactFastSwitch)

    func benchmark(_ f: ModelFamily) -> FamilyBenchmark? { benchmarks.models[f.id] }
    /// The catalog precision of a selection's tier; the committed precision rule when the catalog has none.
    func label(_ f: ModelFamily, _ s: ModelSelection) -> String {
        if let l = precisionLabel(f, tier: s.tier), options(f).contains(l) { return l }
        return shownPrecision(preview: nil, loaded: loaded(f)?.precision, lastLoaded: lastLoaded(f), recommended: nil, family: f)
    }
    /// The cell rules (VellaCore `SelectionRules`, shared with the runtime and the API).
    func rules(_ f: ModelFamily) -> SelectionRules { SelectionRules(family: f, benchmark: benchmark(f)) }
    /// Tiers a row offers: the catalog's options whose cell is present (`cellPresent`, the one presence rule).
    func tiers(_ f: ModelFamily, _ path: EnginePath) -> [ModelTier] { rules(f).tiers(path) }
    /// The Optimized row's segments for a switch position (family coupling rule, `SelectionRules.precisions`).
    func precisions(_ f: ModelFamily, _ mode: OptimizedMode) -> [ModelTier] { rules(f).precisions(mode) }
    /// A cell has numbers (`SelectionRules.measured`).
    func measured(_ f: ModelFamily, _ s: ModelSelection) -> Bool { rules(f).measured(s) }
    /// Tiers of the Optimized row for a switch position that have a measurement.
    func measuredPrecisions(_ f: ModelFamily, _ mode: OptimizedMode) -> [ModelTier] {
        precisions(f, mode).filter { measured(f, ModelSelection(tier: $0, path: .optimized, mode: mode)) }
    }
    /// The Exact position can be chosen: some Exact recipe is measured (where Fast = Exact the switch is pinned anyway).
    func exactAvailable(_ f: ModelFamily) -> Bool { !measuredPrecisions(f, .exact).isEmpty }
    /// The Optimized row's segments as the row shows them (the current switch position).
    func precisions(_ f: ModelFamily) -> [ModelTier] { precisions(f, currentSelection(f).mode) }
    /// The model has an Optimized row (and so the Exact/Fast switch); every shipped Vella model does.
    func hasOptimizedPath(_ f: ModelFamily) -> Bool { rules(f).hasOptimizedPath }
    func isPresent(_ f: ModelFamily, _ s: ModelSelection) -> Bool { rules(f).isPresent(s) }
    /// The Exact/Fast switch is live (`SelectionRules.switchAvailable`).
    func switchAvailable(_ f: ModelFamily) -> Bool { rules(f).switchAvailable }
    /// The loaded model's selection: as the worker reports it, else from the engine (optimized → Optimized with the
    /// remembered switch, default Fast; anything else → Standard) at the loaded tier.
    func loadedSelection(_ f: ModelFamily) -> ModelSelection? {
        guard let loaded = loaded(f) else { return nil }
        if let s = loaded.selection { return effectiveSelection(s, engine: loaded.engine) }
        let tier = modelTier(ofPrecision: loaded.precision) ?? .t16
        let stored = config?.selections[f.id]
        let optimized = loaded.engine == nil || loaded.engine == Engine.optimized.rawValue
        if let stored, stored.tier == tier, optimized == (stored.path == .optimized) { return stored }
        return ModelSelection(tier: tier, path: optimized ? .optimized : .standard, mode: stored?.mode ?? (optimized ? .fast : .exact))
    }
    /// What the row returns to without a preview (ONE state): the loaded selection; else the last used (config.json
    /// `selections`, or a legacy `lastLoaded` precision on the path it then ran: Optimized · Fast); else Optimized 16 ·
    /// Fast where that cell exists, else Standard 16 (`valid`).
    /// An unloaded selection whose cell is no longer present falls back to Standard at its tier, then Standard 16.
    func committedSelection(_ f: ModelFamily) -> ModelSelection {
        if let s = loadedSelection(f) { return s }
        // The same rule as the runtime's on-demand loads and the API (VellaCore `SelectionRules.runnable`).
        return rules(f).runnable(recorded: config?.selections[f.id], precision: lastLoaded(f), available: { self.available(f, $0) })
    }
    /// `s` when its cell is present and measured, else the fallback cell (`SelectionRules.valid`).
    func valid(_ f: ModelFamily, _ s: ModelSelection) -> ModelSelection { rules(f).valid(s) }
    /// What the row shows: a running confirmed download's selection, else the preview, else the committed one.
    func currentSelection(_ f: ModelFamily) -> ModelSelection { pendingSelections[f.id] ?? previews[f.id] ?? committedSelection(f) }
    /// A segment click: preview that cell (its numbers, deltas and button). Picking the committed cell ends the preview.
    static let log = Logger(subsystem: "dev.vella.dictation", category: "models-table")
    func select(_ f: ModelFamily, tier: ModelTier, path: EnginePath) {
        Self.log.notice("segment click \(f.id, privacy: .public) \(tier.rawValue, privacy: .public) \(path == .standard ? "standard" : "optimized", privacy: .public)")
        let s = ModelSelection(tier: tier, path: path, mode: currentSelection(f).mode)
        // A greyed cell (absent tier, recipe the switch position lacks) is never selected, whatever reaches here.
        guard isPresent(f, s) || s == loadedSelection(f) else { Self.log.notice("click refused (not offered)"); return }
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
            if hasOptimizedPath(f), let tier = offered.contains(.t16) ? .t16 : offered.first { moved = current.tier; next.tier = tier } else { next.path = current.path }
        }
        guard setPreview(f, next) else { return }
        couplingNotes[f.id] = moved
    }
    /// The name's second line after a flip to Exact moved the precision, in the segments' dtype names:
    /// `Exact: bf16 only, was int8`.
    func couplingNote(_ f: ModelFamily) -> String? {
        guard let from = couplingNotes[f.id] else { return nil }
        let offered = precisions(f, .exact).map { tierDTypeLabel(f, $0) }
        return "Exact: " + (offered.count == 1 ? "\(offered[0]) only" : offered.joined(separator: " and ")) + ", was \(tierDTypeLabel(f, from))"
    }
    @discardableResult private func setPreview(_ f: ModelFamily, _ s: ModelSelection) -> Bool {
        guard !inUse(f) else {
            let loading = runtime?.loading ?? "-"
            Self.log.notice(
                "click refused (in use): preview \(self.previewInUse, privacy: .public) loadingFamily \(self.isLoading(f), privacy: .public) runtimeLoading \(loading, privacy: .public) mayChange \(self.library(f.mode).mayChangeModel(), privacy: .public)"
            )
            return false
        }
        previews[f.id] = s == committedSelection(f) ? nil : s
        return true
    }
    /// In use: recording, dictating, streaming or loading (segments and switch disabled; a change applies at the next
    /// load, and the no-change-during-recording safety still guards the commit).
    func inUse(_ f: ModelFamily) -> Bool {
        !controlOperations.isEmpty || previewInUse || isLoading(f) || runtime?.loading != nil || !library(f.mode).mayChangeModel()
            || f.variants.values.contains { library(f.mode).modelInUse($0.id) }
    }
    /// The shown cell's figures: schema 2 → the selection's cell; a schema-1 file → the precision's result.
    func shownResult(_ f: ModelFamily) -> PrecisionResult? {
        guard let b = benchmark(f), !b.tiers.isEmpty else { return result(f, selected(f)) }
        guard let cell = shownCell(f), let measured = benchmarkCell(b, cell), !measured.isPending else { return nil }
        return measured.result
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
        let segment: Recipe = path == .standard ? .standard : mode == .exact ? .optimized_exact : .optimized_fast
        return tierCellHelp(f, benchmark(f), tier: tier, segment: segment, figuresPending: benchmarks.figuresPending)
    }
    /// The deltas' base in a schema-1 file (no tiers): the recommended precision, else native.
    func base(_ f: ModelFamily) -> String { recommended(f) ?? f.native }
    func result(_ f: ModelFamily, _ precision: String) -> PrecisionResult? { benchmarks.models[f.id]?.result(precision) }
    /// The registered checkpoint that loads as this precision (`registeredCheckpoint`: never one for a mixed recipe).
    func installed(_ f: ModelFamily, _ precision: String) -> InstalledModel? {
        guard let variant = f.variants[precision], !variant.isDerived || variant.isStored else { return nil }
        return library(f.mode).installed[variant.id]
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
        // The mode's model as `identify` resolves it (never a registered checkpoint under a mixed tier's id).
        guard let (family, precision) = identify(path: library(f.mode).activeModelPath, mode: f.mode), family.id == f.id else { return nil }
        return LoadedFamily(precision: precision)
    }
    /// The header's model label for a mode (`Parakeet v3 4-bit`): the model selected for the mode if known (a download
    /// or a precision made on this Mac, loaded or not), else the first loaded model of that mode.
    func activeLabel(_ mode: RecognitionMode) -> String? {
        let lib = library(mode)
        if let (family, precision) = identify(path: lib.activeModelPath, mode: mode) {
            // Unloaded at a precision no longer offered: what its next load runs (`SelectionRules.runnable`).
            let runs = loaded(family) != nil || options(family).contains(precision) ? precision : committed(family)
            return "\(family.name) \(humanDType(precision: runs, familyID: family.id))"
        }
        guard let (id, loaded) = runtime?.loaded.filter({ catalog.family($0.key)?.mode == mode }).sorted(by: { $0.key < $1.key }).first,
            let family = catalog.family(id)
        else { return lib.activeModelLabel }
        return "\(family.name) \(humanDType(precision: loaded.precision, familyID: family.id))"
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
        let same =
            previews[f.id] == nil
            || (shown.tier == loadedNow.tier && shown.segmentKey == loadedNow.segmentKey
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
        previews[f.id] = {
            let s = ModelSelection(tier: tier, path: current.path, mode: current.mode); return s == committedSelection(f) ? nil : s
        }()
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
        guard !previewing, controlOperations.isEmpty else { return }
        lastError = nil
        let precision = selected(f)
        guard f.variants[precision] != nil else { return }
        let action = action(f)
        guard !inUse(f), !anyBusy else { lastError = "Finish dictation, transcription, loading or downloading before changing this model."; return }
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
        guard
            let prompt = downloadPrompt(
                family: f, precision: precision, followUp: loadedNow.map { .reload(from: $0) } ?? .load,
                freeBytes: freeDiskBytes(at: lib.modelsDirectory))
        else {
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
        } catch { lastError = "Could not prepare \(f.name) at \(precisionFormatName(precision)): \(error.localizedDescription)"; return }
        if let actions {
            if action == .reload {
                actions.reload(family: f, precision: precision, variant: variant, path: path, selection: selection)
            } else {
                actions.load(family: f, precision: precision, variant: variant, path: path, selection: selection)
            }
        } else if installed(f, precision) == nil {
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
    /// Explicit cell preview, shared with the table's rules; Load/Reload/Get is the committing action.
    func selectForControl(_ f: ModelFamily, selection: ModelSelection) throws {
        if let reason = rules(f).cellRefusal(selection, loaded: loadedSelection(f)) { throw APIError(409, reason) }
        guard !inUse(f), !anyBusy else { throw APIError(409, "Finish dictation, transcription, loading or downloading before changing this model.") }
        _ = setPreview(f, selection)
        couplingNotes[f.id] = nil
    }

    /// A mode-only request is the table's switch flip, including its coupling to an Exact tier.
    func setModeForControl(_ f: ModelFamily, mode: OptimizedMode) throws {
        guard !inUse(f), !anyBusy else { throw APIError(409, ExactFastSwitch.inUseHelp) }
        guard hasOptimizedPath(f) else { throw APIError(409, noOptimizedPathHelp) }
        guard switchAvailable(f) else { throw APIError(409, ExactFastSwitch.sameHelp) }
        guard mode != .exact || exactAvailable(f) else { throw APIError(409, ExactFastSwitch.exactNotMeasuredHelp) }
        setMode(f, mode)
    }

    func performForControl(_ f: ModelFamily, action: String, yes: Bool) async throws {
        guard !inUse(f), !anyBusy else { throw APIError(409, "Finish dictation, transcription, loading or downloading before changing this model.") }
        guard let actions = actions as? any AsyncModelRuntimeActions else { throw APIError(503, "Vella's model runtime is not running.") }
        if action == "unload" {
            controlOperations.insert(f.id)
            defer { controlOperations.remove(f.id) }
            try await actions.unloadForControl(family: f); previews[f.id] = nil; return
        }
        if action == "reload", loaded(f) == nil { throw APIError(409, "Load this model before Reload.") }
        let selection = currentSelection(f)
        if let reason = rules(f).cellRefusal(selection, loaded: loadedSelection(f)) { throw APIError(409, reason) }
        guard let precision = rules(f).precision(of: selection) else { throw APIError(409, "Not offered for this model") }
        let lib = library(f.mode)
        let needsDownload = !available(f, precision)
        if action == "get", needsDownload, !yes {
            guard let prompt = downloadPrompt(family: f, precision: precision, followUp: .load, freeBytes: freeDiskBytes(at: lib.modelsDirectory)) else {
                throw APIError(409, "Not offered for this model")
            }
            throw APIError(
                409,
                (prompt.title + " " + prompt.body).components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " · ")
                    + " · Get requires explicit consent (vella get " + f.id + " --yes).", code: "download_consent_required")
        }
        // Even Load/Reload can require a download. Return the table's exact prompt, never silently fetch.
        if needsDownload {
            guard
                let prompt = downloadPrompt(
                    family: f, precision: precision, followUp: loaded(f).map { .reload(from: $0.precision) } ?? .load,
                    freeBytes: freeDiskBytes(at: lib.modelsDirectory))
            else { throw APIError(409, "Not offered for this model") }
            guard action == "get", let approval = DownloadGate.ask(prompt, present: { _ in yes }) else {
                throw APIError(
                    409,
                    (prompt.title + " " + prompt.body).components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " · ")
                        + " · Get requires explicit consent (vella get " + f.id + " --yes).", code: "download_consent_required")
            }
            controlOperations.insert(f.id)
            defer { controlOperations.remove(f.id) }
            lib.selectedID = approval.variantID
            pendingLoads[f.id] = precision; pendingSelections[f.id] = selection
            defer { pendingLoads[f.id] = nil; pendingSelections[f.id] = nil }
            let cancellation = APIJobCancellation.current
            let variant = approval.variantID
            let downloaded: Bool = await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { continuation in
                        if Task.isCancelled {
                            ModelLibrary.downloadLog.notice(
                                "Get \(variant, privacy: .public) not started: request cancelled (\(cancellation?.source ?? "request task", privacy: .public))")
                            continuation.resume(returning: false); return
                        }
                        lib.download(approval: approval, calibrate: false) { continuation.resume(returning: $0) }
                    }
                },
                onCancel: {
                    let source = cancellation?.source ?? "request task"
                    ModelLibrary.downloadLog.notice("Get \(variant, privacy: .public) request cancelled: \(source, privacy: .public)")
                    Task { @MainActor in lib.cancel(source: source) }
                })
            if Task.isCancelled {
                ModelLibrary.downloadLog.notice(
                    "Get \(variant, privacy: .public) ends cancelled after the download: \(cancellation?.source ?? "request task", privacy: .public)")
                throw CancellationError()
            }
            pendingLoads[f.id] = nil; pendingSelections[f.id] = nil
            guard downloaded, available(f, precision) else { throw APIError(500, lib.downloadError ?? "Model download failed") }
            let deadline = Date().addingTimeInterval(900)
            while !lib.mayChangeModel() || runtime?.loading != nil {
                guard Date() < deadline else { throw APIError(409, "Downloaded; finish dictation before Load.") }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try await loadForControl(f, precision: precision, selection: selection, actions: actions)
        } else {
            controlOperations.insert(f.id)
            defer { controlOperations.remove(f.id) }
            try await loadForControl(f, precision: precision, selection: selection, actions: actions)
        }
        previews[f.id] = nil; couplingNotes[f.id] = nil; reloadConfig()
    }

    private func loadForControl(_ f: ModelFamily, precision: String, selection: ModelSelection, actions: any AsyncModelRuntimeActions) async throws {
        let lib = library(f.mode)
        guard let path = try precisionLoadPath(f, precision, installedPath: { lib.installed[$0]?.path }, modelsDirectory: lib.modelsDirectory) else {
            throw APIError(404, "Get this model before Load.")
        }
        try await actions.loadForControl(family: f, precision: precision, path: path, selection: selection)
    }

    func deletionPlan(_ f: ModelFamily, precision: String) throws -> ModelDeletionPlan {
        guard let variant = f.variants[precision] else { throw APIError(400, "Unknown Precision for this model") }
        let lib = library(f.mode)
        if let reason = lib.deletionBlockReason(variant.id) { throw APIError(409, reason) }
        guard controlOperations.isEmpty, !previewInUse, runtime?.loading == nil else { throw APIError(409, modelDeletionBusyHelp) }
        guard let path = lib.modelFilePath(variant.id) else { throw APIError(409, "This model has no local files.") }
        guard let bytes = Runtime.folderBytes(path) else { throw APIError(409, "Cannot verify these weights' size; nothing deleted.") }
        let installed = lib.installed[variant.id] != nil
        let name = f.name + " " + legacyQuantization(precision)
        let earlierDownload = installed && variant.isDerived && registeredCheckpoint(f, precision, installedPath: { lib.installed[$0]?.path }) == nil
        return ModelDeletionPlan(
            familyID: f.id, precision: precision, variantID: variant.id, path: path, wasInstalled: installed,
            bytes: bytes, title: installed ? "Delete " + name + (earlierDownload ? " earlier download (not used)?" : "?") : "Delete unfinished " + name + " download?",
            earlierDownload: earlierDownload)
    }

    func performDeletion(_ f: ModelFamily, plan: ModelDeletionPlan) async throws {
        guard f.id == plan.familyID else { throw APIError(400, "Deletion model changed") }
        let lib = library(f.mode)
        if let reason = lib.deletionBlockReason(plan.variantID) { throw APIError(409, reason) }
        guard controlOperations.isEmpty, !previewInUse, runtime?.loading == nil else { throw APIError(409, modelDeletionBusyHelp) }
        controlOperations.insert(f.id)
        defer { controlOperations.remove(f.id) }
        let delete: @MainActor () -> Bool = {
            guard lib.deleteModel(plan.variantID, expectedPath: plan.path, expectedInstalled: plan.wasInstalled) else { return false }
            removeDerivedModels(sourcePath: plan.path, modelsDirectory: lib.modelsDirectory)
            return true
        }
        let deleted: Bool
        if let actions { deleted = await actions.delete(family: f, path: plan.path, delete: delete) } else { deleted = delete() }
        guard deleted else { throw APIError(409, lib.downloadError ?? "Model was not deleted; reopen Models and try again.") }
        previews[f.id] = nil; couplingNotes[f.id] = nil; reload()
    }

    func cancelDownloads() { dictation.cancel(source: "Models table Cancel"); streaming.cancel(source: "Models table Cancel") }
}
