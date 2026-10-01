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
    private weak var model: DictationController?
    private var subscription: AnyCancellable?
    init(runtime: Runtime? = nil) { self.runtime = runtime ?? .shared }

    func attach(_ delegate: AppDelegate) {
        attach(controller: delegate.modelsMenu.controller, model: delegate.model)
        delegate.menuSettings = self
        delegate.factLine = { [weak self] in self?.factLine }
        delegate.pendingModelRow = { [weak self] in
            guard let offer = self?.model?.pendingModelRequest else { return nil }
            return (offer.title, offer.help)
        }
        delegate.getPendingModel = { [weak self] in self?.getPendingModel() }
        delegate.restartWorkers = { [weak self] in self?.restart() }
        delegate.startWorkers = { [weak self] in self?.start() }
        delegate.modelsLoaded = { [weak self] in
            guard let status = self?.runtime.status else { return false }
            return !status.models.isEmpty || status.loading != nil
        }
    }
    func attach(controller: ModelsController, model: DictationController) {
        self.controller = controller; self.model = model
        controller.actions = self
        // The table reads what was loaded from the runtime's config.json.
        if !controller.previewing {
            controller.configURL = runtime.configURL
            controller.reloadConfig()
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

    /// Launch migration of the installed-model registry (ModelLibrary.migrateRegistry): earlier ids of a catalogued
    /// format are re-keyed, removed models' entries dropped. Registry only; never files. Both libraries share it.
    /// Then a mode's model outside the catalog is cleared from config.json (ModelsController, files untouched).
    func migrateRegistry() {
        guard let controller, !controller.previewing else { return }
        let result = controller.dictation.migrateRegistry(catalog: controller.catalog)
        if !result.rekeyed.isEmpty || !result.dropped.isEmpty {
            controller.streaming.reload()
            runtime.log(
                "registry: re-keyed \(result.rekeyed.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value)" }.joined(separator: ", ")); dropped \(result.dropped.joined(separator: ", "))"
            )
        }
        // Manifests of precisions made on this Mac follow the catalog's current recipe (same folders; content only).
        let directories = Set([controller.dictation.modelsDirectory, controller.streaming.modelsDirectory].map(\.standardizedFileURL))
        let rewritten = directories.flatMap { migrateDerivedManifests(catalog: controller.catalog, modelsDirectory: $0) }
        if !rewritten.isEmpty {
            runtime.log("derived: rewrote to the catalog's current recipe: \(rewritten.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted().joined(separator: ", "))")
        }
        let cleared = controller.clearSelectionsOutsideTheCatalog()
        if !cleared.isEmpty {
            runtime.log("config: cleared models outside the catalog: \(cleared.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")
        }
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
            let (family, precision) = controller.catalog.locate(variant: id)
        {
            // A registered checkpoint runs as the precision only when it IS that recipe (`registeredCheckpoint`); one
            // re-keyed to a mixed tier (an imported uniform quantization) resolves like Load: the recipe made from the
            // 16-bit root, else nothing (never the import under the tier's name).
            guard registeredCheckpoint(family, precision, installedPath: { library.installed[$0]?.path }) != nil else {
                return runnablePath(family, precision).map { runnableRef(family, precision, path: $0) }
            }
            return runnableRef(family, precision, path: path)
        }
        // A precision made on this Mac: its directory holds only the derivation manifest (never in the registry). It
        // resolves like Load (precisionLoadPath), so it runs the catalog's current recipe.
        guard let manifest = derivedModelManifest(at: URL(fileURLWithPath: path)), let family = controller.catalog.family(manifest.family),
            family.variants[manifest.precision]?.isDerived == true
        else { return nil }
        return runnableRef(family, manifest.precision, path: runnablePath(family, manifest.precision) ?? path)
    }
    /// What a request for these files runs (`SelectionRules.runnable`, the table's rule): the loaded model when these
    /// files are loaded (its cell stays, whatever it is); else the recorded selection when it is offered and measured,
    /// else the table's fallback cell, at that cell's precision and files. A precision no longer offered (an older
    /// version's load) or a cell never measured therefore never loads, here or through the API.
    func runnableRef(_ family: ModelFamily, _ precision: String, path: String) -> ModelRef {
        if let loaded = runtime.loadedRef(family.id), sameFiles(loaded.path, path) { return loaded }
        guard let controller else { return ref(family, precision, path: path) }
        let rules = controller.rules(family)
        let config = (try? Data(contentsOf: runtime.configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        let runnable = rules.runnable(recorded: config?.selections[family.id], precision: precision, available: { controller.available(family, $0) })
        guard let valid = rules.precision(of: runnable), valid != precision else {
            return ref(family, precision, path: path, selection: runnable.tier == modelTier(ofPrecision: precision) ? runnable : nil)
        }
        guard let files = runnablePath(family, valid) else { return ref(family, precision, path: path) }
        if let loaded = runtime.loadedRef(family.id), sameFiles(loaded.path, files) { return loaded }
        return ref(family, valid, path: files, selection: runnable)
    }
    /// The files of a precision, resolved exactly as the Models table's Load does (`precisionLoadPath`): its
    /// registered checkpoint, or a precision made on this Mac (its manifest is written here; the worker makes the
    /// weights at load). Nil when its weights are not on this Mac.
    func runnablePath(_ family: ModelFamily, _ precision: String) -> String? {
        guard let controller else { return nil }
        let library = controller.library(family.mode)
        return try? precisionLoadPath(family, precision, installedPath: { library.installed[$0]?.path }, modelsDirectory: library.modelsDirectory)
    }
    /// `selection` nil: the family's recorded one (`defaultSelection`), so an on-demand load runs what the user chose.
    func ref(_ family: ModelFamily, _ precision: String, path: String, selection: ModelSelection? = nil) -> ModelRef {
        ModelRef(
            id: family.id, precision: precision, path: path, mode: family.mode, name: family.name,
            diskBytes: estimatedWeightBytes(family, precision).map { Int64($0) } ?? family.diskBytes(precision), memoryMB: admissionMemoryMB(family, precision),
            precisionOptions: precisionOptions(family), selection: selection ?? recordedSelection(family, precision))
    }
    func recordedSelection(_ family: ModelFamily, _ precision: String) -> ModelSelection {
        let config = (try? Data(contentsOf: runtime.configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        return VellaCore.recordedSelection(config: config, family: family.id, precision: precision)
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
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {
        let ref = ref(family, precision, path: path, selection: selection)
        Task { await loadAndSelect(ref) }
    }
    func loadAndSelect(_ ref: ModelRef) async {
        runtime.beginSelection(); runtime.userChanged(ref.id)
        defer { runtime.userChanged(ref.id); runtime.endSelection() }
        do {
            try await runtime.load(ref)
            select(ref.path, mode: ref.mode, selection: ref.selection)
        } catch { controller?.lastError = error.localizedDescription }
    }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {
        load(family: family, precision: precision, variant: variant, path: path, selection: selection)
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
            let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        {
            candidates += entries
        }
        var seen: Set<String> = []
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, let manifest = derivedModelManifest(at: url), sameFiles(manifest.source, source) else { return nil }
            return path
        }
    }
    /// A successful load makes the model its mode's model (what the next dictation or streaming session loads on
    /// demand) and records the family's precision, so the table and dictation never disagree.
    private func select(_ path: String, mode: RecognitionMode, selection: ModelSelection? = nil) {
        let url = runtime.configURL
        var config = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration(model: "")
        let identity = controller?.identify(path: path, mode: mode)
        config.recordLoad(path: path, mode: mode, family: identity?.family.id, precision: identity?.precision, selection: selection)
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
    /// Start Worker (no worker running): the launch set, as at app launch; with an empty launch set, the current
    /// mode's selected model, loaded on demand as a dictation would load it. Nothing selected: nothing to start.
    func start() {
        guard let model else { return }
        Task {
            await runtime.loadLaunchSet()
            guard runtime.status.models.isEmpty, runtime.status.loading == nil,
                let config = try? model.backend.configuration(requiresModel: false)
            else { return }
            let mode = model.mode
            let path = mode == .dictation ? config.model : config.streamingModel
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            let ref = runtime.resolve(path, mode: mode)
            switch mode {
            case .dictation: try? await model.backend.preload(ref, residency: .onDemand)
            case .streaming: try? await model.streamingBackend.preload(ref, residency: .onDemand)
            }
        }
    }

    // MARK: Table state

    private func publish(_ status: WorkerStatus) {
        guard let controller, !controller.previewing else { return }
        var loaded: [String: LoadedFamily] = [:]
        for (id, entry) in status.models {
            loaded[id] = LoadedFamily(
                precision: entry.precision ?? "", engine: entry.engine, engineReason: entry.engine_reason,
                optimizations: entry.optimizations, residency: entry.residency, selection: entry.selection)
        }
        controller.runtime = TableRuntime(
            loaded: loaded, loading: status.loading, chip: status.gpu?.chip, workerError: status.error,
            refusal: status.refused.map { TableRefusal(message: $0.message, at: $0.at) }, available: true)
    }

    // MARK: First dictation without a model

    /// The first offered family of the mode (catalog order) at its recommended precision.
    private func offered(_ mode: RecognitionMode) -> (family: ModelFamily, precision: String)? { controller?.firstOffered(mode) }
    /// The Get row downloads what the recommended precision needs: its own weights, or for a precision made on this
    /// Mac the weights it is made from.
    func offer(_ mode: RecognitionMode) -> DictationController.ModelOffer? { controller?.firstOffer(mode) }
    /// After the offered download: the path to use, the derived directory when the recommended precision is made here.
    private func offeredPath(_ offer: DictationController.ModelOffer, sourcePath: String) throws -> String {
        guard let controller, let (family, precision) = offered(offer.mode), family.isDerived(precision), family.variants[precision]?.isStored != true,
            family.downloadSource(of: precision)?.variant.id == offer.id
        else { return sourcePath }
        return try prepareDerivedModel(
            family: family, precision: precision, sourcePath: sourcePath,
            modelsDirectory: controller.library(offer.mode).modelsDirectory)
    }
    /// The first-dictation Get row's selection: the family's recorded one, else Optimized · Fast at the offered tier
    /// (the default for a model never loaded).
    private func offerSelection(_ offer: DictationController.ModelOffer) -> ModelSelection? {
        guard let (family, precision) = offered(offer.mode) else { return nil }
        let config = (try? Data(contentsOf: runtime.configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        return defaultSelection(recorded: config?.selections[family.id], precision: precision)
    }
    /// The download confirmation popup for the first-dictation Get row (tests answer it without a window).
    var presentDownload: (DownloadPrompt) -> Bool = { DownloadGate.presentAlert($0) }
    /// Approvals from the Get row's popup, consumed by `fetch`.
    private var approvals: [String: DownloadApproval] = [:]
    /// The popup for the offered download; nil when the catalog has none.
    func offerPrompt(_ offer: DictationController.ModelOffer) -> DownloadPrompt? {
        guard let controller, let (family, precision) = offered(offer.mode) else { return nil }
        return downloadPrompt(
            family: family, precision: precision, followUp: .transcribe,
            freeBytes: freeDiskBytes(at: controller.library(offer.mode).modelsDirectory))
    }
    /// The Get row: asks first when the offer needs a download; on Download (or with the weights already on disk)
    /// fetches and transcribes the saved recording. Cancel keeps the recording and the row.
    func getPendingModel() {
        guard let model, let offer = model.pendingModelRequest, let controller else { return }
        if controller.library(offer.mode).installed[offer.id] == nil {
            guard let prompt = offerPrompt(offer), prompt.variantID == offer.id,
                let approval = DownloadGate.ask(prompt, present: presentDownload)
            else { return }
            approvals[offer.id] = approval
        }
        model.getRecommendedModel()
    }
    /// Download (only with the Get row's approval) and validate the offered variant, select it for its mode, and
    /// return its path. Nothing loads or downloads until the user clicks the Get row and confirms.
    func fetch(_ offer: DictationController.ModelOffer) async throws -> String {
        guard let controller else { throw VellaError.message("Models are unavailable.") }
        let library = controller.library(offer.mode)
        if let local = library.installed[offer.id] {
            let path = try offeredPath(offer, sourcePath: local.path)
            select(path, mode: offer.mode, selection: offerSelection(offer)); return path
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
        select(path, mode: offer.mode, selection: offerSelection(offer))
        return path
    }
}
