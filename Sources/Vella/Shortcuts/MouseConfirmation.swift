import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

// MARK: - Bounded mouse-button confirmation seams (injectable, no global posting in tests)

/// Thin native observer for mouse-button confirmation. Production consumes the
/// matching down/up via a CGEvent tap so the gesture never navigates; tests
/// inject a fake and drive the manager handler directly with synthetic events.
public protocol MouseConfirmationMonitor: AnyObject {
    func start(button: MouseButton, handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) throws
    func stop()
}

/// Bounded 10s timer. Production fires in `.common` modes so it fires while
/// the native menu is tracking; tests inject a manual fake.
public protocol MouseConfirmationTimer: AnyObject {
    func schedule(delay: TimeInterval, handler: @escaping () -> Void)
    func invalidate()
}

/// Native confirmation tap: observes ONLY otherMouseDown/Up, consumes the
/// expected button so it never navigates. Silent AX check only; never prompts.
/// No raw HID, no new permission scope — reuses existing Accessibility access.
final class CGEventMouseConfirmationMonitor: MouseConfirmationMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapBox: ConfirmationTapBox?
    func start(button: MouseButton, handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) throws {
        // Silent check only; never prompts here. AX-denied surfaces distinctly.
        guard AXIsProcessTrusted() else {
            throw VellaError.message(ShortcutManager.mouseConfirmationAccessDeniedMessage)
        }
        stop()
        // Mask matches observed types: expected other-button down/up for commit,
        // plus wrong other-button and ordinary left/right downs for SAME-row feedback.
        // Left/right are never consumed. No key observation.
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
        // tapBox owns the box for the monitor lifetime; context is unretained
        // (no manual retain/release). stop()/deinit clears it, so the pointer
        // never dangles and failures never pretend monitoring.
        let box = ConfirmationTapBox(handler: handler, onFailure: onFailure)
        tapBox = box
        let context = Unmanaged<ConfirmationTapBox>.passUnretained(box).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, data in
            guard let data else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<ConfirmationTapBox>.fromOpaque(data).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let rawTap = box.liveTap { CGEvent.tapEnable(tap: rawTap, enable: true) }
                let failure = box.onFailure
                DispatchQueue.main.async { failure() }
                return Unmanaged.passUnretained(event)
            }
            if box.handler(type, event) { return nil } // consumed: never navigates
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            tapBox = nil
            throw VellaError.message(ShortcutManager.mouseConfirmationUnavailableMessage)
        }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            tapBox = nil
            // tapCreate succeeded but no runloop source: fail cleanly, never pretend.
            throw VellaError.message(ShortcutManager.mouseConfirmationUnavailableMessage)
        }
        box.liveTap = tap
        self.tap = tap
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        _ = button // button filtering lives in the manager handler (testable reducer)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil; self.tap = nil; self.tapBox = nil
    }
    deinit { stop() }
}

private final class ConfirmationTapBox {
    let handler: (CGEventType, CGEvent) -> Bool
    let onFailure: () -> Void
    var liveTap: CFMachPort?
    init(handler: @escaping (CGEventType, CGEvent) -> Bool, onFailure: @escaping () -> Void) { self.handler = handler; self.onFailure = onFailure }
}

/// Production timer scheduled in event-tracking + common modes so the 10s
/// bound fires while the native menu is tracking.
final class CommonRunLoopMouseConfirmationTimer: MouseConfirmationTimer {
    private var timer: Timer?
    func schedule(delay: TimeInterval, handler: @escaping () -> Void) {
        invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in handler() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    func invalidate() { timer?.invalidate(); timer = nil }
    deinit { invalidate() }
}

final class ShortcutActionBox {
    var handler: ((String) -> Void)?
}
