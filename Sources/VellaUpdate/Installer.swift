import AppKit
import Darwin
import Foundation
import VellaCore

/// The app's hand-off to `VellaInstallTool update --plan PLAN`: the app has to quit for the swap, so a separate
/// process waits for it to exit, installs the staged app, relaunches it and checks that it becomes ready.
public struct InstallPlan: Codable, Equatable, Sendable {
    public var staged: StagedUpdate
    /// The installed Vella.app to replace (the running app's bundle).
    public var destination: String
    /// The version being replaced (for messages).
    public var from: String
    /// The app that handed off; the install starts once it has exited.
    public var waitForPID: Int32?
    /// Application Support/Vella (VELLA_SUPPORT_DIR): worker-status.json, dictation-status.json, update-result.json.
    public var supportDirectory: String

    public init(staged: StagedUpdate, destination: String, from: String, waitForPID: Int32? = nil, supportDirectory: String) {
        self.staged = staged; self.destination = destination; self.from = from
        self.waitForPID = waitForPID; self.supportDirectory = supportDirectory
    }
}

/// A failed update, for the relaunched app to report (it reads and deletes update-result.json at launch). Written
/// before the app is relaunched; a successful update leaves none.
public struct UpdateResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var from: String
    public var to: String
    public var message: String
    public var at: Double
    public init(ok: Bool, from: String, to: String, message: String, at: Double = Date().timeIntervalSince1970) {
        self.ok = ok; self.from = from; self.to = to; self.message = message; self.at = at
    }
    public static func url(support: URL) -> URL { support.appendingPathComponent("update-result.json") }
    /// Reads and removes the result, if there is one.
    public static func take(support: URL) -> UpdateResult? {
        let url = url(support: support)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(UpdateResult.self, from: data)
    }
}

/// Installs a staged update the way scripts/install-prepared.sh does, with an automatic rollback:
/// 1. wait for the app that handed off to quit;
/// 2. NativeInstaller: refuse while a dictation or model load is under way, check the bundle and that it is signed
///    like the installed app, swap with the previous app kept aside, launch;
/// 3. wait until the new version is ready (InstallReadiness: it answers with its own pid, nothing loading, the launch
///    set loaded). Ready, or running with a launch-set model refused for memory: the previous app is deleted.
///    Otherwise (no answer, it exited, still loading after 30 minutes, a launch-set model keeps failing): the new app
///    is stopped, the previous one is moved back and relaunched, and update-result.json says why.
/// Settings, models and recordings in Application Support are never touched.
public final class UpdateInstaller {
    public let plan: InstallPlan
    public var log: (String) -> Void
    /// How long the relaunched app has to answer (VELLA_UPDATE_READY_SECONDS, default 120).
    public var startTimeout: TimeInterval
    /// How long launch-set models may take to load after that (as the installers: 30 minutes).
    public var loadTimeout: TimeInterval = 30 * 60
    /// A launch-set model failing this long counts as a failed update (the app retries a crashed worker 3 times in ~12 s).
    public var settle: TimeInterval = 60
    public var pollInterval: TimeInterval = 0.5
    /// How long the handing-off app has to exit.
    public var quitTimeout: TimeInterval = 120

    // Seams for tests; production uses the defaults.
    public var configure: (NativeInstaller) -> Void = { _ in }
    public var isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    public var isInstalledApp: (Int32, URL) -> Bool = { InstallReadiness.runs($0, app: $1) }
    public var readStatus: (URL) -> Data? = { try? Data(contentsOf: $0) }
    public lazy var launch: (URL) -> Void = { [support = self.support, log = self.log] app in
        do { try NativeInstaller.launchApplication(app, support: support) } catch { log("launch failed: \(error.localizedDescription)") }
    }
    public var terminate: (URL) -> Void = UpdateInstaller.terminateApp
    public var now: () -> Date = Date.init
    public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    public init(plan: InstallPlan, log: @escaping (String) -> Void = { _ in }, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.plan = plan; self.log = log
        startTimeout = env["VELLA_UPDATE_READY_SECONDS"].flatMap(TimeInterval.init) ?? 120
    }

    var destination: URL { URL(fileURLWithPath: plan.destination, isDirectory: true) }
    var support: URL { URL(fileURLWithPath: plan.supportDirectory, isDirectory: true) }
    var fm: FileManager { .default }

    /// Installs, relaunches and checks readiness; rolls back on failure and throws the reason. On any failure the
    /// previous version is installed and running again, and update-result.json explains what happened.
    public func run() throws {
        try? fm.removeItem(at: UpdateResult.url(support: support))
        defer { try? fm.removeItem(atPath: plan.staged.directory) }
        if let pid = plan.waitForPID, !wait(timeout: quitTimeout, until: { !isAlive(pid) }) {
            // The app is still running: nothing was touched, nothing to relaunch.
            throw UpdateError("Vella did not quit; installation left unchanged")
        }
        let installer = NativeInstaller(preparedApp: URL(fileURLWithPath: plan.staged.app), destination: destination, support: support)
        installer.keepPrevious = true
        let launch = self.launch
        installer.launch = { launch($0) }
        configure(installer)
        let previous: URL?
        do {
            previous = try installer.install()
        } catch {
            // Refused or rolled back before the swap committed: the previous app is in place, not running (it quit to
            // hand off). Relaunch it and say why.
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            fail(message)
            if fm.fileExists(atPath: destination.path) { launch(destination) }
            throw UpdateError(message)
        }
        log("installed \(plan.destination) (\(plan.staged.version)); starting…")
        switch awaitReady() {
        case .ready(let line):
            log("ready: \(line)")
            if let previous { try? fm.removeItem(at: previous) }
        case .degraded(let line):
            // Running; a launch-set model was refused for memory, which the previous version could not fix either.
            log("running, degraded: \(line)")
            if let previous { try? fm.removeItem(at: previous) }
        case .failed(let reason):
            try rollBack(previous: previous, reason: reason)
        }
    }

    public enum Outcome: Equatable { case ready(String), degraded(String), failed(String) }

    /// Polls worker-status.json until the new app is ready, degraded or has failed (see the type's comment).
    public func awaitReady() -> Outcome {
        let statusFile = support.appendingPathComponent(InstallReadiness.statusFileName)
        let destination = self.destination
        let start = now()
        var answeredAt: Date?
        var failingSince: Date?
        while true {
            let data = readStatus(statusFile)
            let answering = Self.appPID(data).map { isInstalledApp($0, destination) } ?? false
            if !answering {
                if answeredAt != nil { return .failed("the new version exited") }
                if now().timeIntervalSince(start) > startTimeout { return .failed("no answer after \(Int(startTimeout)) s") }
            } else {
                let answered = answeredAt ?? now(); answeredAt = answered
                switch InstallReadiness.evaluate(status: data, isInstalledApp: { self.isInstalledApp($0, destination) }) {
                case .ready(let line): return .ready(line)
                case .degraded(let line): return .degraded(line)
                case .failing(let reason):
                    let since = failingSince ?? now(); failingSince = since
                    if now().timeIntervalSince(since) >= settle { return .failed(reason) }
                case .waiting(let reason):
                    failingSince = nil
                    if now().timeIntervalSince(answered) > loadTimeout { return .failed("still \(reason) after \(Int(loadTimeout / 60)) min") }
                }
            }
            sleep(pollInterval)
        }
    }

    static func appPID(_ data: Data?) -> Int32? {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (object["app_pid"] as? NSNumber)?.int32Value
    }

    private func rollBack(previous: URL?, reason: String) throws {
        let failure = "Vella \(plan.staged.version) did not start (\(reason))"
        log("\(failure); restoring \(plan.from)")
        terminate(destination)
        guard let previous, fm.fileExists(atPath: previous.path) else {
            fail(failure + "; there was no previous app to restore")
            throw UpdateError(failure)
        }
        let failed = destination.deletingLastPathComponent().appendingPathComponent(".Vella.app.failed.\(getpid()).\(UUID().uuidString.prefix(8))")
        do {
            try fm.moveItem(at: destination, to: failed)
            do { try fm.moveItem(at: previous, to: destination) }
            catch { try? fm.moveItem(at: failed, to: destination); throw error }
        } catch {
            let message = failure + " and restoring \(plan.from) failed; the previous app is at \(previous.path)"
            fail(message)
            launch(destination)
            throw UpdateError(message)
        }
        try? fm.removeItem(at: failed)
        let message = failure + "; Vella \(plan.from) was restored"
        fail(message)                   // written first: the restored app reports it at launch
        launch(destination)
        throw UpdateError(message)
    }

    private func fail(_ message: String) {
        log("failed: \(message)")
        let result = UpdateResult(ok: false, from: plan.from, to: plan.staged.version, message: message)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: UpdateResult.url(support: support), options: .atomic) }
    }

    private func wait(timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            if done() { return true }
            sleep(min(pollInterval, 0.2))
        }
        return done()
    }

    /// Quits the app running from `app` (matched by its bundle file, never by name): terminate, then force after 15 s.
    /// Its workers exit when their stdin closes.
    public static func terminateApp(_ app: URL) {
        let target = app.standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == target }
        running.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        running.filter { !$0.isTerminated }.forEach { _ = $0.forceTerminate() }
        let forced = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }) && Date() < forced { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    }

    /// Appends a stamped line to Application Support/Vella/update.log (reset past 1 MB). Never speech or transcripts.
    public static func appendLog(_ line: String, support: URL) {
        let url = support.appendingPathComponent("update.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }
}
