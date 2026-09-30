import AppKit
import VellaCore
import VellaUpdate

/// Updates from GitHub Releases. Checks at launch when due and every 24 hours (one request to the releases API;
/// nothing else is sent). A newer release shows an orange "Update to X…" item under "Support the developer…".
/// Update Now is refused while Vella is busy (a dictation that is not idle, a model loading, a download or calibration,
/// an API transcription). Otherwise it downloads the release, checks its SHA-256, archive entries, bundle and version,
/// and that it is signed like this app; waits until Vella is idle if it became busy meanwhile; then hands the install
/// to `VellaInstallTool update` (the app has to quit for the swap) and quits. That process swaps the app with the
/// previous one kept aside, relaunches it and waits until it is ready; a failure restores this version and the
/// relaunched app reports why (update-result.json).
@MainActor final class UpdateController: NSObject {
    private(set) var machine = UpdateMachine()
    var onChange: (() -> Void)?
    let current: SemanticVersion?
    /// Why an update cannot start now, or nil when Vella is idle. The app delegate wires it.
    var blocker: () -> String? = { nil }
    /// Only the released app checks: not tests, lab candidates with another bundle id, or `VELLA_UPDATE=0`.
    var enabled: Bool
    let defaults: UserDefaults
    var source: () throws -> UpdateSource = { try UpdateSource.fromEnvironment() }
    /// Tests answer requests from fixtures (URLProtocol subclasses); empty in the app.
    var protocolClasses: [AnyClass] = []
    var runningApp = Bundle.main.bundleURL
    var support = Backend.support
    var identity = IdentityCheck()
    /// Starts the installer and quits; replaced in tests.
    lazy var handOff: (StagedUpdate) throws -> Void = { [unowned self] in try self.startInstaller($0) }
    var quit: () -> Void = { NSApp.terminate(nil) }
    /// Alerts are modal; tests turn them off and read `machine.lastError`.
    var presentsAlerts = true
    /// A verified download waits this long for Vella to become idle.
    var idleWait: TimeInterval = 15 * 60
    var idlePollNanoseconds: UInt64 = 1_000_000_000
    private var checking = false
    private var timer: Timer?

    static let lastCheckKey = "update.lastCheck"
    static let offerKey = "update.offer"

    init(
        current: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        defaults: UserDefaults = .standard,
        enabled: Bool = Bundle.main.bundleIdentifier == "dev.vella.dictation" && ProcessInfo.processInfo.environment["VELLA_UPDATE"] != "0"
    ) {
        self.current = current.flatMap(SemanticVersion.init)
        self.defaults = defaults
        self.enabled = enabled && self.current != nil
    }

    func start() {
        guard enabled else { return }
        // Keys of the notice-only checker this replaces.
        defaults.removeObject(forKey: "releaseCheck.lastAttempt"); defaults.removeObject(forKey: "releaseCheck.availableTag")
        if let result = UpdateResult.take(support: support), !result.ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                showAlert(title: "Update to \(result.to) failed", result.message.hasSuffix(".") ? result.message : result.message + ".")
            }
        }
        restoreOffer()
        if updateCheckDue(last: defaults.object(forKey: Self.lastCheckKey) as? Date) { check() }
        // Hourly wake-up, 24-hour cadence: a Mac that slept through the due time checks soon after it wakes.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, updateCheckDue(last: self.defaults.object(forKey: Self.lastCheckKey) as? Date) else { return }
                self.check()
            }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    func check() { Task { await runCheck() } }

    func runCheck(now: Date = Date()) async {
        guard enabled, !checking, !machine.phase.busy, let current else { return }
        checking = true
        defer { checking = false; onChange?() }
        // Recorded before the request, so failures and relaunches never retry more than hourly.
        defaults.set(now, forKey: Self.lastCheckKey)
        do {
            let release = try await UpdateClient(source: try source(), protocolClasses: protocolClasses).check(current: current)
            if machine.handle(.checked(release)) { saveOffer(release) }
        } catch {
            machine.handle(.checkFailed((error as? UpdateError)?.message ?? error.localizedDescription))
            defaults.set(now.addingTimeInterval(-23 * 3600), forKey: Self.lastCheckKey) // offline, say: again in about an hour
        }
    }

    /// A newer release found earlier stays offered across relaunches until this version catches up.
    private func restoreOffer() {
        guard let saved = defaults.dictionary(forKey: Self.offerKey), let tag = saved["tag"] as? String,
            let version = SemanticVersion(tag), let current
        else { return }
        let release = ReleaseInfo(tag: tag, version: version, name: saved["name"] as? String ?? "", body: saved["body"] as? String ?? "")
        if let offer = release.offer(to: current) { machine.handle(.checked(offer)) } else { defaults.removeObject(forKey: Self.offerKey) }
    }
    private func saveOffer(_ release: ReleaseInfo?) {
        if let release {
            defaults.set(["tag": release.tag, "name": release.name, "body": release.body], forKey: Self.offerKey)
        } else {
            defaults.removeObject(forKey: Self.offerKey)
        }
    }

    /// Render harness and tests.
    func preview(_ phase: UpdatePhase) { machine = UpdateMachine(phase: phase) }

    // MARK: Menu

    /// The orange item under "Support the developer…"; nil when this version is current.
    func menuItem() -> NSMenuItem? {
        guard let title = machine.phase.menuTitle else { return nil }
        let item = NSMenuItem(title: title, action: #selector(confirm), keyEquivalent: "")
        item.target = self
        item.isEnabled = !machine.phase.busy
        item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemOrange])
        item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        item.toolTip = machine.lastError.map { "Last attempt failed: \($0)" }
        return item
    }

    @objc func confirm() {
        guard case .available(let release) = machine.phase else { return }
        // Wait until menu tracking has ended before a modal alert.
        DispatchQueue.main.async { [self] in
            if let reason = blocker() { refuse(reason, release); return }
            NSApp.activate(ignoringOtherApps: true)
            if confirmation(release).runModal() == .alertFirstButtonReturn { Task { await install() } }
        }
    }

    /// The popup: version, short release notes, Update Now / Later.
    func confirmation(_ release: ReleaseInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update to Vella \(release.version)?"
        let notes = release.shortNotes()
        alert.informativeText =
            "You have \(current?.description ?? "an earlier version"). Settings, models and recordings are kept; Vella restarts."
            + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        return alert
    }

    private func refuse(_ reason: String, _ release: ReleaseInfo) {
        let message = "Vella is \(reason)"
        machine.handle(.failed(message)); onChange?()
        showAlert(title: "Update to \(release.version) not started", message + ". Update when it has finished; nothing was downloaded or changed.")
    }

    // MARK: Install

    func install() async {
        guard let current, case .available(let release) = machine.phase else { return }
        if let reason = blocker() { refuse(reason, release); return }
        guard machine.handle(.confirmed) else { return }
        onChange?()
        var staged: StagedUpdate?
        do {
            let client = UpdateClient(source: try source(), protocolClasses: protocolClasses)
            let prepared = try await Updater.prepare(release, client: client, runningApp: runningApp, identity: identity)
            staged = prepared
            machine.handle(.verified(busy: blocker() != nil)); onChange?()
            if case .waitingForIdle = machine.phase {
                let deadline = Date().addingTimeInterval(idleWait)
                while blocker() != nil && Date() < deadline { try await Task.sleep(nanoseconds: idlePollNanoseconds) }
                if let reason = blocker() { throw UpdateError("Vella is still \(reason), so the update was not installed. Try again when it has finished") }
                machine.handle(.becameIdle); onChange?()
            }
            // No suspension point between the idle check above and the hand-off: a dictation cannot start in between.
            try handOff(prepared)
        } catch {
            if let staged { try? FileManager.default.removeItem(atPath: staged.directory) }
            let reason = (error as? UpdateError)?.message ?? error.localizedDescription
            machine.handle(.failed(reason)); onChange?()
            showAlert(title: "Update to \(release.version) failed", reason + ". Vella \(current) is unchanged.")
        }
    }

    /// Starts this app's installer tool, which waits for this process to exit, then quits.
    private func startInstaller(_ staged: StagedUpdate) throws {
        let tool = runningApp.appendingPathComponent("Contents/Helpers/VellaInstallTool")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw UpdateError("The installer tool is missing from Vella.app; reinstall with scripts/install.sh")
        }
        let plan = InstallPlan(
            staged: staged, destination: runningApp.path, from: current?.description ?? "", waitForPID: getpid(),
            supportDirectory: support.path)
        let planURL = URL(fileURLWithPath: staged.directory).appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        let process = Process()
        process.executableURL = tool
        process.arguments = ["update", "--plan", planURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError("Could not start the installer: \(error.localizedDescription)") }
        quit()
        // terminate returns only when the quit was cancelled: stop the installer, so a later quit does not start it.
        if process.isRunning { process.terminate() }
        throw UpdateError("Vella did not quit, so the update was not installed")
    }

    private func showAlert(title: String, _ message: String) {
        guard presentsAlerts else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
