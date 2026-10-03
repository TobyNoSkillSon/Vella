import AppKit
import ServiceManagement
import VellaCore

@MainActor final class LifecycleRenderDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    private var app: AppDelegate!
    private var actions: [() -> Void] = []
    init(directory: URL) { self.directory = directory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var trusted = true
        let permission = InsertionPermission(isTrusted: { trusted }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(
            insertionPermission: permission, configurationURL: RenderFixture.root.appendingPathComponent("lifecycle-config.json"), monitorDefaultInput: false)
        app = AppDelegate(model: model); app.modelsMenu = ModelsMenu(controller: RenderFixture.controller(installed: RenderFixture.downloaded))
        for state in [
            ("failed-microphone", DictationController.Phase.failed, "Microphone capture stopped. Saved audio is retained."),
            ("failed-accessibility", .failed, "Accessibility access was revoked. Re-enable Vella in Settings."),
            ("sleep-wake", .failed, "Mac woke. Recording ended for sleep; audio and recognized text are saved. Retry copies only."),
            ("ready-recovery", .idle, "Ready"), ("streaming-success", .success, "Streaming text sent as you spoke. Full transcript saved; no duplicate final paste."),
            ("streaming-accessibility-revoked", .recording, "Accessibility access was revoked. Audio and the transcript are still saved. Microphone capture continues.")
        ] {
            actions.append { [self] in
                if state.0.hasPrefix("streaming") { try? model.selectMode(.streaming) }
                trusted = !state.0.contains("accessibility")
                model.phase = state.1; model.message = state.2
                if state.0 == "sleep-wake" {
                    #if DEBUG
                        let session = try? RecordingSession(root: RenderFixture.root, config: Configuration(model: "/fixture"))
                        if let session, let writer = try? SegmentedPCMWriter(session: session) {
                            try? [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
                            try? writer.finish(userStopped: false)
                            model.recorder.adoptForTesting(session); model.phase = .recording
                            model.hardwareEvent(.willSleep); model.hardwareEvent(.didWake)
                        }
                    #endif
                }
                model.insertionWasAutomatic = state.0 == "streaming-success"
                app.rebuildMenu(); MenuMock.render(app.menu.items, width: 340, to: directory.appendingPathComponent("menu-\(state.0).png"), done: next)
            }
        }
        actions.append { [self] in
            trusted = true
            model.phase = .idle; app.loginStatus = { .requiresApproval }; app.rebuildMenu()
            MenuMock.render(app.menu.items, width: 340, to: directory.appendingPathComponent("menu-login-approval.png"), done: next)
        }
        let choices = [
            SavedRecordingChoice(directory: URL(fileURLWithPath: "/fixture"), title: "3 Oct 2026 at 12:00 · Dictation · interrupted"),
            SavedRecordingChoice(directory: URL(fileURLWithPath: "/fixture-stream"), title: "3 Oct 2026 at 12:02 · Streaming · interrupted")
        ]
        alert("recovery", AppDelegate.savedRecordingAlert(choices))
        alert(
            "login-failure", title: "Could not change Launch at Login", body: "The operation could not be completed. Check System Settings → General → Login Items & Extensions.",
            buttons: ["OK"])
        alert(
            "quit-download", title: "Quit Vella?", body: "The model download will stop and its partial files will be removed. Saved recordings and installed models are kept.",
            buttons: ["Keep Vella Open", "Quit"])
        alert(
            "quit-recording", title: "Quit Vella?", body: "Saved audio and completed text will be kept. Unfinished text will not be inserted.", buttons: ["Keep Vella Open", "Quit"]
        )
        alert(
            "microphone-purpose", title: "Microphone access",
            body: "Vella records your voice only when you start Dictation or Streaming. Speech recognition runs locally on your Mac.", buttons: ["OK"])
        alert(
            "update-rollback", title: "Update did not become ready", body: "Vella 2.0.1 did not become ready: a configured model could not load. Vella 2.0.0 was restored.",
            buttons: ["OK"])
        alert("update-network", title: "Update to 2.0.1 failed", body: "The network connection was lost. Vella 2.0.0 is unchanged.", buttons: ["OK"])
        let pairs = [
            ("Speed on other Macs", BenchmarkHardware(chip: "M5 Pro", gpuCores: 20).caveat!),
            ("Precision", TierControl.headerHelp), ("Peak RAM", ModelTable.memoryHeaderHelp), ("Loaded on demand", onDemandLoadHelp),
            ("Legacy Delete", "These unused earlier weights cannot be downloaded again from Vella’s catalog. No recipe files depend on them. Recordings and transcripts are kept."),
            ("Model load failed", Backend.loadFailed("Parakeet v3 Ultra")),
            (
                "Recipe preparation failed",
                "Could not prepare the local precision: Vella does not have permission to write the recipe. The current selection is unchanged. Check the model folder and try Load again in Models…."
            ),
            ("Word timestamps", "Word timestamps are not supported. Use timestamp_granularities[]=segment with response_format=verbose_json."),
            ("Direct control API", "Select needs at least one JSON field: precision, path or mode. Deletion needs explicit consent: yes=true (CLI: --yes).")
        ]
        actions.append { [self] in MenuMock.capture(TooltipSheet(pairs: pairs, width: 640), to: directory.appendingPathComponent("changed-tooltips.png"), done: next) }
        actions.append { [self] in MenuMock.capture(DMGLayoutView(), to: directory.appendingPathComponent("dmg-window-settings.png"), done: next) }
        let shortcutError =
            "This shortcut could not be registered because another application uses it. Choose another shortcut in Vella’s Shortcuts menu; the current shortcut remains active."
        actions.append { [self] in
            let item = NSMenuItem(title: compactText(shortcutError, limit: 96), action: nil, keyEquivalent: ""); item.toolTip = shortcutError
            MenuMock.render([item], width: 340, to: directory.appendingPathComponent("shortcut-error-truncation.png"), done: next)
        }
        let install = "scripts/install.sh --migrate-signing\n\n" + NativeInstaller.migrationExplanation + "\nMigrate the signing identity now? [y/N]"
        actions.append { [self] in MenuMock.capture(CLIOutputView(install), to: directory.appendingPathComponent("installer-signing-consent.png"), done: next) }
        if let output = ProcessInfo.processInfo.environment["VELLA_DOC_EXAMPLE_OUTPUTS"] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: output), includingPropertiesForKeys: nil)) ?? []).filter {
                $0.pathExtension == "txt"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                actions.append { [self] in
                    MenuMock.capture(CLIOutputView(text), to: directory.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png"), done: next)
                }
            }
        }
        next()
    }
    private func alert(_ name: String, _ alert: NSAlert) {
        actions.append { [self] in TableRenderDelegate.renderAlert(alert, to: directory.appendingPathComponent("alert-\(name).png"), done: next) }
    }
    private func alert(_ name: String, title: String, body: String, buttons: [String]) {
        let value = NSAlert(); value.messageText = title; value.informativeText = body
        buttons.forEach { value.addButton(withTitle: $0) }; alert(name, value)
    }
    private func next() {
        if actions.isEmpty { app.model.shutdown(); NSApp.terminate(nil); return }
        actions.removeFirst()()
    }
}

/// Finder icon-view reconstruction from the same sealed metadata used by package-dmg.sh. Not a Finder screenshot.
final class DMGLayoutView: NSView {
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360)) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let title = NSAttributedString(
            string: "Vella — Drag to Applications", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        title.draw(at: NSPoint(x: (640 - title.size().width) / 2, y: 8))
        for (x, color) in [(16.0, NSColor.systemRed), (36.0, .systemYellow), (56.0, .systemGreen)] {
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: 10, width: 12, height: 12)).fill()
        }
        let root = ModelLibrary.resourceDirectory()
        let icon =
            ProcessInfo.processInfo.environment["VELLA_RENDER_ICON"].flatMap { NSImage(contentsOfFile: $0) } ?? NSImage(contentsOf: root.appendingPathComponent("Vella.icns"))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        for (x, image, label) in [(170.0, icon, "Vella.app"), (470.0, NSWorkspace.shared.icon(forFile: "/Applications"), "Applications")] {
            image.draw(in: NSRect(x: x - 48, y: 112, width: 96, height: 96), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            text.draw(at: NSPoint(x: x - text.size().width / 2, y: 216))
        }
    }
}

final class CLIOutputView: NSView {
    let text: NSAttributedString
    init(_ output: String) {
        text = NSAttributedString(string: output, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
        let height = ceil(text.boundingRect(with: NSSize(width: 980, height: 20000), options: [.usesLineFragmentOrigin]).height) + 36
        super.init(frame: NSRect(x: 0, y: 0, width: 1016, height: height))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        text.draw(with: bounds.insetBy(dx: 18, dy: 18), options: [.usesLineFragmentOrigin])
    }
}
