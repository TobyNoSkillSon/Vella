import AppKit
import Combine
import Foundation
import VellaCore

/// Connects the runtime (residency, memory, worker status) to the menu and Models table: the table's Load / Reload /
/// Unload / Delete, the Keep Hot and Memory submenus, the fact line, the first-dictation Get row, and the catalog
/// identity (family, precision, measured memory) of a model path.
@MainActor final class RuntimeBridge: ModelRuntimeActions, MenuSettingsSource {
    static let shared = RuntimeBridge()
    let runtime: Runtime
    private weak var controller: ModelsController?
    private weak var model: Model?
    private var subscription: AnyCancellable?
    init(runtime: Runtime? = nil) { self.runtime = runtime ?? .shared }

    func attach(_ delegate: AppDelegate) {
        attach(controller: delegate.modelsMenu.controller, model: delegate.model)
        delegate.menuSettings = self
        delegate.factLine = { [weak self] in self?.factLine }
        delegate.pendingModelRow = { [weak self] in
            guard let offer = self?.model?.pendingModelRequest else { return nil }
            return (offer.title, "Asks before downloading \(offer.name), then transcribes the saved recording and copies the text.")
        }
        delegate.getPendingModel = { [weak self] in self?.getPendingModel() }
        delegate.restartWorkers = { [weak self] in self?.restart() }
        delegate.modelsLoaded = { [weak self] in
            guard let status = self?.runtime.status else { return false }
            return !status.models.isEmpty || status.loading != nil
        }
    }
    func attach(controller: ModelsController, model: Model) {
        self.controller = controller; self.model = model
        controller.actions = self
        // The table reads what was loaded from the runtime's config.json; the retired per-family precision file
        // beside it is migrated once and deleted.
        if !controller.previewing {
            controller.configURL = runtime.configURL
            controller.reloadConfig()
            controller.migrateLegacySelections(from: runtime.configURL.deletingLastPathComponent().appendingPathComponent("model-precision.json"))
        }
        runtime.resolver = { [weak self] path, mode in self?.ref(path: path, mode: mode) }
        model.offerModel = { [weak self] mode in self?.offer(mode) }
        model.fetchModel = { [weak self] offer in
            guard let self else { throw CancellationError() }
            return try await self.fetch(offer)
        }
        subscription = runtime.$status.sink { [weak self] status in self?.publish(status) }
        publish(runtime.status)
    }

    /// Launch clean-up: partial downloads left in Vella's Models folder by a quit, crash or earlier version. An
    /// unfinished download's folder goes whole only when the registry and config.json were read, so the kept set is
    /// complete; otherwise only stale partial files go and every folder stays.
    func sweepPartialDownloads() {
        guard let controller, !controller.previewing else { return }
        let library = controller.dictation
        let config = controller.config
        let configRead = config != nil || !(controller.configURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        let verified = configRead && library.ownershipVerified && controller.streaming.ownershipVerified
        let keep = library.keptModelPaths.union(controller.streaming.keptModelPaths)
            .union([config?.model, config?.streamingModel].compactMap { $0 })
            .union(runtime.settings.launchSet.map(\.path))
        sweepStalePartialDownloads(modelsDirectory: library.modelsDirectory, keep: keep, removeFolders: verified)
    }

    // MARK: Catalog identity

    func ref(path: String, mode: RecognitionMode) -> ModelRef? {
        guard let controller else { return nil }
        let library = controller.library(mode)
        if let id = library.installed.first(where: { $0.value.path == path })?.key,
           let (family, precision) = controller.catalog.locate(variant: id) { return ref(family, precision, path: path) }
        // A precision made on this Mac: its directory holds only the derivation manifest (never in the registry).
        guard let manifest = derivedModelManifest(at: URL(fileURLWithPath: path)), let family = controller.catalog.family(manifest.family),
              family.variants[manifest.precision]?.isDerived == true else { return nil }
        return ref(family, manifest.precision, path: path)
    }
    func ref(_ family: ModelFamily, _ precision: String, path: String) -> ModelRef {
        ModelRef(id: family.id, precision: precision, path: path, mode: family.mode, name: family.name,
                 diskBytes: estimatedWeightBytes(family, precision).map { Int64($0) } ?? family.diskBytes(precision), memoryMB: admissionMemoryMB(family, precision),
                 precisionOptions: precisionOptions(family))
    }
    /// Memory admission plans with: the measured `memory_mb`, else (a precision made on this Mac, or any unmeasured
    /// one) vq-quant's estimate scaled from a measured precision. Nil only when nothing of the family is measured; then
    /// admission falls back to the weights on disk (for a derived precision its source's download, never 0) + overhead.
    func admissionMemoryMB(_ family: ModelFamily, _ precision: String) -> Double? {
        guard let controller else { return nil }
        if let measured = controller.result(family, precision)?.memory_mb { return measured }
        return estimatedMemory(family: family, precision: precision, benchmarks: controller.benchmarks).map(\.mb)
    }

    // MARK: ModelRuntimeActions

    /// The model becomes the mode's selection only once it loaded: a refused or failed Load/Reload keeps
    /// the previous selection, so the next dictation uses the model that still works.
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) {
        let ref = ref(family, precision, path: path)
        Task { await loadAndSelect(ref) }
    }
    func loadAndSelect(_ ref: ModelRef) async {
        runtime.beginSelection(); runtime.userChanged(ref.id)
        defer { runtime.userChanged(ref.id); runtime.endSelection() }
        do {
            try await runtime.load(ref)
            select(ref.path, mode: ref.mode)
        } catch { controller?.lastError = error.localizedDescription }
    }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) {
        load(family: family, precision: precision, variant: variant, path: path)
    }
    func unload(family: ModelFamily) { Task { await runtime.unload(family.id) } }
    /// Deleting weights also ends every precision made on this Mac from them: a loaded derived precision is unloaded
    /// first (its worker reads the source), and after a successful deletion the launch set drops the source and its
    /// derived entries. Order: unload, delete, launch-set clean-up.
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool {
        runtime.userChanged(family.id); defer { runtime.userChanged(family.id) }
        let dependents = derivedPaths(source: path, mode: family.mode)
        let loadedPath = runtime.loadedRef(family.id)?.path
        let target = loadedPath.map { loaded in dependents.contains { sameFiles($0, loaded) } ? loaded : path } ?? path
        let unloaded = await runtime.unloadForDeletion(family.id, path: target)
        guard delete() else {
            if let unloaded, unloaded.residency == .manual { try? await runtime.load(unloaded.ref) }
            return false
        }
        for deleted in [path] + dependents { runtime.deleted(path: deleted) }
        return true
    }
    /// Directories of precisions made on this Mac from the weights at `source`: manifests in the models directory and
    /// launch-set entries (a launch-set manifest may sit elsewhere, e.g. an older data directory).
    func derivedPaths(source: String, mode: RecognitionMode) -> [String] {
        var candidates: [URL] = runtime.settings.launchSet.map { URL(fileURLWithPath: $0.path) }
        if let directory = controller?.library(mode).modelsDirectory,
           let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { candidates += entries }
        var seen: Set<String> = []
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, let manifest = derivedModelManifest(at: url), sameFiles(manifest.source, source) else { return nil }
            return path
        }
    }
    private func sameFiles(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }
    /// A successful load makes the model its mode's model (what the next dictation or streaming session loads on
    /// demand) and records the family's precision, so the table and dictation never disagree.
    private func select(_ path: String, mode: RecognitionMode) {
        let url = runtime.configURL
        var config = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration(model: "")
        let identity = controller?.identify(path: path, mode: mode)
        config.recordLoad(path: path, mode: mode, family: identity?.family.id, precision: identity?.precision)
        try? JSONEncoder().encode(config).write(to: url, options: .atomic)
        controller?.library(mode).activeModelPath = path
        controller?.reloadConfig()
    }

    // MARK: MenuSettingsSource

    var manualIdleMinutes: Int { runtime.settings.manualIdleMinutes }
    var onDemandIdleMinutes: Int { runtime.settings.onDemandIdleMinutes }
    var allowSwap: Bool { runtime.settings.allowSwap }
    var availableMB: Double? { runtime.status.memory?.available_mb }
    var lastEvicted: String? {
        guard let last = runtime.status.evictions?.last, last.reason.hasPrefix("memory"), Date().timeIntervalSince1970 - last.at < 600 else { return nil }
        return controller?.catalog.family(last.model)?.name ?? last.model
    }
    func apply(_ action: SettingsAction) {
        switch action {
        case .keepHot(.manual, let minutes): runtime.setKeepHot(manual: minutes)
        case .keepHot(.onDemand, let minutes): runtime.setKeepHot(onDemand: minutes)
        case .memory(let allow): runtime.setAllowSwap(allow)
        }
    }
    /// "2 models loaded · 1.9 GB in memory"; nil when nothing is loaded.
    var factLine: String? {
        let models = runtime.status.models
        guard !models.isEmpty else { return nil }
        let mb = models.values.compactMap(\.memory_mb).reduce(0, +)
        return "\(models.count) model\(models.count == 1 ? "" : "s") loaded" + (mb > 0 ? " · \(gigabytes(mb)) GB in memory" : "")
    }
    func restart() {
        guard let model else { return }
        Task {
            try? await model.releaseWorkers()
            await runtime.loadLaunchSet()
        }
    }

    // MARK: Table state

    private func publish(_ status: WorkerStatus) {
        guard let controller, !controller.previewing else { return }
        var loaded: [String: LoadedFamily] = [:]
        for (id, entry) in status.models {
            loaded[id] = LoadedFamily(precision: entry.precision ?? "", engine: entry.engine, engineReason: entry.engine_reason,
                                      optimizations: entry.optimizations, residency: entry.residency)
        }
        controller.runtime = TableRuntime(loaded: loaded, loading: status.loading, chip: status.gpu?.chip, workerError: status.error,
                                          refusal: status.refused.map { TableRefusal(message: $0.message, at: $0.at) }, available: true)
    }

    // MARK: First dictation without a model

    /// The first offered family of the mode (catalog order) at its recommended precision.
    private func offered(_ mode: RecognitionMode) -> (family: ModelFamily, precision: String)? {
        guard let controller, let family = controller.catalog.offered(mode).first else { return nil }
        let precision = controller.recommended(family) ?? family.native
        return family.variants[precision] != nil ? (family, precision) : family.variants[family.native] != nil ? (family, family.native) : nil
    }
    /// The Get row downloads what the recommended precision needs: its own weights, or for a precision made on this
    /// Mac the weights it is made from.
    func offer(_ mode: RecognitionMode) -> Model.ModelOffer? {
        guard let (family, precision) = offered(mode), let source = family.downloadSource(of: precision) else { return nil }
        return Model.ModelOffer(id: source.variant.id, name: family.name, downloadBytes: source.variant.downloadBytes, mode: mode)
    }
    /// After the offered download: the path to use, the derived directory when the recommended precision is made here.
    private func offeredPath(_ offer: Model.ModelOffer, sourcePath: String) throws -> String {
        guard let controller, let (family, precision) = offered(offer.mode), family.isDerived(precision),
              family.downloadSource(of: precision)?.variant.id == offer.id else { return sourcePath }
        return try prepareDerivedModel(family: family, precision: precision, sourcePath: sourcePath,
                                       modelsDirectory: controller.library(offer.mode).modelsDirectory)
    }
    /// The download confirmation popup for the first-dictation Get row (tests answer it without a window).
    var presentDownload: (DownloadPrompt) -> Bool = { DownloadGate.presentAlert($0) }
    /// Approvals from the Get row's popup, consumed by `fetch`.
    private var approvals: [String: DownloadApproval] = [:]
    /// The popup for the offered download; nil when the catalog has none.
    func offerPrompt(_ offer: Model.ModelOffer) -> DownloadPrompt? {
        guard let controller, let (family, precision) = offered(offer.mode) else { return nil }
        return downloadPrompt(family: family, precision: precision, followUp: .transcribe,
                              freeBytes: freeDiskBytes(at: controller.library(offer.mode).modelsDirectory))
    }
    /// The Get row: asks first when the offer needs a download; on Download (or with the weights already on disk)
    /// fetches and transcribes the saved recording. Cancel keeps the recording and the row.
    func getPendingModel() {
        guard let model, let offer = model.pendingModelRequest, let controller else { return }
        if controller.library(offer.mode).installed[offer.id] == nil {
            guard let prompt = offerPrompt(offer), prompt.variantID == offer.id,
                  let approval = DownloadGate.ask(prompt, present: presentDownload) else { return }
            approvals[offer.id] = approval
        }
        model.getRecommendedModel()
    }
    /// Download (only with the Get row's approval) and validate the offered variant, select it for its mode, and
    /// return its path. Nothing loads or downloads until the user clicks the Get row and confirms.
    func fetch(_ offer: Model.ModelOffer) async throws -> String {
        guard let controller else { throw VellaError.message("Models are unavailable.") }
        let library = controller.library(offer.mode)
        if let local = library.installed[offer.id] {
            let path = try offeredPath(offer, sourcePath: local.path)
            select(path, mode: offer.mode); return path
        }
        guard let approval = approvals.removeValue(forKey: offer.id) else {
            throw VellaError.message("The download of \(offer.name) was not confirmed.")
        }
        library.selectedID = offer.id
        guard library.download(approval: approval, pendingRecording: true) else {
            throw VellaError.message(library.downloadError ?? "\(offer.name) did not start downloading.")
        }
        while library.downloadingID == offer.id || (library.busy && library.calibratingID == nil && library.installed[offer.id] == nil) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let local = library.installed[offer.id] else {
            throw VellaError.message(library.downloadError ?? "\(offer.name) did not download.")
        }
        let path = try offeredPath(offer, sourcePath: local.path)
        select(path, mode: offer.mode)
        return path
    }
}
