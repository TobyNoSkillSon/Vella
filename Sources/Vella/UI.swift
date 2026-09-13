import AppKit
import SwiftUI
import QuartzCore
import VellaCore

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model: Model
    var openExternalURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    init(model: Model? = nil) { self.model = model ?? Model(); super.init() }
    let shortcut = GlobalShortcut()
    private lazy var dictationMenus = makeModelMenus(.dictation)
    private lazy var streamingMenus = makeModelMenus(.streaming)
    private var modelMenus: ModelsMenu { model.mode == .dictation ? dictationMenus : streamingMenus }
    private var librariesBusy: Bool {
        [dictationMenus.library, streamingMenus.library].contains { $0.busy || $0.calibration.isRunning }
    }
    private var canChangeMode: Bool { model.phase != .recording && !model.busy && !librariesBusy }
    private func makeModelMenus(_ mode: RecognitionMode) -> ModelsMenu {
        let menus = ModelsMenu(library: ModelLibrary(mode: mode))
        menus.library.mayChangeModel = { [weak self] in
            guard let self else { return false }
            let other = mode == .dictation ? self.streamingMenus.library : self.dictationMenus.library
            return self.model.phase != .recording && !self.model.busy && !other.busy && !other.calibration.isRunning
        }
        menus.library.onUse = { [weak self] in self?.model.stopWorkers() }
        menus.library.beforeHeavyWork = { [weak self] in self?.model.stopWorkers() }
        menus.library.prepareForCalibration = { [weak self] in try await self?.model.releaseWorkers() }
        if mode == .dictation {
            model.referenceSpeed = { [weak menus] path in
                guard let library = menus?.library,
                      let id = library.installed.first(where: { $0.value.path == path })?.key,
                      let speed = library.references[id]?.realtimeFactor, speed.isFinite, speed > 0 else { return nil }
                return speed
            }
        }
        return menus
    }
    var status: NSStatusItem!
    let menu = NSMenu()
    var panel: HUDPanel!
    private var dismissal: DispatchWorkItem?
    private var visibilityRevision = 0
    private(set) var permissionTimer: Timer?
    private var permissionDeadline: TimeInterval?
    private var lastPermission: Bool?
    private var applicationFocusObserver: NSObjectProtocol?
    @discardableResult private func checkPermission() -> Bool {
        let granted = model.insertionPermission.granted
        guard lastPermission != granted else { return granted }
        let previous = lastPermission
        lastPermission = granted
        // Diagnostic metadata only. Never record audio, transcript, or clipboard contents.
        let state: [String: Any] = ["accessibilityGranted": granted,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundlePath": Bundle.main.bundleURL.path,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "menuItems": menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            "checkedAt": ISO8601DateFormatter().string(from: Date())]
        if Bundle.main.bundleIdentifier == "dev.vella.dictation",
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: Backend.support, withIntermediateDirectories: true)
            try? data.write(to: Backend.support.appendingPathComponent("permission-status.json"), options: .atomic)
        }
        if granted && previous == false && model.phase == .idle {
            model.update(.idle, "Automatic insertion is enabled. Press ⌃⌘N in your text field.")
        }
        return granted
    }
    private func stopPermissionPolling() {
        permissionTimer?.invalidate(); permissionTimer = nil; permissionDeadline = nil
    }
    func beginPermissionPolling(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stopPermissionPolling()
        guard !checkPermission() else { return }
        permissionDeadline = now + 60
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermission() }
        }
        timer.tolerance = 0.2
        permissionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func pollPermission(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let deadline = permissionDeadline else { return }
        if now >= deadline || checkPermission() { stopPermissionPolling() }
    }

    @objc private func showCaptureError() {
        let alert = NSAlert()
        alert.messageText = "\(model.mode.title) failed"
        alert.informativeText = model.message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Vella dictation")
        menu.delegate = self; menu.autoenablesItems = false
        // Real NSMenu tracking handles click-away, Escape, and standard macOS keyboard navigation.
        status.menu = menu
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: HUDView.panelSize.width, height: HUDView.panelSize.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
        panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        model.onChange = { [weak self] in self?.refresh() }
        rebuildMenu()
        shortcut.action = { [weak self] in
            self?.menu.cancelTracking(); self?.checkPermission(); self?.model.toggle()
        }
        // Prepare browser accessibility on activation, before the recording's
        // immutable app/window/field snapshot. Never retarget an ongoing recording.
        AccessibilityFocus.prepare(NSWorkspace.shared.frontmostApplication)
        applicationFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in AccessibilityFocus.prepare(app) }
            }
        if !shortcut.register() { model.update(.failed, "⌃⌘N is already reserved or could not be registered. Free it in the other application, then restart Vella.") }
        DispatchQueue.main.async { [weak self] in
            self?.model.ensureAutomaticInsertion()
            self?.beginPermissionPolling()
        }
        if CommandLine.arguments.contains("--check-hud") {
            func report(_ phase: String) {
                let state: [String: Any] = ["phase": phase, "window": self.panel.windowNumber,
                    "visible": self.panel.isVisible, "y": self.panel.frame.minY,
                    "x": self.panel.frame.minX, "top": (NSScreen.screens.first?.frame.maxY ?? 0) - self.panel.frame.maxY,
                    "width": self.panel.frame.width, "height": self.panel.frame.height]
                if let data = try? JSONSerialization.data(withJSONObject: state) {
                    try? data.write(to: Backend.support.appendingPathComponent("hud-check.json"), options: .atomic)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.model.update(.preparing, "Visual QA; no microphone capture")
                self.model.audioLevel = 0.65
                self.model.update(.recording, "Visual QA; no microphone capture")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { report("recording") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.model.processingProgress = "≈42% · ~8s"
                    self.model.update(.transcribing, "Visual QA: estimated progress")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { report("processing") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.model.update(.success, "Visual QA completion")
                    report("flash")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.27 / WaveformMotion.completionSpeed) { report("collapse") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        report("hidden")
                        self.model.update(.idle, "Visual QA complete")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        if checkPermission() { stopPermissionPolling() }
        rebuildMenu()
    }
    func rebuildMenu() {
        menu.removeAllItems()
        let summary: String
        switch model.phase {
        case .idle: summary = model.insertionPermission.granted ? "\(model.mode.title): ready" : "\(model.mode.title): Accessibility required"
        case .preparing: summary = "\(model.mode.title): preparing…"
        case .recording: summary = "\(model.mode.title): listening"
        case .transcribing: summary = model.processingProgress.isEmpty ? "\(model.mode.title): transcribing…" : "\(model.mode.title): " + model.processingProgress
        case .success: summary = model.insertionWasAutomatic ? "\(model.mode.title): paste sent" : "\(model.mode.title): copied—press ⌘V"
        case .failed: summary = "\(model.mode.title): needs attention…"
        }
        let needsPermission = !model.insertionPermission.granted
        let header = NSMenuItem(title: summary, action: needsPermission ? #selector(accessibility) : model.phase == .failed ? #selector(showCaptureError) : nil, keyEquivalent: "")
        header.target = self
        header.isEnabled = needsPermission || model.phase == .failed
        header.toolTip = model.message
        header.attributedTitle = NSAttributedString(string: summary, attributes: [.foregroundColor: model.phase == .failed || needsPermission ? NSColor.systemOrange : NSColor.systemGreen])
        menu.addItem(header); menu.addItem(.separator())
        item(model.phase == .recording ? "Finish \(model.mode.title)" : "Start \(model.mode.title)", "waveform", #selector(toggle), enabled: !model.busy, key: "n", modifiers: [.control, .command])
        if model.phase == .recording || model.busy { item("Stop and Keep Audio", "pause.circle", #selector(cancel)) }
        if model.phase == .failed, model.savedSession != nil { item("Retry Saved Recording", "arrow.clockwise", #selector(retry)) }
        if model.savedSession != nil, !model.busy, model.phase != .recording {
            item("Delete This Saved Recording…", "trash", #selector(deleteSaved))
        }
        let modes = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(); modeMenu.autoenablesItems = false
        for mode in RecognitionMode.allCases {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = mode.rawValue
            entry.state = model.mode == mode ? .on : .off
            entry.isEnabled = canChangeMode
            modeMenu.addItem(entry)
        }
        modes.submenu = modeMenu; menu.addItem(modes)
        let microphones = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphones.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        let devices = NSMenu(); devices.autoenablesItems = false
        let selected = try? model.backend.configuration(requiresModel: false).preferredMicrophone
        for device in Recorder.devices() {
            let entry = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = device.name
            entry.state = device.name == selected ? .on : .off
            entry.isEnabled = canChangeMode
            devices.addItem(entry)
        }
        devices.addItem(.separator())
        let fallback = NSMenuItem(title: "Falls back to MacBook microphone", action: nil, keyEquivalent: "")
        fallback.isEnabled = false; devices.addItem(fallback)
        microphones.submenu = devices; menu.addItem(microphones)
        menu.addItem(.separator())
        if !model.lastText.isEmpty { item(model.lastTranscriptIncomplete ? "Copy Recognized Text (Incomplete)" : "Copy Last Transcript", "doc.on.doc", #selector(copyLast)) }
        menu.addItem(modelMenus.modelItem())
        item("Open Saved Recordings", "folder", #selector(savedRecordings))
        item("Open Vella Files", "folder", #selector(files))
        menu.addItem(.separator())
        item("Support the developer…", "heart", #selector(supportDeveloper))
        item("Quit Vella", "power", #selector(quit), key: "q", modifiers: [.command])
    }
    private func item(_ title: String, _ icon: String, _ action: Selector, enabled: Bool = true, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.isEnabled = enabled; entry.keyEquivalentModifierMask = modifiers
        entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        menu.addItem(entry)
    }
    // Wait until native menu tracking ends before microphone capture or opening panels.
    @objc private func toggle() { DispatchQueue.main.async { self.checkPermission(); self.model.toggle() } }
    @objc private func cancel() { model.cancel() }
    @objc private func retry() { DispatchQueue.main.async { self.model.retry() } }
    @objc private func savedRecordings() {
        DispatchQueue.main.async {
            do {
                let folder = RecordingSession.root
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard NSWorkspace.shared.open(folder) else { throw VellaError.message("Could not open the saved recordings folder in Finder.") }
            } catch { NSAlert(error: error).runModal() }
        }
    }
    @objc private func deleteSaved() {
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = "Delete this saved recording?"
            alert.informativeText = "This permanently deletes its audio and saved transcript. Other recordings are untouched."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
            if alert.runModal() == .alertSecondButtonReturn {
                do { try self.model.deleteSavedRecording() }
                catch { self.model.update(.failed, error.localizedDescription) }
            }
        }
    }
    @objc private func copyLast() { model.copyLast() }
    @objc private func accessibility() { model.accessibility(); beginPermissionPolling() }
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard canChangeMode, let raw = sender.representedObject as? String, let mode = RecognitionMode(rawValue: raw) else { return }
        do { try model.selectMode(mode); rebuildMenu() }
        catch { model.update(.failed, error.localizedDescription) }
    }
    @objc private func selectMicrophone(_ sender: NSMenuItem) { if let name = sender.representedObject as? String { model.chooseMicrophone(name) } }
    @objc private func files() { NSWorkspace.shared.open(Backend.support) }
    @objc private func supportDeveloper() {
        DispatchQueue.main.async {
            let url = URL(string: "https://github.com/sponsors/TobyNoSkillSon")!
            if !self.openExternalURL(url) {
                let alert = NSAlert()
                alert.messageText = "Could not open GitHub Sponsors"
                alert.informativeText = url.absoluteString
                alert.runModal()
            }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func details() {
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = self.model.title
            alert.informativeText = self.model.message + "\n\n" + self.model.backendStatus
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }

    func refresh() {
        status.button?.toolTip = "Vella · " + model.title
        dismissal?.cancel(); visibilityRevision += 1
        if model.phase == .idle { model.hudVisible = false; panel.orderOut(nil); return }
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let rect = screen?.visibleFrame {
                let destination = NSRect(x: rect.midX - HUDView.panelSize.width / 2, y: rect.minY + 8,
                                         width: HUDView.panelSize.width, height: HUDView.panelSize.height)
                panel.setFrame(destination, display: false)
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }
        model.hudVisible = panel.isVisible
        if model.phase == .success || model.phase == .failed {
            let revision = visibilityRevision
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.visibilityRevision == revision else { return }
                self.model.hudVisible = false
                self.panel.orderOut(nil)
            }
            dismissal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (model.phase == .failed ? HUDView.failureDwell : HUDView.successDwell), execute: work)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.phase == .recording || model.busy || librariesBusy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Stop dictation and quit?"
        alert.informativeText = "Saved audio and completed text will be kept. Unfinished text will not be inserted."
        alert.addButton(withTitle: "Keep Dictating"); alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if model.captureIsFinalizing {
            Task {
                await model.shutdownAfterCaptureDrain()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let applicationFocusObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationFocusObserver) }
        dismissal?.cancel(); stopPermissionPolling(); model.hudVisible = false
        dictationMenus.library.shutdown(); streamingMenus.library.shutdown(); model.shutdown()
    }
}
