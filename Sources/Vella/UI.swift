import AppKit
import SwiftUI
import QuartzCore
import ServiceManagement
import VellaCore

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model: Model
    var openExternalURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    let releaseUpdates: ReleaseUpdateChecker
    private(set) var shortcutManager: ShortcutManager
    init(model: Model? = nil, releaseUpdates: ReleaseUpdateChecker? = nil, shortcutManager: ShortcutManager? = nil, shortcutStoreURL: URL? = nil) {
        let resolved = model ?? Model()
        self.model = resolved
        self.releaseUpdates = releaseUpdates ?? ReleaseUpdateChecker()
        if let shortcutManager {
            self.shortcutManager = shortcutManager
        } else if let url = shortcutStoreURL {
            // Synthetic file-backed store (tests): isolated persistence through the
            // real factory path without touching the home directory.
            self.shortcutManager = ShortcutManager(model: resolved, store: ShortcutStore(fileURL: url))
        } else {
            // Memory-only until launch swaps in the production file-backed store,
            // so unit tests never touch ~/Library through this factory.
            self.shortcutManager = ShortcutManager(model: resolved, store: ShortcutStore(fileURL: nil))
        }
        super.init()
        // Inline confirmation updates while tracking (no rebuild, identities kept).
        self.shortcutManager.onMouseConfirmationChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshTrackedMouseConfirmation() }
        }
    }
    /// One Models table for both modes (Dictation and Streaming sections).
    lazy var modelsMenu = makeModelsMenu()
    private var dictationLibrary: ModelLibrary { modelsMenu.controller.dictation }
    private var streamingLibrary: ModelLibrary { modelsMenu.controller.streaming }
    private func library(_ mode: RecognitionMode) -> ModelLibrary { mode == .dictation ? dictationLibrary : streamingLibrary }
    private var librariesBusy: Bool {
        [dictationLibrary, streamingLibrary].contains { $0.busy || $0.calibration.isRunning }
    }
    private var canChangeMode: Bool { model.phase != .recording && !model.busy && !librariesBusy }
    /// Keep Hot and Memory values and their apply action (the runtime's settings); nil = defaults, not yet wired.
    var menuSettings: MenuSettingsSource = DefaultMenuSettings()
    /// The fact line under the header (e.g. `2 models loaded · 1.9 GB in memory`); nil = no line.
    var factLine: () -> String? = { nil }
    /// First dictation without a model: the recording is kept and the menu offers one `Get <model> (<size>)` row.
    /// The runtime sets it (vr-runtime `Model.pendingModelRequest`); nil = no pending request.
    var pendingModelRow: () -> (title: String, help: String)? = { nil }
    var getPendingModel: () -> Void = {}
    /// Restart Worker: the runtime's restart; nil = stop the workers (the next dictation starts them again).
    var restartWorkers: (() -> Void)?
    /// `controller`: an isolated Models controller (tests); the wiring below is the real one either way.
    func makeModelsMenu(controller: ModelsController? = nil) -> ModelsMenu {
        let menus = ModelsMenu(controller: controller)
        for mode in RecognitionMode.allCases {
            let library = menus.controller.library(mode)
            library.mayChangeModel = { [weak self] in
                guard let self else { return false }
                let other = self.library(mode == .dictation ? .streaming : .dictation)
                return self.model.phase != .recording && !self.model.busy && !other.busy && !other.calibration.isRunning
            }
            library.onUse = { [weak self] in self?.model.stopWorkers() }
            // A download no longer stops the workers: models kept hot stay loaded while another one downloads.
            library.prepareForCalibration = { [weak self] in try await self?.model.releaseWorkers() }
        }
        // Progress estimate before local calibration: the measured speed of the selected precision (benchmarks.json).
        model.referenceSpeed = { [weak menus] path in
            guard let controller = menus?.controller,
                  let id = controller.dictation.installed.first(where: { $0.value.path == path })?.key,
                  let (family, precision) = controller.catalog.locate(variant: id),
                  let speed = controller.result(family, precision)?.speed_x, speed.isFinite, speed > 0 else { return nil }
            return speed
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
    private var spaceObserver: NSObjectProtocol?
    private var settingsMenuIsTracking = false
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
            model.update(.idle, "Automatic insertion is enabled. Press \(model.shortcutHint) in your text field.")
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
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.activeSpaceChanged() }
            }
        configureHUDPanel()
        model.onChange = { [weak self] in self?.refresh() }
        rebuildMenu()
        releaseUpdates.onChange = { [weak self] in self?.refreshUpdateIndicator() }
        refreshUpdateIndicator()
        if !CommandLine.arguments.contains("--check-hud") {
            model.onTranscriptionCompleted = { [weak self] in
                Task { [weak self] in await self?.releaseUpdates.checkAfterUse() }
            }
        }
        shortcutManager = ShortcutManager(model: model, store: ShortcutStore(fileURL: ShortcutManager.shortcutsFileURL))
        shortcutManager.menuCancel = { [weak self] in self?.menu.cancelTracking() }
        shortcutManager.onMouseConfirmationChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshTrackedMouseConfirmation() }
        }
        shortcutManager.permissionCheck = { [weak self] in
            guard let self else { return false }
            self.menu.cancelTracking()
            self.checkPermission()
            return self.model.ensureAutomaticInsertion()
        }
        shortcutManager.beginObservingSystemInterruptions()
        // Production file-backed shortcuts owned by shortcutManager.store.
        // Never prompts at startup; event-tap failures surface as menu errors only.
        shortcutManager.reloadFromStore()
        if !shortcutManager.registerStoredOrDefault() {
            // Preserve the legacy conflict message when the default chord cannot register.
            if !shortcutManager.requiresEventTap {
                model.update(.failed, shortcutManager.lastError ?? "⌃⌘N is already reserved or could not be registered. Free it in the other application, then restart Vella.")
            }
        }
        rebuildMenu()
        // Prepare accessibility on activation; Dictation chooses its field at Finish.
        AccessibilityFocus.prepare(NSWorkspace.shared.frontmostApplication)
        applicationFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in AccessibilityFocus.prepare(app) }
            }
        // Activation is owned by shortcutManager (Carbon press/release, no new permissions).
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

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { settingsMenuIsTracking = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu {
            settingsMenuIsTracking = false
            // Root close/Escape cancels bounded confirmation; prior binding stays.
            shortcutManager.cancelMouseButtonConfirmation()
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu, !settingsMenuIsTracking else { return }
        if checkPermission() { stopPermissionPolling() }
        rebuildMenu()
    }
    func rebuildMenu() {
        menu.removeAllItems()
        var summary: String
        switch model.phase {
        case .idle: summary = model.insertionPermission.granted ? "\(model.mode.title): ready" : "\(model.mode.title): Accessibility required"
        case .preparing: summary = "\(model.mode.title): preparing…"
        case .recording: summary = "\(model.mode.title): listening"
        case .transcribing: summary = model.processingProgress.isEmpty ? "\(model.mode.title): transcribing…" : "\(model.mode.title): " + model.processingProgress
        case .success: summary = model.insertionWasAutomatic ? "\(model.mode.title): paste sent" : "\(model.mode.title): copied—press ⌘V"
        case .failed: summary = "\(model.mode.title): needs attention…"
        }
        // The loaded model is the fact most worth knowing before opening Models.
        if let activeModel = modelsMenu.controller.activeLabel(model.mode) { summary += " · \(activeModel)" }
        let pending = pendingModelRow()
        if pending != nil, model.phase == .idle || model.phase == .failed { summary = "\(model.mode.title): recording kept, needs a model" }
        let needsPermission = !model.insertionPermission.granted
        let header = NSMenuItem(title: summary, action: needsPermission ? #selector(accessibility) : model.phase == .failed ? #selector(showCaptureError) : nil, keyEquivalent: "")
        header.target = self
        header.isEnabled = needsPermission || model.phase == .failed
        // Tooltip only when the header has more to say (errors, permission, progress), not the idle greeting.
        header.toolTip = model.phase == .idle && !needsPermission ? pending?.help : model.message
        header.attributedTitle = NSAttributedString(string: summary, attributes: [.foregroundColor: model.phase == .failed || needsPermission || pending != nil ? NSColor.systemOrange : NSColor.systemGreen])
        menu.addItem(header)
        if let fact = factLine() {
            let line = NSMenuItem(title: fact, action: nil, keyEquivalent: ""); line.isEnabled = false
            menu.addItem(line)
        }
        if let pending {
            item(pending.title, "arrow.down.circle", #selector(getPending), help: pending.help)
        }
        menu.addItem(.separator())
        let workingShortcut = shortcutManager.isUsingFallback ? (shortcutManager.activeConfiguration ?? .default) : shortcutManager.configuration
        let startKey = ShortcutManager.menuKeyEquivalent(for: workingShortcut)
        item(model.phase == .recording ? "Finish \(model.mode.title)" : "Start \(model.mode.title)", "waveform", #selector(toggle), enabled: !model.busy, key: startKey.key, modifiers: startKey.modifiers)
        if model.phase == .recording || model.busy { item("Stop and Keep Audio", "pause.circle", #selector(cancel)) }
        if model.phase == .failed, model.savedSession != nil { item("Retry Saved Recording", "arrow.clockwise", #selector(retry)) }
        if model.savedSession != nil, !model.busy, model.phase != .recording {
            item("Delete This Saved Recording…", "trash", #selector(deleteSaved))
        }
        let modes = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modes.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil); modes.toolTip = modeHelp
        let modeMenu = NSMenu(); modeMenu.autoenablesItems = false
        for mode in RecognitionMode.allCases {
            let entry = SettingsMenuItem(title: mode.title, target: self, action: #selector(selectMode(_:)))
            entry.target = self; entry.representedObject = mode.rawValue
            entry.state = model.mode == mode ? .on : .off
            entry.isEnabled = canChangeMode; entry.synchronize()
            modeMenu.addItem(entry)
        }
        modes.submenu = modeMenu; menu.addItem(modes)
        let microphones = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphones.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil); microphones.toolTip = microphoneHelp
        let devices = NSMenu(); devices.autoenablesItems = false
        let selected = try? model.backend.configuration(requiresModel: false).preferredMicrophone
        for device in Recorder.devices() {
            let entry = SettingsMenuItem(title: device.name, target: self, action: #selector(selectMicrophone(_:)))
            entry.target = self; entry.representedObject = device.name
            entry.state = device.name == selected ? .on : .off
            entry.isEnabled = canChangeMode; entry.synchronize()
            devices.addItem(entry)
        }
        devices.addItem(.separator())
        let fallback = NSMenuItem(title: "Falls back to MacBook microphone", action: nil, keyEquivalent: "")
        fallback.isEnabled = false; devices.addItem(fallback)
        microphones.submenu = devices; menu.addItem(microphones)
        // Activation customization lives immediately below Microphone (compact native menu preserved).
        menu.addItem(ShortcutMenuFactory.shortcutsItem(manager: shortcutManager, model: model, target: self,
            selectBehavior: #selector(selectShortcutBehavior(_:)), recordKeys: #selector(recordShortcutKeys),
            cancelCapture: #selector(cancelShortcutCapture), selectModifier: #selector(selectShortcutModifier(_:)),
            selectMouse: #selector(selectShortcutMouse(_:)), resetDefault: #selector(resetShortcutDefault),
            openSettings: #selector(accessibility)))
        menu.items.last?.toolTip = menu.items.last?.toolTip ?? shortcutsHelp
        menu.addItem(.separator())
        // Which models are in memory: the model, how long it stays hot, what happens when memory is short.
        menu.addItem(modelsMenu.modelItem())
        menu.addItem(settingsSubmenu("Keep Hot", "flame", keepHotEntries(manualIdle: menuSettings.manualIdleMinutes, onDemandIdle: menuSettings.onDemandIdleMinutes), help: keepHotHelp))
        menu.addItem(settingsSubmenu("Memory", "memorychip", memoryEntries(allowSwap: menuSettings.allowSwap, availableMB: menuSettings.availableMB, lastEvicted: menuSettings.lastEvicted), help: memoryHelp))
        menu.addItem(.separator())
        if !model.lastText.isEmpty { item(model.lastTranscriptIncomplete ? "Copy Recognized Text (Incomplete)" : "Copy Last Transcript", "doc.on.doc", #selector(copyLast), help: copyLastHelp) }
        item("Open Saved Recordings", "folder", #selector(savedRecordings), help: "Opens the folder of saved recordings and their transcripts.")
        item("Open Vella Files", "folder", #selector(files), help: openFilesHelp)
        item("Restart Worker", "arrow.clockwise", #selector(restartWorker), enabled: model.phase != .recording && !model.busy, help: restartWorkerHelp)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.image = NSImage(systemSymbolName: "power.circle", accessibilityDescription: nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        if let update = releaseUpdates.available {
            item("Update available — \(update.tag)…", "arrow.down.circle", #selector(openReleaseUpdate))
            if let entry = menu.items.last {
                entry.attributedTitle = NSAttributedString(string: entry.title, attributes: [.foregroundColor: NSColor.systemYellow])
                entry.image = entry.image?.withSymbolConfiguration(.init(paletteColors: [.systemYellow]))
            }
        }
        item("Support the developer…", "heart", #selector(supportDeveloper), help: supportHelp)
        item("Quit Vella", "power", #selector(quit), key: "q", modifiers: [.command])
    }
    private func item(_ title: String, _ icon: String, _ action: Selector, enabled: Bool = true, key: String = "", modifiers: NSEvent.ModifierFlags = [], help: String? = nil) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.isEnabled = enabled; entry.keyEquivalentModifierMask = modifiers; entry.toolTip = help
        entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        menu.addItem(entry)
    }
    // Wait until native menu tracking ends before microphone capture or opening panels.
    @objc private func toggle() {
        // Starting capture makes settings busy: cancel bounded confirmation first.
        shortcutManager.cancelMouseButtonConfirmation()
        DispatchQueue.main.async { self.checkPermission(); self.model.toggle() }
    }
    @objc private func cancel() {
        shortcutManager.cancelMouseButtonConfirmation()
        model.cancel()
    }
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
    @objc private func getPending() { getPendingModel() }
    @objc private func restartWorker() { if let restartWorkers { restartWorkers() } else { model.stopWorkers() } }
    /// Keep Hot / Memory submenu from VellaCore's entries (section headers, checkmarked choices, short captions).
    private func settingsSubmenu(_ title: String, _ icon: String, _ entries: [SettingsEntry], help: String) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil); root.toolTip = help
        let sub = NSMenu(); sub.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .header(let text, let help):
                let header = NSMenuItem.sectionHeader(title: text); header.toolTip = help
                sub.addItem(header)
            case .separator: sub.addItem(.separator())
            case .caption(let text):
                let line = NSMenuItem(title: text, action: nil, keyEquivalent: ""); line.isEnabled = false
                sub.addItem(line)
            case .choice(let text, let checked, let action, let help):
                let choice = NSMenuItem(title: text, action: #selector(chooseSetting(_:)), keyEquivalent: "")
                choice.target = self; choice.state = checked ? .on : .off; choice.toolTip = help
                choice.representedObject = SettingsActionBox(action)
                sub.addItem(choice)
            }
        }
        root.submenu = sub
        return root
    }
    @objc private func chooseSetting(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SettingsActionBox else { return }
        menuSettings.apply(box.action)
        rebuildMenuIfIdle()
    }
    private func rebuildMenuIfIdle() { if !settingsMenuIsTracking { rebuildMenu() } }
    @objc private func accessibility() { model.accessibility(); beginPermissionPolling() }
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard canChangeMode, let raw = sender.representedObject as? String, let mode = RecognitionMode(rawValue: raw) else { return }
        do {
            try model.selectMode(mode)
            // Keep the tracked root and Mode submenu alive. Only update their
            // contents and replace the inactive Models submenu for the new mode.
            for entry in sender.menu?.items ?? [] {
                entry.state = entry.representedObject as? String == mode.rawValue ? .on : .off
                (entry as? SettingsMenuItem)?.synchronize()
            }
            let summary = "\(mode.title): " + (model.insertionPermission.granted ? "ready" : "Accessibility required")
            if let header = menu.items.first {
                header.title = summary; header.toolTip = model.message
                header.action = model.insertionPermission.granted ? nil : #selector(accessibility)
                header.isEnabled = !model.insertionPermission.granted
                header.attributedTitle = NSAttributedString(string: summary, attributes: [.foregroundColor: model.insertionPermission.granted ? NSColor.systemGreen : NSColor.systemOrange])
            }
            menu.items.first { $0.action == #selector(toggle) }?.title = "Start \(mode.title)"
            // One table holds both modes; nothing to replace.
        }
        catch { model.update(.failed, error.localizedDescription) }
    }
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard canChangeMode, let name = sender.representedObject as? String else { return }
        model.chooseMicrophone(name)
        let selected = try? model.backend.configuration(requiresModel: false).preferredMicrophone
        for entry in sender.menu?.items ?? [] {
            entry.state = entry.representedObject as? String == selected ? .on : .off
            (entry as? SettingsMenuItem)?.synchronize()
        }
    }
    // MARK: Shortcuts submenu (activation customization; disabled while busy).
    private var canChangeShortcuts: Bool { shortcutManager.canEdit && !model.busy && model.phase != .recording }
    /// The Shortcuts submenu owning sender (sender may live in a nested picker).
    private func shortcutsMenu(containing sender: NSMenuItem) -> NSMenu? {
        if let m = sender.menu, m.items.first?.title.hasPrefix("Current:") == true { return m }
        if let sup = sender.menu?.supermenu, sup.items.first?.title.hasPrefix("Current:") == true { return sup }
        return menu.item(withTitle: "Shortcuts")?.submenu
    }
    /// Refresh shortcut labels, equivalents and status without replacing tracked items.
    private func refreshShortcutsMenuInPlace(_ shortcutsMenu: NSMenu) {
        let working = shortcutManager.isUsingFallback ? (shortcutManager.activeConfiguration ?? .default) : shortcutManager.configuration
        let equivalent = ShortcutManager.menuKeyEquivalent(for: working)
        if let start = menu.items.first(where: { $0.action == #selector(toggle) }) {
            start.keyEquivalent = equivalent.key
            start.keyEquivalentModifierMask = equivalent.modifiers
        }
        ShortcutMenuFactory.refreshStatus(in: shortcutsMenu, manager: shortcutManager)
        if let current = shortcutsMenu.items.first {
            var title = "Current: \(shortcutManager.currentLabel)"
            if shortcutManager.isUsingFallback {
                let working = shortcutManager.activeConfiguration ?? .default
                title += " (using \(ShortcutLabels.triggerDisplay(working.trigger)))"
            }
            current.title = title
        }
        for entry in shortcutsMenu.items {
            if entry.action == #selector(selectShortcutBehavior(_:)) {
                entry.state = entry.representedObject as? String == shortcutManager.configuration.behavior.rawValue ? .on : .off
                (entry as? SettingsMenuItem)?.synchronize()
            }
            guard let sub = entry.submenu else { continue }
            if entry.title == "Modifier-Only" {
                for mod in sub.items {
                    guard let raw = mod.representedObject as? String else { continue }
                    let parts = raw.split(separator: ":").map(String.init)
                    guard parts.count == 2, let k = ModifierKey(rawValue: parts[0]),
                          let s = ModifierSide(rawValue: parts[1]) else { continue }
                    if case .modifierOnly(let ck, let cs) = shortcutManager.configuration.trigger, ck == k, (k == .function || cs == s) {
                        mod.state = .on
                    } else { mod.state = .off }
                    (mod as? SettingsMenuItem)?.synchronize()
                }
            } else if entry.title == "Mouse Button" {
                for m in sub.items {
                    guard let raw = m.representedObject as? String, let v = Int(raw),
                          let b = MouseButton(rawValue: v) else { continue }
                    if case .mouseButton(let cb) = shortcutManager.configuration.trigger, cb == b {
                        m.state = .on
                    } else { m.state = .off }
                    (m as? SettingsMenuItem)?.synchronize()
                    // Bounded confirmation renders inline in the same row (red).
                    // Same instance helper as factory; updates during tracking.
                    if let settings = m as? SettingsMenuItem {
                        if shortcutManager.pendingMouseButton == b {
                            settings.showConfirmationPrompt(shortcutManager.mouseConfirmationRowText(for: b))
                        } else if shortcutManager.mouseConfirmationErrorButton == b, let err = shortcutManager.mouseConfirmationError {
                            settings.showConfirmationError(err, toolTip: shortcutManager.mouseConfirmationRowToolTip(for: b))
                        } else {
                            settings.restoreBaseTitle()
                        }
                    }
                }
            }
        }
    }
    @objc private func selectShortcutBehavior(_ sender: NSMenuItem) {
        guard canChangeShortcuts, let raw = sender.representedObject as? String,
              let behavior = ShortcutBehavior(rawValue: raw) else { return }
        guard shortcutManager.applyBehavior(behavior) else {
            if let shortcutsMenu = shortcutsMenu(containing: sender) { refreshShortcutsMenuInPlace(shortcutsMenu) }
            return
        }
        // Keep tracked menu/items alive like selectMode: update states in place.
        if let shortcutsMenu = shortcutsMenu(containing: sender) { refreshShortcutsMenuInPlace(shortcutsMenu) }
    }
    @objc private func recordShortcutKeys() {
        guard canChangeShortcuts else { return }
        shortcutManager.beginKeyCapture()
        // The transient panel owns the keyboard now; never rebuild tracked menus here.
    }
    @objc private func cancelShortcutCapture() {
        shortcutManager.cancelKeyCapture()
    }
    @objc private func selectShortcutModifier(_ sender: NSMenuItem) {
        guard canChangeShortcuts, let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let key = ModifierKey(rawValue: parts[0]),
              let side = ModifierSide(rawValue: parts[1]) else { return }
        _ = shortcutManager.applyModifierOnly(key: key, side: side)
        if let shortcutsMenu = shortcutsMenu(containing: sender) { refreshShortcutsMenuInPlace(shortcutsMenu) }
    }
    @objc private func selectShortcutMouse(_ sender: NSMenuItem) {
        guard canChangeShortcuts, let raw = sender.representedObject as? String,
              let int = Int(raw), let button = MouseButton(rawValue: int) else { return }
        // Bounded confirmation: never applies immediately; same row prompts.
        _ = shortcutManager.beginMouseButtonConfirmation(button)
        if let shortcutsMenu = shortcutsMenu(containing: sender) { refreshShortcutsMenuInPlace(shortcutsMenu) }
    }
    @objc private func resetShortcutDefault() {
        guard canChangeShortcuts else { return }
        shortcutManager.resetToDefault()
        if let shortcutsMenu = menu.item(withTitle: "Shortcuts")?.submenu { refreshShortcutsMenuInPlace(shortcutsMenu) }
    }
    /// Async inline refresh for confirmation monitor/timer callbacks while tracking.
    /// Preserves tracked identities; never rebuilds menus here.
    private func refreshTrackedMouseConfirmation() {
        guard let submenu = menu.item(withTitle: "Shortcuts")?.submenu else { return }
        refreshShortcutsMenuInPlace(submenu)
    }
    @objc private func files() { NSWorkspace.shared.open(Backend.support) }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSAlert(error: error).runModal() }
        rebuildMenu()
    }
    @objc private func openReleaseUpdate() {
        guard let url = releaseUpdates.available?.url else { return }
        DispatchQueue.main.async {
            if !self.openExternalURL(url) {
                let alert = NSAlert()
                alert.messageText = "Could not open the release page"
                alert.informativeText = url.absoluteString
                alert.runModal()
            }
        }
    }
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
    func configureHUDPanel() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: HUDView.panelSize.width, height: HUDView.panelSize.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
        panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
    }

    func activeSpaceChanged() {
        menu.cancelTracking()
        guard panel != nil, [.preparing, .recording, .transcribing].contains(model.phase) else { return }
        // Restore presentation only. System occlusion is not an opacity command:
        // a transparent window may never receive the "visible again" event.
        refresh()
    }

    func restoreHUDOpacity() {
        panel.alphaValue = 1
        panel.contentView?.alphaValue = 1
    }

    func refreshUpdateIndicator() {
        status?.button?.contentTintColor = releaseUpdates.available == nil ? nil : .systemYellow
        // Do not rebuild a menu while the user is tracking it. Next opening reads the cache.
        if !settingsMenuIsTracking { rebuildMenu() }
    }

    func refresh() {
        // Bounded mouse confirmation cancels when capture turns busy;
        // prior binding stays. Before the panel guard so panel-nil tests still cancel.
        if shortcutManager.isConfirmingMouseButton, model.phase == .recording || model.busy {
            shortcutManager.cancelMouseButtonConfirmation()
        }
        status?.button?.toolTip = "Vella · " + model.title
        dismissal?.cancel(); visibilityRevision += 1
        guard panel != nil else { return }
        if model.phase == .idle { model.hudVisible = false; panel.orderOut(nil); return }
        restoreHUDOpacity()
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
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        dismissal?.cancel(); stopPermissionPolling(); model.hudVisible = false
        dictationLibrary.shutdown(); streamingLibrary.shutdown(); model.shutdown()
    }
}


/// Keep Hot and Memory values for the menu and the action that applies a choice. The runtime implements it.
@MainActor protocol MenuSettingsSource: AnyObject {
    var manualIdleMinutes: Int { get }
    var onDemandIdleMinutes: Int { get }
    var allowSwap: Bool { get }
    var availableMB: Double? { get }
    var lastEvicted: String? { get }
    func apply(_ action: SettingsAction)
}

/// Defaults held in memory until the runtime's settings are attached (also the render harness's source).
@MainActor final class DefaultMenuSettings: MenuSettingsSource {
    var manualIdleMinutes = defaultManualIdleMinutes
    var onDemandIdleMinutes = defaultOnDemandIdleMinutes
    var allowSwap = false
    var availableMB: Double?
    var lastEvicted: String?
    init(manualIdleMinutes: Int = defaultManualIdleMinutes, onDemandIdleMinutes: Int = defaultOnDemandIdleMinutes, allowSwap: Bool = false,
         availableMB: Double? = nil, lastEvicted: String? = nil) {
        self.manualIdleMinutes = manualIdleMinutes; self.onDemandIdleMinutes = onDemandIdleMinutes; self.allowSwap = allowSwap
        self.availableMB = availableMB; self.lastEvicted = lastEvicted
    }
    func apply(_ action: SettingsAction) {
        switch action {
        case .keepHot(.manual, let minutes): manualIdleMinutes = minutes
        case .keepHot(.onDemand, let minutes): onDemandIdleMinutes = minutes
        case .memory(let allow): allowSwap = allow
        }
    }
}

/// Carries a VellaCore settings action through NSMenuItem.representedObject.
final class SettingsActionBox: NSObject {
    let action: SettingsAction
    init(_ action: SettingsAction) { self.action = action }
}
