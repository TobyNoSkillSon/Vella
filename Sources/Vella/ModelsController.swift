import AppKit
import Combine
import Foundation
import VellaCore

/// What the Models table asks the runtime to do. The app's runtime (Backend) implements it; without one, Load falls
/// back to selecting the model for its mode (the pre-residency behaviour) and Unload is unavailable.
@MainActor protocol ModelRuntimeActions: AnyObject {
    /// Menu Load: select for its mode and keep hot (manual residency, joins the launch set).
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String)
    /// Menu Reload: same family at another precision, in place of the loaded one.
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String)
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
/// ONE state per model (Toby, 26 Sep 2026): a row shows its loaded precision; a segment the user picks is a transient
/// preview (its numbers, deltas and the green Reload) that closing the menu discards; an unloaded row shows the
/// precision it was last loaded at (config.json: the mode's model, else `lastLoaded`), else the recommended one. Only
/// Load/Reload changes what dictation uses. Every download asks first (`confirmDownload`).
@MainActor final class ModelsController: ObservableObject {
    let dictation: ModelLibrary
    let streaming: ModelLibrary
    @Published var catalog: ModelCatalog
    @Published var benchmarks: BenchmarkFile
    /// Family id → previewed precision; never persisted.
    @Published private(set) var previews: [String: String] = [:]
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

    /// One-time migration of the retired model-precision.json (a per-family choice kept apart from what was loaded,
    /// the 1.0.0 bug): an entry becomes `lastLoaded` only for a family with no load record whose precision is on disk,
    /// so it never overrides a loaded or configured model and never leads to a download. The file is then deleted.
    /// Only when it sits beside config.json (the same support directory).
    func migrateLegacySelections(from url: URL) {
        guard !previewing, let configURL, FileManager.default.fileExists(atPath: url.path),
              url.deletingLastPathComponent().standardizedFileURL == configURL.deletingLastPathComponent().standardizedFileURL else { return }
        let stored = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        var config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        var changed = false
        if var edited = config {
            self.config = edited
            for (id, value) in stored.sorted(by: { $0.key < $1.key }) {
                guard let family = catalog.family(id), edited.lastLoaded[id] == nil, lastLoaded(family) == nil else { continue }
                let precision = effectivePrecision(stored: value, native: family.native)
                guard options(family).contains(precision), available(family, precision) else { continue }
                edited.lastLoaded[id] = precision; changed = true
            }
            if changed {
                do { try JSONEncoder().encode(edited).write(to: configURL, options: .atomic); config = edited }
                catch { lastError = "Could not migrate the precision choices: \(error.localizedDescription)"; return }
            }
        }
        try? FileManager.default.removeItem(at: url)
        self.config = config
    }

    func library(_ mode: RecognitionMode) -> ModelLibrary { mode == .dictation ? dictation : streaming }

    /// Rows of one section: offered families, plus any other family with downloaded weights so it stays manageable.
    func families(_ mode: RecognitionMode) -> [ModelFamily] {
        catalog.families.filter { $0.mode == mode && ($0.offered || $0.variants.values.contains { library(mode).installed[$0.id] != nil }) }
    }
    /// Cloud reference rows of a section (estimated WER only; no controls). Shown only beside local models.
    func references(_ mode: RecognitionMode) -> [ReferenceEntry] { families(mode).isEmpty ? [] : benchmarks.references(mode) }
    var rowCount: Int { RecognitionMode.allCases.reduce(0) { $0 + families($1).count + references($1).count } }
    var sectionCount: Int { [RecognitionMode.dictation, .streaming].filter { !families($0).isEmpty }.count }

    func options(_ f: ModelFamily) -> [String] { precisionOptions(f) }
    /// The Q control's segment labels (bare widths), parallel to `options`.
    func segmentLabels(_ f: ModelFamily) -> [String] { precisionSegmentLabels(options(f)) }
    /// The precision a derived one is made from, nil for a published precision.
    func derivedSource(_ f: ModelFamily, _ precision: String) -> String? { f.variants[precision]?.derivedFrom }
    /// On disk for a precision: a published download's pinned size, else the measured size (`\u{2014}` otherwise).
    func disk(_ f: ModelFamily, _ precision: String) -> Int64? { tableDiskBytes(f, precision, result(f, precision)) }

    /// A Q segment's tooltip: the exact format, where it comes from (published, or made on this Mac from a higher
    /// precision), whether it is measured, and the recommendation or the loaded precision when they apply.
    /// A Q segment's tooltip (an NSSegmentedControl tooltip, in the family line format): the format, where the weights
    /// come from, whether it is measured, the recommendation when it is the recommended one, and what Reload does.
    func segmentHelp(_ f: ModelFamily, _ precision: String) -> String {
        var lines = [precisionFormatName(precision) + (precision == f.native ? " \u{00b7} native precision" : "")]
        if let source = derivedSource(f, precision) {
            var line = "Made on this Mac from the \(precisionFormatName(source)) weights"
            if let root = downloadRoot(f, precision), let v = f.variants[root], installed(f, root) == nil {
                line += "; loading downloads those first (\(formatBytes(v.downloadBytes)), after you confirm)"
            }
            lines.append(line)
        } else if let v = f.variants[precision], !v.repository.isEmpty {
            lines.append("Published on Hugging Face")
        }
        if result(f, precision)?.wer == nil { lines.append("Not measured yet") }
        if precision == recommended(f), let help = recommendedHelp(f) { lines.append(help) }
        if let loaded = loaded(f)?.precision, loaded != precision {
            lines.append("Loaded at \(precisionFormatName(loaded)); Reload loads this precision instead, closing the menu keeps \(precisionFormatName(loaded))")
        }
        return lines.joined(separator: "\n")
    }
    func recommended(_ f: ModelFamily) -> String? { recommendedPrecision(for: f, in: benchmarks) }
    /// What the first dictation without a model offers: the catalog's first offered family at its recommended
    /// precision (else native).
    func firstOffered(_ mode: RecognitionMode) -> (family: ModelFamily, precision: String)? {
        guard let family = catalog.offered(mode).first else { return nil }
        let precision = recommended(family) ?? family.native
        return family.variants[precision] != nil ? (family, precision) : family.variants[family.native] != nil ? (family, family.native) : nil
    }
    /// The Get row's download: the offered precision's own weights, or for a precision made on this Mac its source's.
    func firstOffer(_ mode: RecognitionMode) -> Model.ModelOffer? {
        guard let (family, precision) = firstOffered(mode), let source = family.downloadSource(of: precision) else { return nil }
        return Model.ModelOffer(id: source.variant.id, name: family.name, downloadBytes: source.variant.downloadBytes, mode: mode)
    }
    /// The precision the row returns to without a preview: loaded, else last loaded, else recommended.
    func committed(_ f: ModelFamily) -> String {
        committedPrecision(loaded: loaded(f)?.precision, lastLoaded: lastLoaded(f), recommended: recommended(f), family: f)
    }
    /// The precision the row shows: a running confirmed download's, else the preview, else the committed one.
    func selected(_ f: ModelFamily) -> String {
        shownPrecision(preview: pendingLoads[f.id] ?? previews[f.id], loaded: loaded(f)?.precision, lastLoaded: lastLoaded(f),
                       recommended: recommended(f), family: f)
    }
    func isPreviewing(_ f: ModelFamily) -> Bool { previews[f.id] != nil }
    func recommendedHelp(_ f: ModelFamily) -> String? {
        recommended(f).map { recommendationHelp(benchmarks.models[f.id], recommended: $0, native: f.native) }
    }
    /// The deltas' base: the recommended precision, else native.
    func base(_ f: ModelFamily) -> String { recommended(f) ?? f.native }
    func result(_ f: ModelFamily, _ precision: String) -> PrecisionResult? { benchmarks.models[f.id]?.result(precision) }
    func installed(_ f: ModelFamily, _ precision: String) -> InstalledModel? {
        f.variants[precision].flatMap { library(f.mode).installed[$0.id] }
    }
    /// The downloadable precision a derived one resolves to (itself when published).
    func downloadRoot(_ f: ModelFamily, _ precision: String) -> String? { f.downloadSource(of: precision)?.label }
    /// Whether the precision can load without a download: its own weights, or (derived) its source's.
    func available(_ f: ModelFamily, _ precision: String) -> Bool {
        if installed(f, precision) != nil { return true }
        guard derivedSource(f, precision) != nil, let root = downloadRoot(f, precision) else { return false }
        return installed(f, root) != nil
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

    func action(_ f: ModelFamily) -> LoadAction {
        let precision = selected(f)
        return loadAction(selected: precision, loaded: loaded(f)?.precision, native: f.native, downloaded: available(f, precision))
    }
    /// Whether the row's button starts a download (after the confirmation popup).
    func needsDownload(_ f: ModelFamily) -> Bool { action(f) != .unload && !available(f, selected(f)) }

    /// A Q segment click: preview that precision (its numbers, deltas and button). Picking the committed precision
    /// ends the preview. Nothing is written; only Load/Reload changes the model.
    func preview(_ f: ModelFamily, _ precision: String) {
        previews[f.id] = precision == committed(f) ? nil : precision
    }
    /// The menu closed: previews end without effect.
    func discardPreviews() { if !previews.isEmpty { previews = [:] } }
    /// Render harness: previews without a click.
    func previewSelections(_ values: [String: String]) { previews = values }

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
        let started = lib.download(approval: approval, calibrate: false) { [weak self] installed in
            guard let self else { return }
            // A failure or cancellation stays in the footer (the library's error line).
            guard installed, self.available(f, precision) else { self.pendingLoads[f.id] = nil; return }
            self.commitWhenIdle(f, precision)
        }
        if !started { pendingLoads[f.id] = nil; lastError = lib.downloadError ?? lib.message }
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
        pendingLoads[f.id] = nil
        commit(f, precision, loaded(f) == nil ? .load : .reload)
    }
    static var idlePollSeconds = 0.2

    /// Load or Reload weights that are on disk. The runtime makes the model its mode's model once it loaded.
    private func commit(_ f: ModelFamily, _ precision: String, _ action: LoadAction) {
        guard let variant = f.variants[precision], let source = f.downloadSource(of: precision) else { return }
        let lib = library(f.mode)
        guard let local = lib.installed[source.variant.id] else { return }
        var path = local.path
        if variant.isDerived {
            // The worker derives from the source; the derived directory (a manifest) keeps its own model identity.
            do { path = try prepareDerivedModel(family: f, precision: precision, sourcePath: local.path, modelsDirectory: lib.modelsDirectory) }
            catch { lastError = "Could not prepare \(f.name) at \(precisionFormatName(precision)): \(error)"; return }
        }
        if let actions {
            action == .reload ? actions.reload(family: f, precision: precision, variant: variant, path: path)
                              : actions.load(family: f, precision: precision, variant: variant, path: path)
        } else if variant.isDerived {
            lastError = "\(f.name) at \(precisionFormatName(precision)) needs the recognition worker; use Start Worker (or Restart Worker) in Vella's menu and try again."
        } else {
            lib.selectedID = variant.id
            if !lib.useSelected() { lastError = lib.downloadError }
            reloadConfig()
        }
    }
    func cancelDownloads() { dictation.cancel(); streaming.cancel() }
}
