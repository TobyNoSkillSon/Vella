import AppKit
import ApplicationServices

/// Request the application's accessibility tree, not a macOS permission change.
/// Chromium-family applications can otherwise expose a window but no focused field.
@MainActor enum AccessibilityFocus {
    private static var lastAttempt: [pid_t: Date] = [:]

    nonisolated static func isFieldRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role)
    }

    static func prepare(_ target: NSRunningApplication?) {
        guard AXIsProcessTrusted(), let target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = target.processIdentifier
        // Chromium debounces activation. Repeated requests can restart that delay.
        if let attempted = lastAttempt[pid], Date().timeIntervalSince(attempted) < 5 { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(app, &names) == .success,
              let advertised = names as? [String] else { return }
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] where advertised.contains(name) {
            var enabled: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, name as CFString, &enabled) == .success,
               enabled as? Bool == true { return }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(app, name as CFString, &settable) == .success,
                  settable.boolValue else { continue }
            if lastAttempt.count > 128 { lastAttempt.removeAll() }
            lastAttempt[pid] = Date()
            _ = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
            return
        }
    }
}
