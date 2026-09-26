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
            return (offer.title, "Downloads \(offer.name), then transcribes the saved recording and copies the text.")
        }
        delegate.getPendingModel = { [weak self] in self?.model?.getRecommendedModel() }
        delegate.restartWorkers = { [weak self] in self?.restart() }
    }
    func attach(controller: ModelsController, model: Model) {
        self.controller = controller; self.model = model
        controller.actions = self
        runtime.resolver = { [weak self] path, mode in self?.ref(path: path, mode: mode) }
        model.offerModel = { [weak self] mode in self?.offer(mode) }
        model.fetchModel = { [weak self] offer in
            guard let self else { throw CancellationError() }
            return try await self.fetch(offer)
        }
        subscription = runtime.$status.sink { [weak self] status in self?.publish(status) }
        publish(runtime.status)
    }

    // MARK: Catalog identity

    func ref(path: String, mode: RecognitionMode) -> ModelRef? {
        guard let controller else { return nil }
        let library = controller.library(mode)
        guard let id = library.installed.first(where: { $0.value.path == path })?.key,
              let (family, precision) = controller.catalog.locate(variant: id) else { return nil }
        return ref(family, precision, path: path)
    }
    private func ref(_ family: ModelFamily, _ precision: String, path: String) -> ModelRef {
        ModelRef(id: family.id, precision: precision, path: path, mode: family.mode, name: family.name,
                 diskBytes: family.variants[precision]?.downloadBytes, memoryMB: controller?.result(family, precision)?.memory_mb,
                 precisionOptions: precisionOptions(family))
    }

    // MARK: ModelRuntimeActions

    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) {
        select(path, mode: family.mode)
        let ref = ref(family, precision, path: path)
        Task { do { try await runtime.load(ref) } catch { controller?.lastError = error.localizedDescription } }
    }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) {
        load(family: family, precision: precision, variant: variant, path: path)
    }
    func unload(family: ModelFamily) { Task { await runtime.unload(family.id) } }
    func forget(family: ModelFamily) { Task { await runtime.forget(family.id) } }
    /// Load also selects the model for its mode (what the next dictation uses).
    private func select(_ path: String, mode: RecognitionMode) {
        let url = runtime.configURL
        var config = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration(model: "")
        config.selectModel(path, for: mode)
        try? JSONEncoder().encode(config).write(to: url, options: .atomic)
        controller?.library(mode).activeModelPath = path
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
    func offer(_ mode: RecognitionMode) -> Model.ModelOffer? {
        guard let controller, let family = controller.catalog.offered(mode).first else { return nil }
        let precision = controller.recommended(family) ?? family.native
        guard let variant = family.variants[precision] ?? family.variants[family.native] else { return nil }
        return Model.ModelOffer(id: variant.id, name: family.name, downloadBytes: variant.downloadBytes, mode: mode)
    }
    /// Download and validate the offered variant, select it for its mode, and return its path. Nothing loads or
    /// downloads until the user clicks the Get row.
    func fetch(_ offer: Model.ModelOffer) async throws -> String {
        guard let controller else { throw VellaError.message("Models are unavailable.") }
        let library = controller.library(offer.mode)
        if let local = library.installed[offer.id] { select(local.path, mode: offer.mode); return local.path }
        library.selectedID = offer.id
        library.download(pendingRecording: true)
        while library.downloadingID == offer.id || (library.busy && library.calibratingID == nil && library.installed[offer.id] == nil) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let local = library.installed[offer.id] else {
            throw VellaError.message(library.downloadError ?? "\(offer.name) did not download.")
        }
        select(local.path, mode: offer.mode)
        return local.path
    }
}
