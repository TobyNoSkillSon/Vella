import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

// MARK: - Registrar abstraction (testable; no host audio/input in tests)

public protocol ShortcutRegistrar: AnyObject {
    var registered: ShortcutConfiguration? { get }
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws
    func unregister()
    /// Clear pending input and invalidate queued native callbacks without
    /// losing registration or notifying. Default no-op for mocks.
    func resetPendingInput()
}

extension ShortcutRegistrar {
    func resetPendingInput() {}
}

/// Carbon press+release for regular key chords. No new permissions.
/// Transactional: the prior hotkey stays registered until the new chord succeeds.
public final class CarbonShortcutRegistrar: ShortcutRegistrar {
    public private(set) var registered: ShortcutConfiguration?
    private var active: GlobalShortcut?
    public init() {}
    public func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        guard case .keyChord(let code, let mods) = config.trigger else {
            throw VellaError.message("That binding needs an event tap, not Carbon.")
        }
        // Behavior-only change on the same chord needs no OS re-registration.
        if let active, registered?.trigger == config.trigger {
            active.updateHandlers(onPress: onPress, onRelease: onRelease)
            registered = config
            return
        }
        let trial = GlobalShortcut()
        do {
            try trial.registerChord(keyCode: code, modifiers: mods, onPress: onPress, onRelease: onRelease)
        } catch let err as VellaError {
            throw err
        } catch {
            throw VellaError.message("That shortcut is already reserved or could not be registered. Choose another chord.")
        }
        active?.unregister()
        active = trial
        registered = config
    }
    public func unregister() {
        active?.unregister()
        active = nil
        registered = nil
    }
    public func resetPendingInput() {
        // Invalidate queued Carbon deliveries without losing registration:
        // bump the callback generation, keep hotkey ID/ref/handlers.
        if let active {
            let press = active.onPress ?? active.action ?? {}
            let release = active.onRelease ?? {}
            active.updateHandlers(onPress: press, onRelease: release)
        }
    }
}
