import AppKit
import VellaCore
import VellaUpdate

// Render harness for the Transcripts window and the shortened pop-ups (review images only): the real window and the
// real alert factories, drawn offscreen. Fixture recordings are written under `<out>/fixtures`; with an absolute
// VELLA_SUPPORT_DIR its Recordings folder is rendered too ("real"). Never activates Vella or takes focus.

@MainActor final class TranscriptsRenderDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    private var actions: [() -> Void] = []
    private var keep: [AnyObject] = []
    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TranscriptsWindow.keepOffscreen = true
        TranscriptsWindowController.activateApp = {}
        // The lab app shares Vella's defaults domain: renders never save a window frame into it.
        TranscriptsWindowController.autosaves = false
        let fixtures = directory.appendingPathComponent("fixtures")
        try? FileManager.default.removeItem(at: fixtures)
        let now = Date()
        window("transcripts-empty", Self.fixture(fixtures.appendingPathComponent("empty"), count: 0, now: now))
        window("transcripts-3", Self.fixture(fixtures.appendingPathComponent("three"), count: 3, now: now))
        let many = Self.fixture(fixtures.appendingPathComponent("many"), count: 14, now: now)
        window("transcripts-10-top", many)
        window("transcripts-10-bottom", many, scrollToBottom: true)
        window("transcripts-10-expanded", many, expandLongest: true)
        if let support = ProcessInfo.processInfo.environment["VELLA_SUPPORT_DIR"], support.hasPrefix("/") {
            window("transcripts-real", URL(fileURLWithPath: support).appendingPathComponent("Recordings"))
        }
        alerts()
        next()
    }

    /// `count` recordings with text, spread over today, yesterday and earlier days, plus one without text (still
    /// recording) that the window must skip. Every fourth is incomplete; the second is long enough to clamp.
    static func fixture(_ base: URL, count: Int, now: Date) -> URL {
        let root = base.appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let texts = [
            "Can you move the standup to ten tomorrow and send the notes from today to the whole team?",
            "Okay so the plan for the release is this. First we merge the models table branch, then the transcripts window, then the fallback hardening. "
                + "After that we build it locally and test it on the M4 Pro as well, because that's the Mac where the Get state did not update. "
                + "If everything is fine we push the tag, update the Homebrew cask and write the release notes. I want the notes short: what changed, "
                + "what the user sees, nothing about the internals. And remind me to check that the download pop-up shows the short name.",
            "Buy oat milk, coffee beans and batteries for the keyboard.",
            "The second chart should use the same palette as the first one and the axis needs units.",
            "Reply to Marta: yes, Thursday works, let's meet at the office at two.",
            "Note to self: the shortcut conflict only happens when the other dictation app is running."
        ]
        let calendar = Calendar.current
        for i in 0..<count {
            let dayOffset = i < 3 ? 0 : i < 6 ? 1 : i < 9 ? 3 : 9
            var date = calendar.date(byAdding: .day, value: -dayOffset, to: now)!
            date = calendar.date(bySettingHour: max(8, 18 - (i % 3) * 3), minute: (i * 7) % 60, second: 0, of: date)!
            if dayOffset == 0, date > now { date = now.addingTimeInterval(Double(-600 * (i + 1))) }
            let folder = root.appendingPathComponent(String(format: "FIXTURE-%04d", i))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: folder.appendingPathComponent("session.json"))
            let text = texts[i % texts.count]
            if i % 4 == 3 {
                try? Data(("[Incomplete transcript — retry missing audio segments]\n" + text).utf8).write(to: folder.appendingPathComponent("partial-transcript.txt"))
            } else {
                try? Data(text.utf8).write(to: folder.appendingPathComponent("transcript.txt"))
            }
            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: folder.path)
        }
        if count > 0 {
            let recording = root.appendingPathComponent("FIXTURE-RECORDING")
            try? FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: recording.appendingPathComponent("session.json"))
        }
        return root
    }

    private func window(_ name: String, _ root: URL, scrollToBottom: Bool = false, expandLongest: Bool = false) {
        actions.append { [self] in
            let controller = TranscriptsWindowController(root: root)
            keep.append(controller)
            controller.model.reload()
            if expandLongest, let long = controller.model.entries.max(by: { $0.text.count < $1.text.count }) { controller.model.expanded = [long.id] }
            guard let window = controller.window else { next(); return }
            window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                if scrollToBottom, let scroll = Self.scrollView(in: window.contentView), let document = scroll.documentView {
                    let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    Self.capture(window, to: directory.appendingPathComponent(name + ".png"))
                    window.orderOut(nil)
                    next()
                }
            }
        }
    }
    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }
    /// The whole window, title-bar band and traffic lights included (the frame view draws them).
    static func capture(_ window: NSWindow, to url: URL) {
        guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func alerts() {
        let controller = RenderFixture.controller()
        let catalog = controller.catalog
        var list: [(String, NSAlert)] = []
        if let ultra = catalog.family("parakeet-v3-ultra"), let p = downloadPrompt(family: ultra, precision: "8b", followUp: .load, freeBytes: 400_000_000_000) {
            list.append(("download-ultra-8bit", DownloadGate.alert(p)))
        }
        if let v3 = catalog.family("parakeet-v3"), let p = downloadPrompt(family: v3, precision: "BF16", followUp: .reload(from: "4b"), freeBytes: 400_000_000_000) {
            list.append(("download-v3-reload", DownloadGate.alert(p)))
        }
        if let whisper = catalog.family("whisper-large-v3"), let p = downloadPrompt(family: whisper, precision: "FP16", followUp: .transcribe, freeBytes: 1_200_000_000) {
            list.append(("download-whisper-low-disk", DownloadGate.alert(p)))
        }
        for (name, earlier) in [("delete-model", false), ("delete-unused-model", true)] {
            let plan = ModelDeletionPlan(
                familyID: "parakeet-v3-ultra", precision: "BF16", variantID: "parakeet-ultra-mlx-bf16", path: "/render", wasInstalled: true,
                bytes: 1_254_840_214, title: earlier ? "Delete unused Parakeet v3 int8?" : "Delete Parakeet v3 Ultra bf16?", earlierDownload: earlier)
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = plan.title; alert.informativeText = plan.body
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Move to Trash")
            list.append((name, alert))
        }
        list.append(("quit-download", AppDelegate.quitAlert(downloading: true)))
        list.append(("quit-recording", AppDelegate.quitAlert(downloading: false)))
        list.append(("delete-saved-recording", AppDelegate.deleteSavedAlert()))
        list.append((
            "recover-saved-recording",
            AppDelegate.savedRecordingAlert([SavedRecordingChoice(directory: URL(fileURLWithPath: "/fixture"), title: "15 Oct 2026 at 11:42 · Dictation · 0:42 · interrupted")])
        ))
        list.append(("login-failure", AppDelegate.loginFailureAlert(VellaError.message("The operation couldn’t be completed"))))
        let updates = UpdateController(current: "2.0.1", enabled: false)
        if let version = SemanticVersion("2.1.0") {
            let release = ReleaseInfo(tag: "v2.1.0", version: version, body: "One row per model, always optimized. A Transcripts window. Shorter pop-ups.")
            list.append(("update-confirm", updates.confirmation(release)))
        }
        let failed = NSAlert(); failed.messageText = "Dictation failed"; failed.informativeText = Backend.loadFailed("Parakeet v3 Ultra"); failed.addButton(withTitle: "OK")
        list.append(("load-failed", failed))
        for (name, alert) in list {
            actions.append { [self] in TableRenderDelegate.renderAlert(alert, to: directory.appendingPathComponent("alert-\(name).png"), done: next) }
        }
    }

    private func next() {
        if actions.isEmpty { NSApp.terminate(nil); return }
        actions.removeFirst()()
    }
}
