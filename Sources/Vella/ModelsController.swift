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
    /// Before Delete: unload and leave the launch set.
    func forget(family: ModelFamily)
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
    /// The header's model label for a mode (`Parakeet v3 4b`): the model selected for the mode if loaded or known,
    /// else the first loaded model of that mode.
    func activeLabel(_ mode: RecognitionMode) -> String? {
        let lib = library(mode)
        if !lib.activeModelPath.isEmpty, let id = lib.installed.first(where: { $0.value.path == lib.activeModelPath })?.key,
           let (family, precision) = catalog.locate(variant: id) { return "\(family.name) \(precision)" }
        guard let (id, loaded) = runtime?.loaded.filter({ catalog.family($0.key)?.mode == mode }).sorted(by: { $0.key < $1.key }).first,
              let family = catalog.family(id) else { return lib.activeModelLabel }
        return "\(family.name) \(loaded.precision)"
    }
    func isLoading(_ f: ModelFamily) -> Bool {
        runtime?.loading == f.id || f.variants.values.contains { library(f.mode).downloadingID == $0.id }
    }
    var anyBusy: Bool { dictation.busy || streaming.busy || runtime?.loading != nil }
    var runtimeAvailable: Bool { runtime?.available ?? true }

    func action(_ f: ModelFamily) -> LoadAction {
        let precision = selected(f)
        return loadAction(selected: precision, loaded: loaded(f)?.precision, native: f.native, downloaded: installed(f, precision) != nil)
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
        switch action(f) {
        case .get:
            lib.selectedID = variant.id; lib.download()
        case .unload:
            if let actions { actions.unload(family: f) }
        case .load, .reload:
            guard let local = lib.installed[variant.id] else { lib.selectedID = variant.id; lib.download(); return }
            setPrecision(f, precision)   // what was loaded stays the selection
            if let actions {
                action(f) == .reload ? actions.reload(family: f, precision: precision, variant: variant, path: local.path)
                                     : actions.load(family: f, precision: precision, variant: variant, path: local.path)
            } else {
                lib.selectedID = variant.id
                if !lib.useSelected() { lastError = lib.downloadError }
            }
        }
    }
    func cancelDownloads() { dictation.cancel(); streaming.cancel() }
}
