import Foundation

/// Channel 1 of the Heimdall integration (docs/HEIMDALL.md): Vella announces whether it is recording, and its
/// keybind, as macOS distributed notifications. Posting with no observer costs nothing; nothing here asks for a
/// permission or opens a connection.
public enum HeimdallNames {
    public static let dictationState = "dev.vella.dictation.state"
    public static let dictationObject = "dev.vella.dictation"
    public static let vellaQuery = "dev.heimdall.vella.query"
    public static let asr = "dev.heimdall.asr"
    public static let asrQuery = "dev.vella.asr.query"
    public static let heimdallObject = "dev.heimdall"
    public static let protocolVersion = 1
    /// The model both apps must run for Vella to borrow Heimdall's copy.
    public static let sharedModel = "parakeet-v3-ultra"
}

/// Why a state notification was posted.
public enum DictationSignalReason: String, Sendable {
    case start, stop, heartbeat, hello, quit
}

/// The dictation controller's phase, as the signal sees it. `preparing` is split: only a press (or menu click, CLI or
/// API start) that begins a recording counts as on; preparing to fetch a model or to recover a saved recording does not.
public enum DictationSignalPhase: Sendable, Equatable {
    case idle, preparingCapture, preparingOther, recording, transcribing, success, failed
    /// On from the moment a press starts preparing until recording stops.
    public var capturing: Bool { self == .preparingCapture || self == .recording }
}

/// Derives start/stop from phase transitions. Pure: the caller supplies new session ids.
public struct DictationSignalTracker: Sendable {
    public private(set) var on = false
    /// The current or last recording session; empty before the first one.
    public private(set) var session = ""
    public init() {}
    /// The reason to post for this transition, or nil when the on/off state did not change.
    public mutating func observe(_ phase: DictationSignalPhase, newSession: () -> String = { UUID().uuidString }) -> DictationSignalReason? {
        switch (on, phase.capturing) {
        case (false, true): on = true; session = newSession(); return .start
        case (true, false): on = false; return .stop
        default: return nil
        }
    }
}

/// One `dev.vella.dictation.state` userInfo (property-list types only).
public struct DictationSignalPayload: Equatable, Sendable {
    public var on: Bool
    public var reason: DictationSignalReason
    public var session: String
    public var pid: Int
    public var sent: Double
    public var mode: String
    public var shortcut: String
    public var shortcutLabel: String
    public init(on: Bool, reason: DictationSignalReason, session: String, pid: Int, sent: Double, mode: String, shortcut: String, shortcutLabel: String) {
        self.on = on; self.reason = reason; self.session = session; self.pid = pid; self.sent = sent
        self.mode = mode; self.shortcut = shortcut; self.shortcutLabel = shortcutLabel
    }
    public var userInfo: [String: Any] {
        [
            "v": HeimdallNames.protocolVersion, "state": on ? "on" : "off", "reason": reason.rawValue, "session": session,
            "pid": pid, "sent": sent, "mode": mode, "shortcut": shortcut, "shortcutLabel": shortcutLabel
        ]
    }
}

/// The active binding as `shortcuts.json` stores it, and its display form (`⌃⌘N · Toggle`).
public func shortcutSignalFields(_ config: ShortcutConfiguration) -> (json: String, label: String) {
    let data = (try? JSONEncoder().encode(config)) ?? Data()
    return (String(decoding: data, as: UTF8.self), ShortcutLabels.display(config))
}

/// Posts Channel 1. Owns the on/off state, the 15 s heartbeat while on, hello on launch, on a keybind change and in reply
/// to Heimdall's query, and quit. The transport, clock and timer are injected (tests use fakes).
@MainActor public final class DictationAnnouncer {
    public static let heartbeatSeconds: TimeInterval = 15
    public typealias Post = (_ userInfo: [String: Any]) -> Void
    /// Starts a repeating timer; returns its cancel.
    public typealias StartTimer = (_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void
    private let post: Post
    private let now: () -> Double
    private let startTimer: StartTimer
    private let pid: Int
    /// "dictation" or "streaming" at the moment of posting.
    public var mode: () -> String = { "dictation" }
    /// The working binding (`shortcuts.json` form, display label).
    public var shortcut: () -> (json: String, label: String) = { shortcutSignalFields(.default) }
    private var tracker = DictationSignalTracker()
    private var cancelHeartbeat: (() -> Void)?
    private var announcedShortcut: String?
    public private(set) var quitPosted = false
    public var on: Bool { tracker.on }

    public init(
        pid: Int = Int(ProcessInfo.processInfo.processIdentifier), now: @escaping () -> Double = { Date().timeIntervalSince1970 },
        startTimer: StartTimer? = nil, post: @escaping Post
    ) {
        self.pid = pid; self.now = now; self.post = post
        self.startTimer = startTimer ?? DictationAnnouncer.runLoopTimer
    }
    /// A `.common`-mode run-loop timer (keeps firing while a menu tracks).
    public static let runLoopTimer: StartTimer = { interval, fire in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// The dictation controller changed phase.
    public func phaseChanged(_ phase: DictationSignalPhase) {
        guard !quitPosted, let reason = tracker.observe(phase) else { return }
        send(reason)
        if tracker.on {
            cancelHeartbeat?()
            cancelHeartbeat = startTimer(Self.heartbeatSeconds) { [weak self] in self?.heartbeat() }
        } else {
            cancelHeartbeat?(); cancelHeartbeat = nil
        }
    }
    /// A heartbeat timer tick; posts only while on.
    public func heartbeat() {
        guard tracker.on, !quitPosted else { return }
        send(.heartbeat)
    }
    /// Launch, or a reply to `dev.heimdall.vella.query`.
    public func hello() {
        guard !quitPosted else { return }
        send(.hello)
    }
    /// The binding may have changed (apply, reload, fallback); a hello goes out only when its JSON differs.
    public func shortcutMayHaveChanged() {
        guard !quitPosted, announcedShortcut != nil, shortcut().json != announcedShortcut else { return }
        send(.hello)
    }
    /// From `applicationWillTerminate`: state off, once.
    public func quit() {
        guard !quitPosted else { return }
        cancelHeartbeat?(); cancelHeartbeat = nil
        send(.quit, forceOff: true)
        quitPosted = true
    }
    private func send(_ reason: DictationSignalReason, forceOff: Bool = false) {
        let binding = shortcut()
        announcedShortcut = binding.json
        let payload = DictationSignalPayload(
            on: tracker.on && !forceOff, reason: reason, session: tracker.session, pid: pid, sent: now(), mode: mode(),
            shortcut: binding.json, shortcutLabel: binding.label)
        post(payload.userInfo)
    }
}
