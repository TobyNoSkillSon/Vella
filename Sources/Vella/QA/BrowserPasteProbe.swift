import AppKit
import ApplicationServices

/// Explicit QA against an agent-owned disposable browser page, never an account form.
@MainActor enum BrowserPasteProbe {
    static let marker = "Vella-Paste-QA-7c2e"
    static func run() async {
        // Launch with open -g. The driver refocuses the disposable field after
        // the browser activation below, before we bind the insertion target.
        defer { NSApp.terminate(nil) }
        let output = Backend.support.appendingPathComponent("browser-paste-check.json")
        func report(_ state: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        guard AXIsProcessTrusted() else { report(["result": "blocked: no Accessibility grant"]); return }
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.citrolabs.ego.lite" }) else {
            report(["result": "blocked: QA browser unavailable"]); return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate(options: [])
        }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let manualResult = CommandLine.arguments.contains("--prime-browser-manual-accessibility")
            ? AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) : nil
        func element(_ attribute: String) -> AXUIElement? {
            guard let value = PasteProbe.attribute(app, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        func owned(_ field: AXUIElement?) -> Bool {
            var node = field
            for _ in 0..<24 {
                guard let current = node else { return false }
                // Some native browser bridges omit web titles/labels. Only the
                // exact disposable fixture values qualify, never arbitrary text.
                if let value = PasteProbe.attribute(current, kAXValueAttribute) as? String,
                   [marker + ":a", marker + ":b", marker + ":rich"].contains(value) { return true }
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXURLAttribute] {
                    if let value = PasteProbe.attribute(current, key), String(describing: value).contains(marker) { return true }
                }
                guard let parent = PasteProbe.attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
                node = unsafeBitCast(parent, to: AXUIElement.self)
            }
            return false
        }
        report(["result": "awaiting-focus"])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if owned(element(kAXFocusedUIElementAttribute)) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let field = element(kAXFocusedUIElementAttribute), window = element(kAXFocusedWindowAttribute)
        var state: [String: Any] = ["trusted": true,
            "focusedRole": field.flatMap { PasteProbe.attribute($0, kAXRoleAttribute) as? String } ?? "unavailable",
            "windowRole": window.flatMap { PasteProbe.attribute($0, kAXRoleAttribute) as? String } ?? "unavailable",
            "ownedPage": owned(field) || owned(window)]
        state["focusDescription"] = field.flatMap { PasteProbe.attribute($0, kAXRoleDescriptionAttribute) as? String } ?? "unavailable"
        state["focusIdentifier"] = field.flatMap { PasteProbe.attribute($0, kAXIdentifierAttribute) as? String } ?? "unavailable"
        state["windowMatchesTaskName"] = window.flatMap { PasteProbe.attribute($0, kAXTitleAttribute) as? String } == "Vella browser insertion QA"
        var parentRoles: [String] = []
        var node = field
        for _ in 0..<12 {
            guard let current = node else { break }
            parentRoles.append(PasteProbe.attribute(current, kAXRoleAttribute) as? String ?? "unknown")
            guard let parent = PasteProbe.attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
        }
        state["focusAncestorRoles"] = parentRoles
        state["enhancedUI"] = PasteProbe.attribute(app, "AXEnhancedUserInterface") as? Bool ?? false
        if let manualResult { state["manualAccessibilityResult"] = manualResult.rawValue }
        if let focusedApp = PasteProbe.attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute), CFGetTypeID(focusedApp) == AXUIElementGetTypeID() {
            let systemApp = unsafeBitCast(focusedApp, to: AXUIElement.self)
            var pid: pid_t = 0; AXUIElementGetPid(systemApp, &pid)
            state["systemFocusMatchesBrowserPID"] = pid == target.processIdentifier
        }
        var names: CFArray?
        _ = AXUIElementCopyAttributeNames(app, &names)
        state["applicationAttributes"] = names as? [String] ?? []
        if CommandLine.arguments.contains("--check-browser-accessibility") {
            state["result"] = "read-only focus diagnostic"; report(state); return
        }
        guard owned(field), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            state["result"] = "blocked: disposable QA page does not own focus"; report(state); return
        }
        let clipboard = NSPasteboard.general
        let wasEmpty = clipboard.pasteboardItems?.isEmpty != false
        let previous = Model.clipboardTextToRestore(clipboard, eligible: true)
        guard wasEmpty || previous != nil else {
            state["result"] = "blocked: QA will not overwrite an unsupported clipboard payload"; report(state); return
        }
        var qaClipboardCount: Int?
        defer {
            if let qaClipboardCount, clipboard.changeCount == qaClipboardCount {
                if let previous { Model.restoreClipboardText(previous, to: clipboard, changeCount: qaClipboardCount) }
                else if wasEmpty { clipboard.clearContents() }
            }
        }
        let model = Model()
        model.preparePasteCheck(to: target)
        state["result"] = "prepared"; report(state)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        model.finishPasteCheck()
        qaClipboardCount = clipboard.changeCount
        state["result"] = "completed"
        state["pasteSent"] = model.insertionWasAutomatic
        state["message"] = model.message
        report(state)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
    }
}
