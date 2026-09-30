import AppKit
import ApplicationServices

// Explicit CLI-only QA. The sole paste target is a newly created disposable document.
@MainActor enum PasteProbe {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func key(_ code: CGKeyCode) {
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
            event?.flags = .maskCommand; event?.post(tap: .cghidEventTap)
        }
    }
    static func run() async {
        let original = NSWorkspace.shared.frontmostApplication
        let clipboard = NSPasteboard.general
        let originalClipboard = (clipboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        var qaClipboardCount: Int?
        defer {
            if let qaClipboardCount, clipboard.changeCount == qaClipboardCount {
                clipboard.clearContents()
                clipboard.writeObjects(originalClipboard.map { values in
                    let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
                })
            }
            original?.activate(options: []); NSApp.terminate(nil)
        }
        let output = Backend.support.appendingPathComponent("paste-check.json")
        func report(_ message: String) {
            if let data = try? JSONSerialization.data(withJSONObject: ["result": message, "checkedAt": ISO8601DateFormatter().string(from: Date())]) { try? data.write(to: output, options: .atomic) }
        }
        guard AXIsProcessTrusted() else { report("blocked: no existing Accessibility grant"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vella-Paste-Check-\(UUID().uuidString).txt")
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let target = try await NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: configuration)
            let app = AXUIElementCreateApplication(target.processIdentifier)
            func ownsFocus(_ expected: URL) -> Bool {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      let raw = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
                let window = unsafeBitCast(raw, to: AXUIElement.self)
                guard let document = attribute(window, kAXDocumentAttribute) as? String,
                      let documentURL = URL(string: document) else { return false }
                return documentURL.standardizedFileURL == expected.standardizedFileURL
            }
            for _ in 0..<20 { if ownsFocus(url) { break }; try await Task.sleep(nanoseconds: 200_000_000) }
            guard ownsFocus(url) else { report("blocked: disposable document does not own focus; nothing pasted"); return }
            var shortcutEvents = 0
            let shortcut = GlobalShortcut()
            shortcut.action = { shortcutEvents += 1 }
            guard shortcut.register() else { report("failed: global shortcut could not register"); return }
            for _ in 0..<2 {
                guard ownsFocus(url) else { report("blocked: test document lost focus"); return }
                for pressed in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: pressed)
                    event?.flags = [.maskControl, .maskCommand]; event?.post(tap: .cghidEventTap)
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard shortcutEvents == 2 else { report("failed: global shortcut callbacks missing"); return }
            let model = Model()
            model.checkPaste(to: target)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard ownsFocus(url), let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { report("failed: focus changed during paste"); return }
            let field = unsafeBitCast(raw, to: AXUIElement.self)
            let accepted = (attribute(field, kAXValueAttribute) as? String)?.contains("Vella paste verification.") == true
            guard accepted, model.insertionWasAutomatic else { report("failed: target did not accept the test paste"); return }
            // Save and close only the verified test document. No Return/Send events.
            key(1) // Command-S
            try await Task.sleep(nanoseconds: 500_000_000)
            guard ownsFocus(url), let firstRaw = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(firstRaw) == AXUIElementGetTypeID() else { report("blocked: first document lost focus"); return }
            let firstWindow = unsafeBitCast(firstRaw, to: AXUIElement.self)
            model.preparePasteCheck(to: target)
            let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent("Vella-Other-Window-Check-\(UUID()).txt")
            try "".write(to: otherURL, atomically: true, encoding: .utf8)
            _ = try await NSWorkspace.shared.open([otherURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: configuration)
            for _ in 0..<20 { if ownsFocus(otherURL) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            guard ownsFocus(otherURL) else { report("blocked: second owned document not focused"); return }
            model.finishPasteCheck()
            qaClipboardCount = clipboard.changeCount
            try await Task.sleep(nanoseconds: 300_000_000)
            guard ownsFocus(otherURL), let otherRaw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(otherRaw) == AXUIElementGetTypeID() else { report("blocked: second field unavailable"); return }
            let otherField = unsafeBitCast(otherRaw, to: AXUIElement.self)
            guard !model.insertionWasAutomatic, (attribute(otherField, kAXValueAttribute) as? String)?.isEmpty == true,
                  clipboard.string(forType: .string) == "Vella paste verification." else { report("failed: different-window insertion guard"); return }
            key(13) // Close only the verified empty second document.
            try await Task.sleep(nanoseconds: 300_000_000)
            AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
            target.activate(options: [])
            try await Task.sleep(nanoseconds: 300_000_000)
            if ownsFocus(url) { key(13) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: otherURL)
            withExtendedLifetime(shortcut) {}
            report("passed: two real global shortcut events; actual Command-V accepted; different TextEdit window stayed empty with clipboard fallback; no Return/Send")
        } catch { report("failed: \(error.localizedDescription)") }
    }
}
