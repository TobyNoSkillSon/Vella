import Foundation
import Darwin

/// The installer's readiness rule, read from the app's `worker-status.json`:
/// the running app wrote it (its pid is alive and is the installed app), nothing is
/// loading, and every model in the launch set is loaded. A fresh install has an empty
/// launch set, so it is ready with nothing loaded. A launch-set model the app refused for
/// memory counts as settled (ready, with the refusal); one that failed with an error is
/// `.failing` so the caller can wait briefly for a restart before accepting it.
public enum InstallReadiness {
    public static let statusFileName = "worker-status.json"

    public enum State: Equatable {
        case ready(String)
        case waiting(String)
        case failing(String)
        public var isReady: Bool { if case .ready = self { return true }; return false }
    }

    struct Status: Decodable {
        struct Model: Decodable { let precision: String? }
        struct Refusal: Decodable { let model: String?; let message: String? }
        let app_pid: Int32?
        let loading: String?
        let error: String?
        let models: [String: Model]?
        let launch_set: [String]?
        let refused: Refusal?
    }

    /// `isInstalledApp(pid)`: the pid is alive and runs the installed app's executable.
    public static func evaluate(status data: Data?, isInstalledApp: (Int32) -> Bool) -> State {
        guard let data else { return .waiting("Vella has not written its status yet") }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return .waiting("status file is incomplete") }
        guard let pid = status.app_pid, isInstalledApp(pid) else { return .waiting("status is from an earlier launch") }
        if let loading = status.loading { return .waiting("loading \(loading)") }
        let models = status.models ?? [:]
        let missing = (status.launch_set ?? []).filter { models[$0] == nil }
        if !missing.isEmpty {
            let names = missing.joined(separator: ", ")
            if let refusal = status.refused, let model = refusal.model, missing.contains(model) {
                let rest = missing.filter { $0 != model }
                if rest.isEmpty { return .ready("Vella running (pid \(pid)), \(model) not loaded: \(refusal.message ?? "refused")") }
            }
            if let error = status.error { return .failing("\(names) not loaded: \(error)") }
            return .waiting("waiting for \(names) to load")
        }
        if models.isEmpty { return .ready("Vella running (pid \(pid)), no model loaded") }
        let names = models.keys.sorted().map { id in models[id]?.precision.map { "\(id) (\($0))" } ?? id }
        return .ready("Vella running (pid \(pid)), \(names.count == 1 ? "model" : "models") loaded: \(names.joined(separator: ", "))")
    }

    /// The model a running Vella is loading right now, if its status says so.
    public static func loadingModel(statusFile: URL, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> String? {
        guard let data = try? Data(contentsOf: statusFile),
              let status = try? JSONDecoder().decode(Status.self, from: data),
              let pid = status.app_pid, isAlive(pid) else { return nil }
        return status.loading
    }

    /// True when `pid` is alive and its executable is `app`'s main executable (same file).
    public static func runs(_ pid: Int32, app: URL) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              let running = FileIdentity(URL(fileURLWithPath: String(cString: buffer))),
              let expected = FileIdentity(app.appendingPathComponent("Contents/MacOS/Vella")) else { return false }
        return running == expected
    }
}
