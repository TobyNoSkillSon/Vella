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
    /// Delete, ordered after unload (Review 1 R10): unload these files if they are the loaded ones and wait for the
    /// worker to exit, then run `delete`; only when it succeeded drop the launch-set entry for these files (loaded or
    /// already evicted). A failed deletion keeps the launch set and reloads a manual model it unloaded.
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool
}

/// The Models table's state: catalog families of both modes, measured numbers, precision selections, what is
/// downloaded (the two mode libraries) and what is loaded (the runtime).
@MainActor final class ModelsController: ObservableObject {
    let dictation: ModelLibrary
    let streaming: ModelLibrary
    @Published var catalog: ModelCatalog
    @Published var benchmarks: BenchmarkFile
    @Published private(set) var selections: [String: String]
    /// Runtime state from the worker status; nil = no runtime attached (loaded = the mode's selected model).
    @Published var runtime: TableRuntime?
    @Published var lastError: String?
    /// True in the render harness: nothing is written, no worker is asked.
    var previewing = false
    weak var actions: ModelRuntimeActions?
    let selectionsURL: URL
    private var forwarding: [AnyCancellable] = []

    init(dictation: ModelLibrary? = nil, streaming: ModelLibrary? = nil, benchmarksURL: URL? = nil, selectionsURL: URL? = nil) {
        let dictation = dictation ?? ModelLibrary(mode: .dictation)
        self.dictation = dictation
        self.streaming = streaming ?? (dictation.registryURL == ModelLibrary.registry ? ModelLibrary(mode: .streaming)
            : ModelLibrary(mode: .streaming, resources: dictation.resources, registryURL: dictation.registryURL))
        self.selectionsURL = selectionsURL ?? dictation.registryURL.deletingLastPathComponent().appendingPathComponent("model-precision.json")
        catalog = (try? decodeCatalog(Data(contentsOf: dictation.resources.appendingPathComponent("models.json")))) ?? ModelCatalog(families: [])
        benchmarks = decodeBenchmarks(try? Data(contentsOf: benchmarksURL ?? Self.benchmarksURL(resources: dictation.resources)))
        selections = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: self.selectionsURL))) ?? [:]
        // Download progress and registry changes redraw the table.
        for library in [self.dictation, self.streaming] {
            forwarding.append(library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    /// `VELLA_BENCHMARKS` (a fixture for renders and tests), else the bundled Resources/benchmarks.json.
    static func benchmarksURL(resources: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment["VELLA_BENCHMARKS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return resources.appendingPathComponent("benchmarks.json")
    }

    func reload() {
        dictation.reload(); streaming.reload()
        if let catalog = try? decodeCatalog(Data(contentsOf: dictation.resources.appendingPathComponent("models.json"))) { self.catalog = catalog }
    }

    func library(_ mode: RecognitionMode) -> ModelLibrary { mode == .dictation ? dictation : streaming }

    /// Rows of one section: offered families, plus any other family with downloaded weights so it stays manageable.
    func families(_ mode: RecognitionMode) -> [ModelFamily] {
        catalog.families.filter { $0.mode == mode && ($0.offered || $0.variants.values.contains { library(mode).installed[$0.id] != nil }) }
    }
    var rowCount: Int { families(.dictation).count + families(.streaming).count }
    var sectionCount: Int { [RecognitionMode.dictation, .streaming].filter { !families($0).isEmpty }.count }

    func options(_ f: ModelFamily) -> [String] { precisionOptions(f) }
    /// The Q control's segment labels (bare widths), parallel to `options`.
    func segmentLabels(_ f: ModelFamily) -> [String] { precisionSegmentLabels(options(f)) }
    /// The precision a derived one is made from, nil for a published precision.
    func derivedSource(_ f: ModelFamily, _ precision: String) -> String? { f.variants[precision]?.derivedFrom }
    /// On disk for a precision: a published download's pinned size, else the measured size (`\u{2014}` otherwise).
    func disk(_ f: ModelFamily, _ precision: String) -> Int64? { tableDiskBytes(f, precision, result(f, precision)) }

    /// A Q segment's tooltip: the exact format, where it comes from (published, or made on this Mac from a higher
    /// precision), whether it is measured, and the recommendation or pending Reload when they apply.
    func segmentHelp(_ f: ModelFamily, _ precision: String) -> String {
        var text = precisionFormatName(precision)
        if precision == f.native { text += ", the model's native precision" }
        if let source = derivedSource(f, precision) {
            text += ". Made on this Mac from the \(precisionFormatName(source)) weights"
            if let root = downloadRoot(f, precision), let v = f.variants[root], installed(f, root) == nil {
                text += "; Get downloads those (\(formatBytes(v.downloadBytes)))"
            }
            text += "."
        } else if let v = f.variants[precision], !v.repository.isEmpty {
            text += ". Published: \(v.repository)."
        } else {
            text += "."
        }
        if result(f, precision)?.wer == nil { text += " Not measured yet." }
        if precision == recommended(f), let help = recommendedHelp(f) { text += " " + help }
        if let loaded = loaded(f)?.precision, loaded != precision {
            text += " Loaded at \(precisionFormatName(loaded)); Reload applies the selection."
        }
        return text
    }
    func recommended(_ f: ModelFamily) -> String? { recommendedPrecision(for: f, in: benchmarks) }
    func selected(_ f: ModelFamily) -> String {
        selectedPrecision(stored: selections[f.id], loaded: loaded(f)?.precision, recommended: recommended(f), family: f)
    }
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
    /// Whether the selected precision can load without a download: its own weights, or (derived) its source's.
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
    /// The header's model label for a mode (`Parakeet v3 4-bit`): the model selected for the mode if loaded or known,
    /// else the first loaded model of that mode.
    func activeLabel(_ mode: RecognitionMode) -> String? {
        let lib = library(mode)
        if !lib.activeModelPath.isEmpty, let id = lib.installed.first(where: { $0.value.path == lib.activeModelPath })?.key,
           let (family, precision) = catalog.locate(variant: id) { return "\(family.name) \(precisionBitsName(precision))" }
        guard let (id, loaded) = runtime?.loaded.filter({ catalog.family($0.key)?.mode == mode }).sorted(by: { $0.key < $1.key }).first,
              let family = catalog.family(id) else { return lib.activeModelLabel }
        return "\(family.name) \(precisionBitsName(loaded.precision))"
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

    func setPrecision(_ f: ModelFamily, _ precision: String) {
        selections[f.id] = storedPrecision(precision, native: f.native)
        guard !previewing else { return }
        do {
            try FileManager.default.createDirectory(at: selectionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(selections).write(to: selectionsURL, options: .atomic)
        } catch { lastError = "Could not save the precision choice: \(error.localizedDescription)" }
    }
    /// Render harness: selections without touching disk.
    func previewSelections(_ values: [String: String]) { selections = values }

    /// The row button: Get downloads the selected precision; Load, Reload and Unload go to the runtime.
    func perform(_ f: ModelFamily) {
        guard !previewing else { return }
        lastError = nil
        let precision = selected(f)
        guard let variant = f.variants[precision] else { return }
        let lib = library(f.mode)
        // A derived precision downloads the weights it is made from.
        guard let source = f.downloadSource(of: precision) else { lastError = "\(f.name) at \(precisionFormatName(precision)) has no source in the catalog."; return }
        switch action(f) {
        case .get:
            lib.selectedID = source.variant.id; lib.download()
        case .unload:
            if let actions { actions.unload(family: f) }
        case .load, .reload:
            guard let local = lib.installed[source.variant.id] else { lib.selectedID = source.variant.id; lib.download(); return }
            var path = local.path
            if variant.isDerived {
                // The worker derives from the source; the derived directory (a manifest) keeps its own model identity.
                do { path = try prepareDerivedModel(family: f, precision: precision, sourcePath: local.path, modelsDirectory: lib.modelsDirectory) }
                catch { lastError = "Could not prepare \(f.name) at \(precisionFormatName(precision)): \(error)"; return }
            }
            setPrecision(f, precision)   // what was loaded stays the selection
            if let actions {
                action(f) == .reload ? actions.reload(family: f, precision: precision, variant: variant, path: path)
                                     : actions.load(family: f, precision: precision, variant: variant, path: path)
            } else if variant.isDerived {
                lastError = "\(f.name) at \(precisionFormatName(precision)) needs the recognition worker; use Restart Worker and try again."
            } else {
                lib.selectedID = variant.id
                if !lib.useSelected() { lastError = lib.downloadError }
            }
        }
    }
    func cancelDownloads() { dictation.cancel(); streaming.cancel() }
}
