import CoreFoundation
import Foundation
import VellaCore

/// Authenticated controls use the table's controller, gate, download prompt and runtime actions.
@MainActor final class ModelControls {
    let controller: ModelsController
    let runtime: Runtime
    init(controller: ModelsController, runtime: Runtime) { self.controller = controller; self.runtime = runtime }

    func catalog() -> [[String: Any]] {
        RecognitionMode.allCases.flatMap { controller.families($0) }.map(object)
    }
    func family(_ id: String) throws -> ModelFamily {
        guard let f = RecognitionMode.allCases.flatMap({ controller.families($0) }).first(where: { $0.id.lowercased() == id.lowercased() }) else {
            throw APIError(404, "unknown model \(id); see GET /v1/models/catalog", code: "model_not_found")
        }
        return f
    }
    func object(_ f: ModelFamily) -> [String: Any] {
        let asked = controller.committedSelection(f)
        let running = effectiveSelection(asked, engine: runtime.status.models[f.id]?.engine)
        let precision = controller.committed(f)
        var o: [String: Any] = ["id": f.id, "name": f.name, "mode": f.mode.title, "precision": precision,
                               "dtype": tierDTypeLabel(f, running.tier), "selection": selectionObject(running),
                               "loaded": controller.loaded(f) != nil, "downloaded": controller.available(f, precision)]
        if running != asked { o["requested_selection"] = selectionObject(asked) }
        if controller.isPreviewing(f) {
            o["preview_selection"] = selectionObject(controller.currentSelection(f))
            o["preview_precision"] = tierDTypeLabel(f, controller.currentSelection(f).tier)
        }
        let selectedPath = controller.config.map { f.mode == .dictation ? $0.model : $0.streamingModel } ?? ""
        o["current"] = controller.identify(path: selectedPath, mode: f.mode)?.family.id == f.id
        o["action"] = String(describing: controller.action(f)).capitalized
        if let chosen = controller.rules(f).precision(of: controller.currentSelection(f)), let source = f.acquisition(of: chosen) {
            o["download"] = ["bytes": source.download.downloadBytes, "source": source.download.repository, "revision": source.download.revision]
        }
        o["cells"] = ModelTier.allCases.flatMap { tier -> [[String: Any]] in
            EnginePath.allCases.flatMap { path -> [[String: Any]] in
                (path == .standard ? [OptimizedMode.fast] : OptimizedMode.allCases).map { mode in
                    let s = ModelSelection(tier: tier, path: path, mode: mode)
                    var cell = selectionObject(s)
                    cell["precision"] = tierDTypeLabel(f, tier)
                    if let reason = controller.rules(f).cellRefusal(s, loaded: controller.loadedSelection(f)) { cell["reason"] = reason }
                    return cell
                }
            }
        }
        return o
    }
    func selection(_ fields: [String: Any], family: ModelFamily) throws -> ModelSelection {
        let existing = controller.currentSelection(family)
        var s = existing
        if let value = fields["precision"] {
            guard let precision = value as? String,
                  let tier = ModelTier.allCases.first(where: { tierDTypeLabel(family, $0) == precision.lowercased() }) else {
                throw APIError(400, "Precision must be \(tierDTypeLabel(family, .t16)), int8 or int4", param: "precision")
            }
            s.tier = tier
        }
        if let value = fields["path"] {
            guard let string = value as? String, let path = EnginePath(rawValue: string.lowercased()) else {
                throw APIError(400, "Path must be Standard or Optimized", param: "path")
            }
            s.path = path
        }
        if let value = fields["mode"] {
            guard let string = value as? String, let mode = OptimizedMode(rawValue: string.lowercased()) else {
                throw APIError(400, "Mode must be Fast or Exact", param: "mode")
            }
            s.mode = mode
        }
        return s
    }
    func perform(_ action: String, id: String, fields: [String: Any]) async throws -> [String: Any] {
        let f = try family(id)
        let allowed: Set<String> = action == "select" ? ["precision", "path", "mode"] : ["yes"]
        guard Set(fields.keys).isSubset(of: allowed) else { throw APIError(400, "Unknown model control field") }
        if action == "select" {
            guard !fields.isEmpty else { throw APIError(400, "Select needs Precision, path or Fast/Exact") }
            let chosen = try selection(fields, family: f)
            if Set(fields.keys) == ["mode"] { try controller.setModeForControl(f, mode: chosen.mode) }
            else { try controller.selectForControl(f, selection: chosen) }
        } else {
            var yes = false
            if let value = fields["yes"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw APIError(400, "yes must be true or false") }
                yes = flag.boolValue
            }
            if yes && action != "get" { throw APIError(400, "Download consent belongs to Get, not \(action.capitalized)") }
            try await controller.performForControl(f, action: action, yes: yes)
        }
        return object(f)
    }
    func settings() -> [String: Any] {
        let s = runtime.settings
        func title(_ minutes: Int) -> String { keepHotChoices.first(where: { $0.minutes == minutes })?.title ?? "\(minutes) min idle" }
        return ["Keep Hot": ["Manually loaded": title(s.manualIdleMinutes), "Loaded on demand": title(s.onDemandIdleMinutes)],
                "Memory": s.allowSwap ? allowSwapTitle : fitInFreeMemoryTitle]
    }
    func setting(_ action: String, fields: [String: Any]) throws -> [String: Any] {
        guard let source = controller.actions as? any MenuSettingsSource else { throw APIError(503, "Vella's settings runtime is not running.") }
        if action == "memory" {
            guard Set(fields.keys) == ["value"], let value = fields["value"] as? String,
                  [fitInFreeMemoryTitle, allowSwapTitle].contains(value) else {
                throw APIError(400, "Memory must be \(fitInFreeMemoryTitle) or \(allowSwapTitle)")
            }
            source.apply(.memory(allowSwap: value == allowSwapTitle))
        } else {
            guard Set(fields.keys) == ["class", "value"], let kind = fields["class"] as? String, let value = fields["value"] as? String,
                  ["Manually loaded", "Loaded on demand"].contains(kind), let choice = keepHotChoices.first(where: { $0.title == value }) else {
                throw APIError(400, "Keep Hot needs class Manually loaded / Loaded on demand and value Always / 5 min idle / 15 min idle / 30 min idle / 60 min idle")
            }
            source.apply(.keepHot(kind == "Manually loaded" ? .manual : .onDemand, minutes: choice.minutes))
        }
        return settings()
    }
}
