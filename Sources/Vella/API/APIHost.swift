import Foundation
import VellaCore

/// The app's models for the API: dictation families with weights on this Mac, from the Models table's catalog.
/// Holds the table's controller strongly (the controller never references the source, so there is no cycle).
@MainActor final class ControllerModelSource: APIModelSource {
    let controller: ModelsController
    let runtime: Runtime
    init(controller: ModelsController, runtime: Runtime) { self.controller = controller; self.runtime = runtime }

    /// The current family is always at its selected precision (what the next dictation loads), even when another
    /// precision of it is loaded (a saved recording retried with an older one); other families at their loaded
    /// precision, else the committed one.
    func models() -> [APIModel] {
        let config = (try? Data(contentsOf: runtime.configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        let current = config?.model ?? ""
        let currentIdentity = controller.identify(path: current, mode: .dictation)
        var result: [APIModel] = []
        for family in controller.families(.dictation) {
            let loaded = runtime.loadedRef(family.id)
            var precision: String?, path: String?
            if currentIdentity?.family.id == family.id {
                precision = currentIdentity?.precision; path = current
            } else if let loaded {
                precision = loaded.precision; path = loaded.path
            } else {
                let preferred = controller.committed(family)
                let order = [preferred] + precisionOptions(family).filter { $0 != preferred }
                if let first = order.first(where: { controller.available(family, $0) }) {
                    precision = first
                    path = controller.installed(family, first)?.path ?? "" // derived: prepared on use
                }
            }
            guard var precision, var path else { continue }
            var isLoaded = loaded?.path == path
            var requested: ModelSelection
            if isLoaded, let selection = loaded?.selection {
                requested = selection
            } else {
                // Not loaded (or loaded without a reported selection): the table's rule (`SelectionRules.runnable`),
                // so a recorded precision no longer offered or a cell never measured is neither reported nor loaded.
                let rules = controller.rules(family)
                // The recorded precision (the mode's model, else `lastLoaded`), as the table reads it.
                let record = isLoaded ? precision : controller.lastLoaded(family) ?? precision
                requested = rules.runnable(recorded: config?.selections[family.id], precision: record, available: { [controller] in controller.available(family, $0) })
                if !isLoaded, let valid = rules.precision(of: requested), valid != precision, controller.available(family, valid) {
                    precision = valid
                    path = controller.installed(family, valid)?.path ?? "" // derived: prepared on use
                    if let loaded, loaded.precision == valid {
                        path = loaded.path; isLoaded = true; requested = loaded.selection ?? requested
                    }
                } else if requested.tier != modelTier(ofPrecision: precision) {
                    requested = recordedSelection(config: config, family: family.id, precision: precision)
                }
            }
            let running = effectiveSelection(requested, engine: isLoaded ? runtime.status.models[family.id]?.engine : nil)
            result.append(
                APIModel(
                    id: family.id, name: family.name, precision: precision, path: path, languages: family.languages,
                    loaded: isLoaded, current: currentIdentity?.family.id == family.id,
                    selection: running, requested: running == requested ? nil : requested))
        }
        return result
    }

    func unavailableReason(_ id: String) -> String? {
        guard let family = controller.catalog.families.first(where: { $0.id.lowercased() == id.lowercased() }) else { return nil }
        if family.mode == .streaming { return "\(family.name) is a Streaming model; the API transcribes files with Dictation models (see GET /v1/models)." }
        return "\(family.name) is not downloaded. Get it in Vella → Models… (Vella never downloads without asking)."
    }

    func prepare(_ model: APIModel) throws -> APIModel {
        guard model.path.isEmpty else { return model }
        guard let family = controller.catalog.family(model.id), let variant = family.variants[model.precision],
            variant.isDerived, let source = family.downloadSource(of: model.precision),
            let local = controller.library(.dictation).installed[source.variant.id]
        else {
            throw APIError(500, "\(model.name) has no files at \(model.precision)")
        }
        var prepared = model
        prepared.path = try prepareDerivedModel(
            family: family, precision: model.precision, sourcePath: local.path,
            modelsDirectory: controller.library(.dictation).modelsDirectory)
        return prepared
    }
}

/// Owns the app's API: the listener, the routes and the job runner; publishes the port in the status file.
@MainActor final class APIHost {
    static let shared = APIHost()
    private(set) var server: APIServer?
    private(set) var service: APIService?

    /// Starts the API on an ephemeral loopback port. `VELLA_API=0` turns it off (diagnosis).
    func start(model: DictationController, controller: ModelsController, runtime: Runtime? = nil) {
        let runtime = runtime ?? model.backend.runtime
        guard server == nil, ProcessInfo.processInfo.environment["VELLA_API"] != "0" else { return }
        let root = runtime.support.appendingPathComponent("API", isDirectory: true)
        try? FileManager.default.removeItem(at: root) // an earlier launch's unfinished jobs
        let transcriber = APITranscriber(backend: model.backend, root: root.appendingPathComponent("jobs", isDirectory: true))
        transcriber.dictationActive = { [weak model] in
            guard let model else { return false }
            return model.phase == .recording || model.busy
        }
        let service = APIService(
            transcriber: transcriber, models: ControllerModelSource(controller: controller, runtime: runtime),
            scratch: root.appendingPathComponent("files", isDirectory: true))
        service.controls = ModelControls(controller: controller, runtime: runtime)
        service.dictationState = { [weak model] in
            switch model?.phase {
            case .recording?: return "recording"
            case .preparing?, .transcribing?: return "transcribing"
            default: return model?.busy == true ? "transcribing" : "idle"
            }
        }
        do {
            let server = try APIServer(uploads: root.appendingPathComponent("uploads", isDirectory: true), handler: service)
            self.server = server; self.service = service
            runtime.apiToken = UUID().uuidString + UUID().uuidString
            server.start { port in
                if let port { runtime.apiPort = port } else { runtime.log("api: listener failed") }
            }
        } catch { runtime.log("api: \(error.localizedDescription)") }
    }
    func stop() { server?.stop(); server = nil }
}

extension AppDelegate {
    /// The launch wiring of the API (App.swift's main): the delegate's model and its Models table's controller.
    func startAPI(_ host: APIHost? = nil) { (host ?? .shared).start(model: model, controller: modelsMenu.controller) }
}
