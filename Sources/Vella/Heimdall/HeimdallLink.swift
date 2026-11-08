import AppKit
import Foundation
import Security
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

/// Drops everything: renders, and every app instance under XCTest (tests never speak to a real Heimdall).
@MainActor final class SilentHeimdallBus: HeimdallBus {
    func post(_ name: String, object: String, userInfo: [String: Any]?) {}
    func observe(_ name: String, object: String?, _ handler: @escaping @MainActor ([AnyHashable: Any]?) -> Void) {}
}

/// Vella's side of both Heimdall channels (docs/HEIMDALL.md). Harmless without Heimdall: posting with no observer costs
/// nothing, no connection is made until Heimdall has announced a socket, and nothing asks for a permission.
@MainActor final class HeimdallLink {
    let bus: HeimdallBus
    /// Channel 1; nil when this instance does not announce dictation (QA headless and lab runs).
    let announcer: DictationAnnouncer?
    private(set) var borrow = HeimdallBorrowState()
    /// Whether a Heimdall app is on this Mac (LaunchServices; tests inject).
    var findInstalled: () -> Bool = {
        HeimdallApp.bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
    /// Cached; refreshed at start, on every announcement and when the Models table opens (`refreshInstalled`).
    private(set) var installed = false
    /// Heimdall answered during this session (a development build outside Applications): offline, not absent, once it
    /// stops, so an explicit choice of it stays visible.
    private var answered = false
    /// Vella's own downloaded Parakeet v3 Ultra, if any: the offline fallback while Heimdall's row is the choice.
    var ownSharedModelPath: () -> String? = { nil }
    /// Called when the row's presence or the choice changes (the Models table and the menu redraw).
    var onPresenceChange: (() -> Void)?
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
    /// Which announced `ready`s Vella will send audio to (any local process can post the notification): the announcing
    /// edition's own fixed socket path, a socket owned by this user and closed to others, from a process signed as that
    /// edition. So the personal build and the public alpha can never be taken for each other.
    var acceptAnnouncement: (HeimdallAnnouncement) -> Bool = { HeimdallLink.trusted($0) }
    nonisolated static func trusted(
        _ a: HeimdallAnnouncement, home: String = NSHomeDirectory(),
        identity: (Int) -> String? = HeimdallLink.signingIdentifier
    ) -> Bool {
        guard let app = a.app, let expected = HeimdallApp.socketPath(app: app, home: home), a.socket == expected,
            heimdallSocketAcceptable(a.socket, expected: expected), let pid = a.pid
        else { return false }
        return identity(pid) == app
    }
    /// The code-signing identifier of a running process (Heimdall's bundle signs its executable with its app ID).
    nonisolated static func signingIdentifier(pid: Int) -> String? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
            let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoIdentifier as String] as? String
    }
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
        installed = findInstalled()
        bus.observe(HeimdallNames.asr, object: HeimdallNames.heimdallObject) { [weak self] info in
            guard let self, let announcement = HeimdallAnnouncement(userInfo: info) else { return }
            if announcement.state == .ready, !self.acceptAnnouncement(announcement) { return }
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
        if announcement.state == .ready { answered = true }
        installed = findInstalled()
        reevaluate()
    }
    func refreshInstalled() {
        let now = findInstalled()
        guard now != installed else { return }
        installed = now
        reevaluate(residency: false)
    }
    /// Heimdall's app is on this Mac, or its model answered (a development build outside Applications).
    var detected: Bool { installed || answered }
    /// Whether the announcing process still runs (a crash posts no `gone`).
    var processAlive: (Int) -> Bool = { pid in kill(pid_t(pid), 0) == 0 || errno == EPERM }
    var presence: HeimdallPresence {
        let answering = borrow.ready.map { $0.pid.map(processAlive) ?? true } ?? false
        return .of(installed: installed || answered, ready: answering, unavailable: borrow.unavailable)
    }
    /// The choice in effect for `config`.
    func source(for config: Configuration) -> DictationSource { effectiveDictationSource(config, heimdallDetected: detected) }
    /// The "from Heimdall" row is the dictation choice now.
    var heimdallChosen: Bool { currentConfiguration().map { source(for: $0) == .heimdall } ?? false }
    /// Heimdall's state changed (`residency`: tell the runtime, which unloads Vella's copy or restores its launch set),
    /// or the selection did (state only: a model the user just chose and loaded is theirs until Heimdall next announces).
    func reevaluate(residency: Bool = true) {
        let before = borrowingFamily
        borrowingFamily = heimdallChosen && borrow.socket(for: HeimdallNames.sharedModel) != nil ? HeimdallNames.sharedModel : nil
        if residency, borrowingFamily != before { onBorrowChange?(borrowingFamily, before) }
        publish()
        onPresenceChange?()
    }
    private func publish() {
        let ready = borrow.ready
        onStatus?(
            HeimdallStatus(
                state: borrow.label, socket: ready?.socket, model: ready?.model, pid: ready?.pid, borrowing: borrowingFamily != nil,
                last_failure: borrow.lastFailure, app: ready?.app))
    }

    /// The socket a dictation recorded with `config` goes to, or nil for Vella's own model.
    func socket(for config: Configuration) -> String? {
        if labRoute == .own { return nil }
        guard config.mode == .dictation else { return nil }
        if labRoute == .heimdall { return borrow.ready?.socket }
        guard source(for: config) == .heimdall else { return nil }
        return borrow.socket(for: HeimdallNames.sharedModel)
    }
    /// What a recording made now carries: with Heimdall's row chosen, that choice (so a later change cannot reroute
    /// it) and, as the offline fallback, Vella's own Parakeet v3 Ultra only if it is downloaded; otherwise no model, so
    /// an offline Heimdall leads to the usual Get offer, never a silent download or another model.
    func recordingConfiguration(_ config: Configuration) -> Configuration {
        guard config.mode == .dictation, source(for: config) == .heimdall else { return config }
        var pinned = config
        pinned.dictationSource = .heimdall
        pinned.model = ownSharedModelPath() ?? ""
        return pinned
    }
    /// The menu header while Heimdall's row is the choice: "Parakeet v3 Ultra via Heimdall", or "… · Heimdall offline".
    var borrowLabel: String? {
        guard heimdallChosen, let name = familyName(HeimdallNames.sharedModel) else { return nil }
        let heimdall = HeimdallApp.name(app: borrow.ready?.app)
        return presence == .present ? "\(name) via \(heimdall)" : "\(name) · \(heimdall) offline"
    }

    /// One recognition request (a segment's WAV) over Heimdall's socket. A failure marks Heimdall unavailable until its
    /// next `ready` and rethrows; the caller falls back to Vella's own model. Cancellation is not a failure.
    /// `marksFailure` false (API files): a failure is only rethrown, so dictation keeps borrowing.
    func transcribe(wav: URL, socket: String, marksFailure: Bool = true) async throws -> String {
        try await transcribe(samples: heimdallWAVSamples(Data(contentsOf: wav)), socket: socket, marksFailure: marksFailure)
    }
    /// One request with these 16 kHz mono samples (the whole dictation, straight from the saved Float32 audio).
    /// The latest request's timings, for lab runs: the socket round trip and what Heimdall reported.
    private(set) var lastExchange: (ms: Double, queueMs: Double?, decodeMs: Double?, start: Double, end: Double)?
    func transcribe(samples: [Float], socket: String, marksFailure: Bool = true) async throws -> String {
        let asked = borrow.ready
        do {
            // Just before connecting: still a socket owned by this user, closed to others, not a link (lab runs name
            // their own socket).
            if labRoute == nil, !heimdallSocketAcceptable(socket, expected: socket) { throw HeimdallASRError.connect("socket") }
            let start = ProcessInfo.processInfo.systemUptime
            let reply = try await exchange(socket, samples, asked?.socket == socket ? asked?.pid.map { Int32($0) } : nil)
            let end = ProcessInfo.processInfo.systemUptime
            lastExchange = ((end - start) * 1000, reply.queueMs, reply.decodeMs, start, end)
            return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as HeimdallASRError where error == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard marksFailure else { throw error }
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
    /// Each edition's socket path (personal first).
    nonisolated static let editionSockets = HeimdallApp.bundleIdentifiers.compactMap { HeimdallApp.socketPath(app: $0, home: NSHomeDirectory()) }
    private var settled = false
    /// Once, before the first launch-set load: when Heimdall's socket exists but no `ready` arrived yet, wait up to
    /// 1.5 s for its answer to `dev.vella.asr.query`. Without a socket file this returns at once.
    func settle(socketPaths: [String] = HeimdallLink.editionSockets, wait: Double = 1.5) async {
        guard !settled else { return }
        settled = true
        guard borrow.ready == nil, socketPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let until = ProcessInfo.processInfo.systemUptime + wait
        while borrow.ready == nil, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
}
