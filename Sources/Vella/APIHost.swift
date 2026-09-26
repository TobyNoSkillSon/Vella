import Foundation
import VellaCore

/// The app's models for the API: dictation families with weights on this Mac, from the Models table's catalog.
/// Holds the table's controller strongly (the controller never references the source, so there is no cycle).
@MainActor final class ControllerModelSource: APIModelSource {
    let controller: ModelsController
    let runtime: Runtime
    init(controller: ModelsController, runtime: Runtime) { self.controller = controller; self.runtime = runtime }

    private var currentPath: String {
        let config = (try? Data(contentsOf: runtime.configURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        return config?.model ?? ""
    }

    func models() -> [APIModel] {
        let current = currentPath
        let currentIdentity = controller.identify(path: current, mode: .dictation)
        var result: [APIModel] = []
        for family in controller.families(.dictation) {
            let loaded = runtime.loadedRef(family.id)
            var precision: String?, path: String?
            if let loaded { precision = loaded.precision; path = loaded.path }
            else if currentIdentity?.family.id == family.id { precision = currentIdentity?.precision; path = current }
            else {
                let preferred = controller.committed(family)
                let order = [preferred] + precisionOptions(family).filter { $0 != preferred }
                if let first = order.first(where: { controller.available(family, $0) }) {
                    precision = first
                    path = controller.installed(family, first)?.path ?? "" // derived: prepared on use
                }
            }
            guard let precision, let path else { continue }
            result.append(APIModel(id: family.id, name: family.name, precision: precision, path: path, languages: family.languages,
                                   loaded: loaded != nil, current: currentIdentity?.family.id == family.id))
        }
        // A current model outside the catalog (an imported folder) is still usable under its folder name.
        if currentIdentity == nil, !current.isEmpty, FileManager.default.fileExists(atPath: current) {
            let id = URL(fileURLWithPath: current).lastPathComponent
            result.append(APIModel(id: id, name: id, precision: "", path: current, loaded: runtime.loadedRef(id) != nil, current: true))
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
              let local = controller.library(.dictation).installed[source.variant.id] else {
            throw APIError(500, "\(model.name) has no files at \(model.precision)")
        }
        var prepared = model
        prepared.path = try prepareDerivedModel(family: family, precision: model.precision, sourcePath: local.path,
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
    func start(model: Model, controller: ModelsController, runtime: Runtime? = nil) {
        let runtime = runtime ?? model.backend.runtime
        guard server == nil, ProcessInfo.processInfo.environment["VELLA_API"] != "0" else { return }
        let root = runtime.support.appendingPathComponent("API", isDirectory: true)
        try? FileManager.default.removeItem(at: root) // an earlier launch's unfinished jobs
        let transcriber = APITranscriber(backend: model.backend, root: root.appendingPathComponent("jobs", isDirectory: true))
        transcriber.dictationActive = { [weak model] in
            guard let model else { return false }
            return model.phase == .recording || model.busy
        }
        let service = APIService(transcriber: transcriber, models: ControllerModelSource(controller: controller, runtime: runtime),
                                 scratch: root.appendingPathComponent("files", isDirectory: true))
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
