import Foundation
import Darwin

/// The installer's readiness rule, read from the app's `worker-status.json`:
/// the running app wrote it (its pid is alive and is the installed app), nothing is
/// loading, and nothing configured hot (the launch set) is missing. A fresh install has an
/// empty launch set, so it is ready with nothing loaded. A launch-set model the app refused
/// for memory is settled but `.degraded`, never ready; one that failed with an error is
/// `.failing` (the app may still restart it) and becomes degraded once it stays that way.
/// Only `.ready` lets the installer discard the previous app.
public enum InstallReadiness {
    public static let statusFileName = "worker-status.json"

    public enum State: Equatable {
        case ready(String)
        case waiting(String)
        case failing(String)
        /// Running, but a configured-hot model is not loaded (refused, or failing past the settle time).
        case degraded(String)
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
                if rest.isEmpty { return .degraded("Vella running (pid \(pid)), \(model) not loaded: \(refusal.message ?? "refused")") }
            }
            if let error = status.error { return .failing("\(names) not loaded: \(error)") }
            return .waiting("waiting for \(names) to load")
        }
        if models.isEmpty { return .ready("Vella running (pid \(pid)), no model loaded") }
        let names = models.keys.sorted().map { id in models[id]?.precision.map { "\(id) (\($0))" } ?? id }
        return .ready("Vella running (pid \(pid)), \(names.count == 1 ? "model" : "models") loaded: \(names.joined(separator: ", "))")
    }

    /// Exit statuses of `VellaInstallTool ready`.
    public static let readyExit: Int32 = 0, notReadyExit: Int32 = 1, degradedExit: Int32 = 3

    /// The `ready` command's loop: poll the status until ready (exit 0, `ready: …`), degraded (exit 3, `degraded: …`;
    /// a failing launch-set model counts once it has failed for `settle` seconds, since the app retries a crashed
    /// worker 3 times within ~12 s) or the timeout (exit 1). Clock and sleep are injectable for tests.
    public static func wait(read: () -> Data?, isInstalledApp: (Int32) -> Bool, timeout: Double, interval: Double, settle: Double,
                            now: () -> Date = Date.init, sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> (status: Int32, line: String) {
        let deadline = now().addingTimeInterval(timeout)
        var state = State.waiting("not checked")
        var failingSince: Date?
        repeat {
            state = evaluate(status: read(), isInstalledApp: isInstalledApp)
            switch state {
            case .ready(let line): return (readyExit, "ready: \(line)")
            case .degraded(let line): return (degradedExit, "degraded: \(line)")
            case .failing(let reason):
                let since = failingSince ?? now(); failingSince = since
                if now().timeIntervalSince(since) >= settle { return (degradedExit, "degraded: Vella running, \(reason)") }
            case .waiting: failingSince = nil
            }
            sleep(interval)
        } while now() < deadline
        if case .failing(let reason) = state { return (notReadyExit, "not ready after \(Int(timeout)) s: \(reason)") }
        if case .waiting(let reason) = state { return (notReadyExit, "not ready after \(Int(timeout)) s: \(reason)") }
        return (notReadyExit, "not ready after \(Int(timeout)) s")
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
