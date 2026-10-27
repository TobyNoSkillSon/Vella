import AppKit
import Foundation
import VellaCore

/// The notification transport (distributed notifications in the app, an in-memory bus in tests).
@MainActor protocol HeimdallBus: AnyObject {
    func post(_ name: String, object: String, userInfo: [String: Any]?)
    func observe(_ name: String, object: String?, _ handler: @escaping @MainActor ([AnyHashable: Any]?) -> Void)
}

/// `DistributedNotificationCenter`, posting with `deliverImmediately` and observing with `.deliverImmediately`: a menu-bar
/// app is almost never active, and the default suspension would hold Heimdall's notifications until it is.
@MainActor final class DistributedHeimdallBus: NSObject, HeimdallBus {
    private let center = DistributedNotificationCenter.default()
    private var handlers: [String: @MainActor ([AnyHashable: Any]?) -> Void] = [:]
    func post(_ name: String, object: String, userInfo: [String: Any]?) {
        center.postNotificationName(.init(name), object: object, userInfo: userInfo, deliverImmediately: true)
    }
    func observe(_ name: String, object: String?, _ handler: @escaping @MainActor ([AnyHashable: Any]?) -> Void) {
        handlers[name] = handler
        center.addObserver(self, selector: #selector(received(_:)), name: .init(name), object: object, suspensionBehavior: .deliverImmediately)
    }
    @objc nonisolated private func received(_ note: Notification) {
        let name = note.name.rawValue
        // Property-list values only; copied before hopping to the main actor.
        nonisolated(unsafe) let info = note.userInfo
        let deliver = { @MainActor [weak self] in self?.handlers[name]?(info) }
        if Thread.isMainThread { MainActor.assumeIsolated { deliver() } } else { DispatchQueue.main.async { deliver() } }
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
}

/// Vella's side of both Heimdall channels (docs/HEIMDALL.md). Harmless without Heimdall: posting with no observer costs
/// nothing, no connection is made until Heimdall has announced a socket, and nothing asks for a permission.
@MainActor final class HeimdallLink {
    let bus: HeimdallBus
    /// Channel 1; nil when this instance does not announce dictation (QA headless and lab runs).
    let announcer: DictationAnnouncer?
    private(set) var borrow = HeimdallBorrowState()
    /// The catalog family a configuration dictates with (an empty selection: the model the first dictation offers).
    var familyOf: (Configuration) -> String? = { _ in nil }
    /// The current configuration (config.json).
    var currentConfiguration: () -> Configuration? = { nil }
    /// The display name for a family ("Parakeet v3 Ultra").
    var familyName: (String) -> String? = { _ in nil }
    /// Called when the family Vella borrows changes (nil: none): the runtime unloads Vella's copy, or restores residency.
    var onBorrowChange: ((_ now: String?, _ before: String?) -> Void)?
    /// Status for worker-status.json and /status.
    var onStatus: ((HeimdallStatus) -> Void)?
    var onLastDictation: ((LastDictationStatus) -> Void)?
    /// Lab runs: force a path (`own` never asks Heimdall; `heimdall` asks it and never falls back).
    enum Route: String { case own, heimdall }
    var labRoute: Route?
    /// The connection's peer must be the announcing process when the announcement names one.
    var exchange: (_ socket: String, _ samples: [Float], _ peer: Int32?) async throws -> HeimdallTranscript = { socket, samples, peer in
        try await HeimdallASRClient.transcribe(socket: socket, samples: samples, peer: peer)
    }
    /// Which announced `ready` sockets Vella will send audio to: only the spec's path, a socket owned by this user and
    /// closed to others (any local process can post the notification).
    var acceptSocket: (String) -> Bool = { heimdallSocketAcceptable($0, expected: HeimdallLink.defaultSocket) }
    /// After a failure, ask Heimdall again this much later (a transient `busy` should not keep Vella's own copy loaded
    /// until Heimdall restarts); longer after a timeout, which costs the next dictation the whole deadline.
    var requeryDelay: (_ failure: String) -> TimeInterval = { $0 == "timeout" ? 600 : 60 }
    private var requery: DispatchWorkItem?
    private(set) var borrowingFamily: String?

    init(bus: HeimdallBus, announcesDictation: Bool, announcer: DictationAnnouncer? = nil) {
        self.bus = bus
        if let announcer {
            self.announcer = announcer
        } else if announcesDictation {
            self.announcer = DictationAnnouncer(post: { [weak bus] info in
                bus?.post(HeimdallNames.dictationState, object: HeimdallNames.dictationObject, userInfo: info)
            })
        } else {
            self.announcer = nil
        }
    }

    /// Observe Heimdall, ask whether its model is ready, and say hello.
    func start() {
        bus.observe(HeimdallNames.asr, object: HeimdallNames.heimdallObject) { [weak self] info in
            guard let self, let announcement = HeimdallAnnouncement(userInfo: info) else { return }
            if announcement.state == .ready, !self.acceptSocket(announcement.socket) { return }
            self.receive(announcement)
        }
        if let announcer {
            bus.observe(HeimdallNames.vellaQuery, object: HeimdallNames.heimdallObject) { [weak announcer] _ in announcer?.hello() }
            announcer.hello()
        }
        bus.post(HeimdallNames.asrQuery, object: HeimdallNames.dictationObject, userInfo: nil)
        publish()
    }
    func receive(_ announcement: HeimdallAnnouncement) {
        if announcement.state == .ready { requery?.cancel(); requery = nil }
        borrow.receive(announcement)
        reevaluate()
    }
    /// Heimdall's state changed (`residency`: tell the runtime, which unloads Vella's copy or restores its launch set),
    /// or the selection did (state only: a model the user just chose and loaded is theirs until Heimdall next announces).
    func reevaluate(residency: Bool = true) {
        let before = borrowingFamily
        let family = currentConfiguration().flatMap { familyOf($0) }
        borrowingFamily = borrow.socket(for: family) != nil ? family : nil
        if residency, borrowingFamily != before { onBorrowChange?(borrowingFamily, before) }
        publish()
    }
    private func publish() {
        let ready = borrow.ready
        onStatus?(
            HeimdallStatus(
                state: borrow.label, socket: ready?.socket, model: ready?.model, pid: ready?.pid, borrowing: borrowingFamily != nil,
                last_failure: borrow.lastFailure))
    }

    /// The socket a dictation recorded with `config` goes to, or nil for Vella's own model.
    func socket(for config: Configuration) -> String? {
        if labRoute == .own { return nil }
        guard config.mode == .dictation else { return nil }
        if labRoute == .heimdall { return borrow.ready?.socket }
        return borrow.socket(for: familyOf(config))
    }
    /// "Parakeet v3 Ultra via Heimdall" while dictation borrows Heimdall's model, for the menu header.
    var borrowLabel: String? {
        guard let family = borrowingFamily, let name = familyName(family) else { return nil }
        return "\(name) via Heimdall"
    }

    /// One recognition request (a segment's WAV) over Heimdall's socket. A failure marks Heimdall unavailable until its
    /// next `ready` and rethrows; the caller falls back to Vella's own model. Cancellation is not a failure.
    func transcribe(wav: URL, socket: String) async throws -> String {
        let asked = borrow.ready
        do {
            let samples = try heimdallWAVSamples(Data(contentsOf: wav))
            let reply = try await exchange(socket, samples, asked?.socket == socket ? asked?.pid.map { Int32($0) } : nil)
            return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as HeimdallASRError where error == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let code = (error as? HeimdallASRError)?.code ?? "error"
            let before = borrow
            borrow.failed(code, for: labRoute == .heimdall ? borrow.ready : asked)
            reevaluate()
            if borrow.unavailable, !before.unavailable { scheduleRequery(after: requeryDelay(code)) }
            throw error
        }
    }
    func recordDictation(_ status: LastDictationStatus) { onLastDictation?(status) }
    private func scheduleRequery(after delay: TimeInterval) {
        requery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.borrow.unavailable else { return }
                self.bus.post(HeimdallNames.asrQuery, object: HeimdallNames.dictationObject, userInfo: nil)
            }
        }
        requery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Heimdall's socket by the spec's default path.
    nonisolated static let defaultSocket = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Heimdall/asr.sock").path
    private var settled = false
    /// Once, before the first launch-set load: when Heimdall's socket exists but no `ready` arrived yet, wait up to
    /// 1.5 s for its answer to `dev.vella.asr.query`. Without a socket file this returns at once.
    func settle(socketPath: String = HeimdallLink.defaultSocket, wait: Double = 1.5) async {
        guard !settled else { return }
        settled = true
        guard borrow.ready == nil, FileManager.default.fileExists(atPath: socketPath) else { return }
        let until = ProcessInfo.processInfo.systemUptime + wait
        while borrow.ready == nil, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
}
