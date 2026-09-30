import Foundation

// MARK: - Activation state machine

/// Testable solo-modifier arbitration.
/// The tap observes flagsChanged AND nonmodifier keyDown: a target-modifier down
/// becomes pending only; any other keyDown or non-target modifier cancels it.
/// A hold timeout while still sole-held yields press (Hold); a quick solo
/// release yields tap (Toggle/TapOrHold-short). Covers both left/right sides.
public enum SoloInputEvent: Equatable {
    case targetDown(key: ModifierKey, side: ModifierSide, time: TimeInterval, sole: Bool)
    case targetUp(key: ModifierKey, side: ModifierSide, time: TimeInterval)
    case otherKeyDown(time: TimeInterval)
    case otherModifierDown(time: TimeInterval)
    case holdTimeout(time: TimeInterval)
    case reset
}
public enum SoloOutput: Equatable {
    case none
    case pending
    case press
    case tapRelease // quick solo release before hold timeout
    case holdRelease // release after press fired
    case cancelled
}
public struct SoloModifierState: Equatable {
    public var pendingSince: TimeInterval?
    public var pressed: Bool
    public init(pendingSince: TimeInterval? = nil, pressed: Bool = false) {
        self.pendingSince = pendingSince; self.pressed = pressed
    }
}
public enum ModifierSoloReducer {
    public static var holdDelay: TimeInterval { 0.3 }
    public static func step(state: inout SoloModifierState, event: SoloInputEvent, targetKey: ModifierKey, targetSide: ModifierSide, behavior: ShortcutBehavior) -> SoloOutput {
        switch event {
        case .targetDown(let key, let side, let time, let sole):
            guard key == targetKey, side == targetSide, sole else { return .none }
            guard state.pendingSince == nil, !state.pressed else { return .none }
            state.pendingSince = time; state.pressed = false
            return .pending
        case .otherKeyDown, .otherModifierDown:
            if state.pressed { return .none }
            if state.pendingSince != nil {
                state.pendingSince = nil
                return .cancelled
            }
            return .none
        case .holdTimeout:
            guard state.pendingSince != nil, !state.pressed else { return .none }
            if behavior == .toggle { return .none }
            state.pressed = true
            return .press
        case .targetUp(let key, let side, _):
            guard key == targetKey, side == targetSide else { return .none }
            if state.pressed {
                state.pendingSince = nil; state.pressed = false
                return .holdRelease
            }
            if state.pendingSince != nil {
                state.pendingSince = nil
                return .tapRelease
            }
            return .none
        case .reset:
            let had = state.pendingSince != nil || state.pressed
            state.pendingSince = nil; state.pressed = false
            return had ? .cancelled : .none
        }
    }
}

public final class ShortcutEngine {
    public struct Sinks {
        public var start: () -> Void
        public var finish: () -> Void
        public var cancel: () -> Void
        public var isRecording: () -> Bool
        public var isBusy: () -> Bool
        public var currentOperation: () -> UInt64
        public init(
            start: @escaping () -> Void, finish: @escaping () -> Void, cancel: @escaping () -> Void,
            isRecording: @escaping () -> Bool, isBusy: @escaping () -> Bool,
            currentOperation: @escaping () -> UInt64 = { 0 }
        ) {
            self.start = start; self.finish = finish; self.cancel = cancel
            self.isRecording = isRecording; self.isBusy = isBusy
            self.currentOperation = currentOperation
        }
    }
    public private(set) var configuration: ShortcutConfiguration
    public private(set) var activePressID: UInt64?
    public private(set) var activeCaptureID: UInt64?
    public private(set) var activeOperation: UInt64?
    public private(set) var pressStartTime: TimeInterval?
    public private(set) var nextPressID: UInt64 = 1
    public private(set) var captureEpoch: UInt64 = 0
    private var tapKept = false
    private let sinks: Sinks
    private let now: () -> TimeInterval
    public init(configuration: ShortcutConfiguration, sinks: Sinks, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration
        self.sinks = sinks
        self.now = now
    }
    public func updateConfiguration(_ c: ShortcutConfiguration) {
        configuration = c
        activePressID = nil
        activeCaptureID = nil
        activeOperation = nil
        pressStartTime = nil
        tapKept = false
    }
    public var canChangeSettings: Bool { !(sinks.isRecording() || sinks.isBusy()) }

    @discardableResult
    public func press(isRepeat: Bool = false, downTime: TimeInterval? = nil) -> Bool {
        if isRepeat { return false }
        // Physical down time threads through delayed solo confirmation so TapOrHold
        // classifies the total hold (down@0, guard@0.3, up@0.35 => HOLD finishes).
        let down = downTime ?? now()
        let recording = sinks.isRecording()
        let busy = sinks.isBusy()
        switch configuration.behavior {
        case .toggle:
            if activePressID != nil { return false } // duplicate press while held
            if recording {
                let id = nextPressID; nextPressID += 1
                activePressID = id; pressStartTime = down
                // No capture ownership for toggle-off; release just clears.
                activeCaptureID = nil; activeOperation = nil; tapKept = false
                sinks.finish()
                return true
            }
            if busy { return false }
            let id = nextPressID; nextPressID += 1
            activePressID = id; pressStartTime = down
            captureEpoch += 1; activeCaptureID = captureEpoch; tapKept = false
            sinks.start()
            activeOperation = sinks.currentOperation()
            return true
        case .holdToTalk, .tapOrHold:
            // Tap-off arming: previous tap kept capture alive (press cleared, capture kept).
            if activePressID == nil, activeCaptureID != nil, tapKept, recording || busy {
                let id = nextPressID; nextPressID += 1
                activePressID = id; pressStartTime = down
                return true // armed; release will finish
            }
            if activePressID != nil { return false }
            // Stale kept capture with no live recording: drop it and start fresh if idle.
            if activeCaptureID != nil, !recording, !busy {
                activeCaptureID = nil; activeOperation = nil; tapKept = false
            } else if activeCaptureID != nil {
                return false // kept capture still live but unexpected state; duplicate guard
            }
            if recording || busy { return false } // foreign capture: never steal; release must not finish it
            let id = nextPressID; nextPressID += 1
            activePressID = id; pressStartTime = down
            captureEpoch += 1; activeCaptureID = captureEpoch; tapKept = false
            sinks.start()
            activeOperation = sinks.currentOperation()
            return true
        }
    }

    @discardableResult
    public func release() -> Bool {
        guard let id = activePressID else {
            // Tap-kept capture has no active press; release without press is stale.
            return false
        }
        return releaseForPressID(id)
    }

    @discardableResult
    public func releaseForPressID(_ id: UInt64) -> Bool {
        guard let active = activePressID, active == id else { return false }
        // Toggle releases never act.
        if configuration.behavior == .toggle {
            activePressID = nil; activeCaptureID = nil; activeOperation = nil; pressStartTime = nil; tapKept = false
            return false
        }
        let start = pressStartTime ?? now()
        let duration = now() - start
        let owned = activeCaptureID
        let recording = sinks.isRecording()
        let busy = sinks.isBusy()
        // Ownership binds to the actual Model generation observed right after start.
        // A manual menu Finish + new Start changes generation; the stale release must not
        // finish or cancel the new unrelated capture.
        if let ownedOp = activeOperation, ownedOp != sinks.currentOperation() {
            activePressID = nil; activeCaptureID = nil; activeOperation = nil; pressStartTime = nil; tapKept = false
            return false
        }
        // Late release after foreign finish or completed capture: suppress.
        guard owned != nil else {
            activePressID = nil; activeOperation = nil; pressStartTime = nil
            return false
        }
        if !recording && !busy {
            activePressID = nil; activeCaptureID = nil; activeOperation = nil; pressStartTime = nil; tapKept = false
            return false
        }
        // Tap-or-hold short tap keeps recording (first tap only). Boundary (0.300s) belongs to hold.
        // Use epsilon so binary floating-point 0.300 still finishes.
        if configuration.behavior == .tapOrHold, !tapKept, duration + 1e-6 < ShortcutBehavior.tapHoldThreshold {
            activePressID = nil; pressStartTime = nil
            tapKept = true // keep activeCaptureID for tap-off cycle
            return false
        }
        // Hold finish (or tap-off finish, or busy abort).
        activePressID = nil; pressStartTime = nil; activeCaptureID = nil; activeOperation = nil; tapKept = false
        captureEpoch += 1
        if recording {
            sinks.finish()
        } else {
            // Preparing/transcribing: abort without runaway.
            sinks.cancel()
        }
        return true
    }

    public func handleInterruption() {
        guard activePressID != nil || activeCaptureID != nil else { return }
        let owned = activeCaptureID != nil
        let ownedOp = activeOperation
        activePressID = nil; pressStartTime = nil; tapKept = false
        // Only cancel the capture this press actually started. A generation change means
        // a manual Finish/Start already replaced it; never cancel unrelated work and never
        // insert automatically on interruption (sinks.cancel preserves audio, inserts nothing).
        if owned, let ownedOp, ownedOp == sinks.currentOperation(), sinks.isRecording() || sinks.isBusy() {
            sinks.cancel()
            captureEpoch += 1
        }
        activeCaptureID = nil; activeOperation = nil
    }
}
