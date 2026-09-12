import AppKit
import ApplicationServices

/// History records whether setup was shown—not whether macOS grants access.
@MainActor final class PermissionPromptHistory {
    private let read: () -> Bool
    private let write: () -> Void
    init(read: @escaping () -> Bool, write: @escaping () -> Void) { self.read = read; self.write = write }
    var shown: Bool { read() }
    func markShown() { write() }
    static func persistent() -> PermissionPromptHistory {
        let key = "accessibilitySetupPresented"
        return PermissionPromptHistory(read: {
            // Earlier Vella versions already requested setup but did not persist a flag.
            UserDefaults.standard.bool(forKey: key) || FileManager.default.fileExists(atPath: Backend.support.appendingPathComponent("permission-status.json").path)
        }, write: { UserDefaults.standard.set(true, forKey: key) })
    }
}

/// First-setup-only native prompt. All subsequent checks are silent and read live trust.
@MainActor final class InsertionPermission {
    private let isTrusted: () -> Bool
    private let prompt: () -> Void
    private let history: PermissionPromptHistory
    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }, prompt: (() -> Void)? = nil,
         history: PermissionPromptHistory? = nil) {
        self.isTrusted = isTrusted
        self.history = history ?? PermissionPromptHistory.persistent()
        self.prompt = prompt ?? {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }
    var granted: Bool { isTrusted() }
    @discardableResult func ensure() -> Bool {
        if isTrusted() { history.markShown(); return true }
        if !history.shown {
            history.markShown() // Persist before showing UI, including across interrupted launches.
            prompt()
        }
        return isTrusted()
    }
    func openSettings() {
        // Settings opens only through this explicit menu action, never an automatic retry.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
