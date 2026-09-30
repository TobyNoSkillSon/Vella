import AppKit
import Carbon
import ApplicationServices
import IOKit.hidsystem
import VellaCore

// MARK: - Manager (MainActor, injected sinks for tests)

@MainActor
public final class ShortcutManager: ObservableObject {
    public let store: ShortcutStore
    public private(set) var engine: ShortcutEngine
    public private(set) var configuration: ShortcutConfiguration
    /// Actually registered binding (fallback default when desired cannot start).
    public private(set) var activeConfiguration: ShortcutConfiguration?
    public private(set) var isUsingFallback = false
    public private(set) var lastError: String?
    public private(set) var isCapturingKeys = false
    public var onAction: ((String) -> Void)? {
        didSet { actionBox.handler = onAction }
    }
    public var permissionCheck: (() -> Bool)?
    public var menuCancel: (() -> Void)?
    var carbon: CarbonShortcutRegistrar
    var eventTap: EventTapShortcutRegistrar
    private var activeRegistrar: (any ShortcutRegistrar)?
    private var injectedRegistrar: (any ShortcutRegistrar)?
    private weak var modelRef: Model?
    private let actionBox: ShortcutActionBox
    private var recorderPanel: ShortcutKeyRecorderPanel?
    private var interruptionObservers: [NSObjectProtocol] = []
    // MARK: Bounded mouse-button confirmation (prior config persists until commit on up)
    public private(set) var pendingMouseButton: MouseButton?
    public private(set) var mouseConfirmationError: String?
    public private(set) var mouseConfirmationErrorButton: MouseButton?
    /// Full diagnostic for the error tooltip (commit failures); nil when row text is complete.
    public private(set) var mouseConfirmationErrorDetail: String?
    /// Bounded wrong-button feedback label (e.g. "Button 5 detected"); nil when none.
    /// Never contains raw huge ints; unknown buttons map to "Other button detected".
    public private(set) var mouseConfirmationDetectedLabel: String?
    private var confirmationDownSeen = false
    private var confirmationGeneration: UInt64 = 0
    private var confirmationMonitor: (any MouseConfirmationMonitor)?
    private var confirmationTimer: (any MouseConfirmationTimer)?
    private var isCommittingConfirmation = false
    public var confirmationTimeoutInterval: TimeInterval = 10
    public var makeConfirmationMonitor: () -> any MouseConfirmationMonitor = { CGEventMouseConfirmationMonitor() }
    public var makeConfirmationTimer: () -> any MouseConfirmationTimer = { CommonRunLoopMouseConfirmationTimer() }
    /// Silent Accessibility check seam (production `AXIsProcessTrusted()`, no prompt).
    /// Tests inject true/false; no TCC prompts, no new scope.
    public var confirmationAccessCheck: () -> Bool = { AXIsProcessTrusted() }
    public var onMouseConfirmationChange: (() -> Void)?
    public var isConfirmingMouseButton: Bool { pendingMouseButton != nil }
    nonisolated public static var mouseConfirmationTimeoutMessage: String { "Button not detected" }
    /// Concise AX-denied claim, shown only when the silent check actually failed.
    nonisolated public static var mouseConfirmationAccessDeniedMessage: String { "Need Accessibility access" }
    /// Concise generic observation failure (tapCreate/source nil with AX true).
    /// Never claims AX denial; no remapping/hardware diagnosis.
    nonisolated public static var mouseConfirmationUnavailableMessage: String { "Could not observe input" }
    nonisolated public static func mouseConfirmationPrompt(for button: MouseButton) -> String {
        switch button {
        case .middle: return "Press middle button to confirm…"
        case .button3: return "Press side button 4 to confirm…"
        case .button4: return "Press side button 5 to confirm…"
        }
    }
    /// Compact commit-failure row text; full diagnostic stays in the tooltip.
    nonisolated public static var mouseConfirmationUnchangedMessage: String { "Shortcut unchanged" }
    /// Pre-reserved mouse row width at factory creation (longest prompt +
    /// feedback suffix + concise failures/compact unchanged). Inline updates
    /// never resize a tracking menu.
    public static func mouseConfirmationReservedWidth() -> CGFloat {
        // AppKit metrics; called from factory (MainActor) and tests.
        let font = NSFont.menuFont(ofSize: 0)
        var strings = [
            "Middle Click", "Side Button 4", "Side Button 5",
            mouseConfirmationPrompt(for: .middle),
            mouseConfirmationPrompt(for: .button3),
            mouseConfirmationPrompt(for: .button4),
            mouseConfirmationTimeoutMessage,
            mouseConfirmationAccessDeniedMessage,
            mouseConfirmationUnavailableMessage,
            mouseConfirmationUnchangedMessage,
        ]
        // Worst-case pending feedback suffixes (bounded labels only, no raw ints).
        let feedbacks = [
            "Middle button detected", "Button 4 detected", "Button 5 detected",
            "Left click detected", "Right click detected", "Other button detected",
        ] + (6...32).map { "Button \($0) detected" }
        for button in [MouseButton.middle, .button3, .button4] {
            let base = mouseConfirmationPrompt(for: button)
            strings.append(base)
            for fb in feedbacks { strings.append("\(base) (\(fb))") }
        }
        let widest = strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(180, widest + 52)
    }
    /// Instance row text used by BOTH factory creation and in-place tracking refresh.
    /// Pending row shows base prompt plus bounded "(X detected)" suffix when a
    /// wrong button was observed; otherwise the base prompt. No apply/cancel here.
    public func mouseConfirmationRowText(for button: MouseButton) -> String {
        let base = Self.mouseConfirmationPrompt(for: button)
        if pendingMouseButton == button, let feedback = mouseConfirmationDetectedLabel {
            return "\(base) (\(feedback))"
        }
        return base
    }
    /// Tooltip for mouse rows: full commit-failure diagnostic when the compact
    /// "Shortcut unchanged" row is shown; otherwise nil.
    public func mouseConfirmationRowToolTip(for button: MouseButton) -> String? {
        if mouseConfirmationErrorButton == button, mouseConfirmationError != nil {
            return mouseConfirmationErrorDetail
        }
        return nil
    }
    /// Bounded detected-button label for feedback; no raw huge ints, no key observation.
    nonisolated public static func mouseConfirmationDetectedLabel(forButtonNumber number: Int64, eventType: CGEventType) -> String {
        if eventType == .leftMouseDown { return "Left click detected" }
        if eventType == .rightMouseDown { return "Right click detected" }
        if number == 2 { return "Middle button detected" }
        if number == 3 { return "Button 4 detected" }
        if number == 4 { return "Button 5 detected" }
        if (5...31).contains(number) { return "Button \(number + 1) detected" }
        if number == 0 { return "Left click detected" }
        if number == 1 { return "Right click detected" }
        return "Other button detected"
    }

    public static var shortcutsFileURL: URL {
        Backend.support.appendingPathComponent("shortcuts.json")
    }
    public var currentLabel: String { ShortcutLabels.display(configuration) }
    public var activeLabel: String { ShortcutLabels.display(activeConfiguration ?? configuration) }
    public var requiresEventTap: Bool { configuration.trigger.requiresEventTap }
    public var canEdit: Bool { engine.canChangeSettings && !isCapturingKeys }

    /// Load the supplied store; the default is memory-only. Production launch
    /// supplies its file-backed store and explicitly reloads before registering.
    init(model: Model? = nil, store: ShortcutStore? = nil) {
        let resolved = store ?? ShortcutStore(fileURL: nil)
        resolved.load()
        let box = ShortcutActionBox()
        self.actionBox = box
        self.store = resolved
        self.configuration = resolved.configuration
        self.carbon = CarbonShortcutRegistrar()
        self.eventTap = EventTapShortcutRegistrar()
        self.modelRef = model
        self.injectedRegistrar = nil
        self.activeRegistrar = nil
        self.engine = ShortcutEngine(configuration: resolved.configuration, sinks: .init(
            start: { [weak model, weak box] in
                box?.handler?("start")
                guard let m = model else { return }
                _ = m.ensureAutomaticInsertion()
                m.toggle()
            },
            finish: { [weak model, weak box] in box?.handler?("finish"); model?.finish() },
            cancel: { [weak model, weak box] in box?.handler?("cancel"); model?.cancel() },
            isRecording: { [weak model] in model?.phase == .recording },
            isBusy: { [weak model] in model?.busy == true },
            currentOperation: { [weak model] in model?.captureGeneration ?? 0 }
        ))
        // Delayed solo confirmation carries the physical down time into the engine.
        eventTap.confirmedPressHandler = { [weak self] down in self?.handlePress(downTime: down) }
        updateModelHints()
    }

    /// Test init with full control (no host audio/input).
    public init(engine: ShortcutEngine, store: ShortcutStore, registrar: (any ShortcutRegistrar)? = nil) {
        self.actionBox = ShortcutActionBox()
        self.engine = engine
        self.store = store
        self.configuration = store.configuration
        self.carbon = CarbonShortcutRegistrar()
        self.eventTap = EventTapShortcutRegistrar()
        self.injectedRegistrar = registrar
        self.activeRegistrar = registrar
        self.activeConfiguration = registrar?.registered
        self.modelRef = nil
        engine.updateConfiguration(store.configuration)
    }

    // MARK: Registration

    private func registrarFor(_ config: ShortcutConfiguration) -> any ShortcutRegistrar {
        if let injectedRegistrar { return injectedRegistrar }
        return config.trigger.requiresEventTap ? eventTap : carbon
    }

    private func updateModelHints() {
        // Hints and Start equivalents always reflect the WORKING binding, never stale.
        let working = isUsingFallback ? (activeConfiguration ?? .default) : configuration
        modelRef?.shortcutHint = ShortcutLabels.triggerDisplay(working.trigger)
    }

    /// Load the owned file-backed store (production launch path) and adopt it.
    /// Test delegates inject synthetic stores and never call this with the home URL.
    public func reloadFromStore() {
        store.load()
        configuration = store.configuration
        engine.updateConfiguration(configuration)
        updateModelHints()
    }
    /// Register the stored (or default) binding. Call once at launch; never prompts.
    /// On event-tap failure the stored choice is preserved in the file while the
    /// default Carbon chord stays working as a fallback.
    @discardableResult
    public func registerStoredOrDefault() -> Bool {
        let config = store.configuration
        do {
            let registrar = registrarFor(config)
            try registrar.register(config, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
            if let tap = registrar as? EventTapShortcutRegistrar {
                tap.interruptionHandler = { [weak self] in self?.handleInterruption() }
                tap.confirmedPressHandler = { [weak self] down in self?.handlePress(downTime: down) }
            }
            activeRegistrar = registrar
            activeConfiguration = config
            isUsingFallback = false
            configuration = config
            engine.updateConfiguration(config)
            lastError = nil
            updateModelHints()
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Preserve the stored choice; fall back to a working default chord.
            if config.trigger.requiresEventTap {
                do {
                    let fallback = ShortcutConfiguration(trigger: ShortcutConfiguration.default.trigger, behavior: config.behavior)
                    let fallbackRegistrar = registrarFor(fallback)
                    try fallbackRegistrar.register(fallback, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                    activeRegistrar = fallbackRegistrar
                    activeConfiguration = fallback
                    isUsingFallback = true
                    configuration = config
                    engine.updateConfiguration(config)
                    lastError = "\(message) Using ⌃⌘N until permitted."
                    updateModelHints()
                } catch {
                    lastError = message
                    configuration = config
                    engine.updateConfiguration(config)
                    updateModelHints()
                }
            } else {
                lastError = message
            }
            return false
        }
    }

    @discardableResult
    public func apply(_ config: ShortcutConfiguration) -> Bool {
        // Changing any setting cancels a pending mouse confirmation (new selection
        // starts its own confirmation via beginMouseButtonConfirmation). The commit
        // path sets isCommittingConfirmation to skip this self-cancel.
        if !isCommittingConfirmation, isConfirmingMouseButton {
            stopConfirmationSilently(notify: false)
        }
        guard engine.canChangeSettings else {
            lastError = "Finish or stop recording before changing shortcuts."
            return false
        }
        // Never dismiss the transient recorder here: a failed validation or
        // conflicting registration must leave the panel open for retry. The panel
        // closes itself on success; handleCapturedKey closes the direct path.
        if let err = ShortcutValidation.validate(config) {
            lastError = err
            return false
        }
        let previous = configuration
        let previousActive = activeConfiguration
        let previousRegistrar = activeRegistrar
        let previousFallback = isUsingFallback
        engine.updateConfiguration(config)
        do {
            let registrar = registrarFor(config)
            // Preserve the prior working registration until the new one succeeds.
            // (Carbon registrar itself is transactional via trial hotkey.)
            try registrar.register(config, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
            if let tap = registrar as? EventTapShortcutRegistrar {
                tap.interruptionHandler = { [weak self] in self?.handleInterruption() }
                tap.confirmedPressHandler = { [weak self] down in self?.handlePress(downTime: down) }
            }
            guard store.save(config) else {
                // Save failed: restore prior registration before reporting.
                registrar.unregister()
                if let previousRegistrar, let prev = previousActive ?? Optional(previous) {
                    try? previousRegistrar.register(prev, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                }
                throw VellaError.message(store.lastError ?? "Could not save shortcut.")
            }
            if registrar !== previousRegistrar { previousRegistrar?.unregister() }
            activeRegistrar = registrar
            activeConfiguration = config
            isUsingFallback = false
            configuration = config
            lastError = nil
            updateModelHints()
            objectWillChange.send()
            return true
        } catch {
            // Transactional rollback: restore engine + prior working registration.
            engine.updateConfiguration(previous)
            if let previousRegistrar, let prev = previousActive ?? Optional(previous) {
                if registrarFor(prev) === previousRegistrar {
                    try? previousRegistrar.register(prev, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                    activeRegistrar = previousRegistrar
                    activeConfiguration = prev
                }
            } else if let injectedRegistrar {
                try? injectedRegistrar.register(previous, onPress: { [weak self] in self?.handlePress() }, onRelease: { [weak self] in self?.handleRelease() })
                activeRegistrar = injectedRegistrar
                activeConfiguration = previous
            }
            isUsingFallback = previousFallback
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updateModelHints()
            objectWillChange.send()
            return false
        }
    }

    public func resetToDefault() {
        _ = apply(.default)
    }

    // MARK: Bounded mouse-button confirmation (inline row, no popup)

    /// UI entry: selecting ANY Mouse Button row starts confirmation, never applies.
    /// Same-button re-selection also confirms. Prior config persists until matching up.
    @discardableResult
    public func beginMouseButtonConfirmation(_ button: MouseButton) -> Bool {
        guard engine.canChangeSettings else {
            lastError = "Finish or stop recording before changing shortcuts."
            return false
        }
        if let err = ShortcutValidation.validate(ShortcutConfiguration(trigger: .mouseButton(button: button), behavior: configuration.behavior)) {
            lastError = err
            return false
        }
        // Changing selection cancels any previous pending confirmation.
        stopConfirmationSilently(notify: false)
        // Silent check only; never prompts. AX-denied surfaces distinctly.
        guard confirmationAccessCheck() else {
            pendingMouseButton = nil
            confirmationDownSeen = false
            mouseConfirmationError = Self.mouseConfirmationAccessDeniedMessage
            mouseConfirmationErrorButton = button
            mouseConfirmationErrorDetail = nil
            mouseConfirmationDetectedLabel = nil
            objectWillChange.send()
            onMouseConfirmationChange?()
            return false
        }
        confirmationGeneration &+= 1
        let gen = confirmationGeneration
        pendingMouseButton = button
        mouseConfirmationError = nil
        mouseConfirmationErrorButton = nil
        mouseConfirmationErrorDetail = nil
        mouseConfirmationDetectedLabel = nil
        confirmationDownSeen = false
        let monitor = makeConfirmationMonitor()
        confirmationMonitor = monitor
        do {
            try monitor.start(button: button, handler: { [weak self] type, event in
                guard let self else { return false }
                // Hop to MainActor for state; capture synchronously in handler below.
                // The tap callback runs on the main runloop; MainActor-isolated
                // processing is dispatched via the manager queue below in commit path.
                // For immediate consume decision we call the isolated reducer via assume.
                return MainActor.assumeIsolated { self.processConfirmationTapEvent(type: type, event: event, expectedGeneration: gen) }
            }, onFailure: { [weak self] in
                Task { @MainActor in self?.handleConfirmationMonitorFailure(generation: gen) }
            })
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stopConfirmationSilently(notify: false)
            pendingMouseButton = nil
            mouseConfirmationError = message
            mouseConfirmationErrorButton = button
            mouseConfirmationErrorDetail = nil
            mouseConfirmationDetectedLabel = nil
            objectWillChange.send()
            onMouseConfirmationChange?()
            return false
        }
        let timer = makeConfirmationTimer()
        confirmationTimer = timer
        timer.schedule(delay: confirmationTimeoutInterval) { [weak self] in
            Task { @MainActor in self?.handleConfirmationTimeout(generation: gen) }
        }
        objectWillChange.send()
        onMouseConfirmationChange?()
        return true
    }

    /// Explicit cancel: root menu close/Escape, changing setting/selection, busy.
    public func cancelMouseButtonConfirmation() {
        guard isConfirmingMouseButton || mouseConfirmationError != nil else { return }
        stopConfirmationSilently(notify: true)
    }

    private func stopConfirmationSilently(notify: Bool) {
        confirmationGeneration &+= 1
        confirmationMonitor?.stop()
        confirmationMonitor = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDownSeen = false
        pendingMouseButton = nil
        mouseConfirmationError = nil
        mouseConfirmationErrorButton = nil
        mouseConfirmationErrorDetail = nil
        mouseConfirmationDetectedLabel = nil
        if notify {
            objectWillChange.send()
            onMouseConfirmationChange?()
        }
    }

    private func stopConfirmationKeepingError() {
        confirmationGeneration &+= 1
        confirmationMonitor?.stop()
        confirmationMonitor = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDownSeen = false
        pendingMouseButton = nil
        mouseConfirmationDetectedLabel = nil
        mouseConfirmationErrorDetail = nil
    }

    /// Production tap entry, callable with synthetic events in tests (no posting/TCC).
    /// Consumes ONLY the expected other-button down/up (true). Wrong other-button
    /// downs and left/right downs update SAME-row feedback, keep waiting, and are
    /// NEVER consumed. Unmatched ups, other ups, and all other types pass through.
    /// No typed-key observation.
    @discardableResult
    public func processConfirmationTapEvent(type: CGEventType, event: CGEvent, expectedGeneration: UInt64? = nil) -> Bool {
        let gen = expectedGeneration ?? confirmationGeneration
        guard gen == confirmationGeneration, let expected = pendingMouseButton else { return false }
        guard engine.canChangeSettings else {
            // Busy during confirmation cancels; do not consume the click.
            Task { @MainActor in self.cancelMouseButtonConfirmation() }
            return false
        }
        // Ordinary clicks inform accurate feedback but are never consumed.
        if type == .leftMouseDown || type == .rightMouseDown {
            let label = Self.mouseConfirmationDetectedLabel(forButtonNumber: type == .leftMouseDown ? 0 : 1, eventType: type)
            if mouseConfirmationDetectedLabel != label {
                mouseConfirmationDetectedLabel = label
                objectWillChange.send()
                onMouseConfirmationChange?()
            }
            return false
        }
        guard type == .otherMouseDown || type == .otherMouseUp else { return false }
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        let expectedNumber = Int64(expected.rawValue)
        if number != expectedNumber {
            // Wrong other-button: feedback in SAME row, keep waiting, never consume.
            // Only downs inform feedback; wrong ups pass through silently.
            if type == .otherMouseDown {
                let label = Self.mouseConfirmationDetectedLabel(forButtonNumber: number, eventType: type)
                if mouseConfirmationDetectedLabel != label {
                    mouseConfirmationDetectedLabel = label
                    objectWillChange.send()
                    onMouseConfirmationChange?()
                }
            }
            return false
        }
        if type == .otherMouseDown {
            if confirmationDownSeen { return true } // autorepeat: consume silently
            confirmationDownSeen = true
            // Correct button found: clear wrong-button feedback, keep waiting for up.
            if mouseConfirmationDetectedLabel != nil {
                mouseConfirmationDetectedLabel = nil
                objectWillChange.send()
                onMouseConfirmationChange?()
            }
            return true
        } else {
            guard confirmationDownSeen else { return false } // unmatched up passes through
            // Prefer commit on matching up: consume first, commit async so the
            // release can never reach the new Hold binding.
            let commitGen = confirmationGeneration
            let commitButton = expected
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in self?.commitConfirmedMouseButton(button: commitButton, generation: commitGen) }
            }
            return true
        }
    }

    private func commitConfirmedMouseButton(button: MouseButton, generation: UInt64) {
        guard generation == confirmationGeneration, pendingMouseButton == button else { return }
        guard engine.canChangeSettings else { cancelMouseButtonConfirmation(); return }
        // Tear down confirmation FIRST so late callbacks cannot leak into activation.
        let errorButton = button
        confirmationMonitor?.stop()
        confirmationMonitor = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDownSeen = false
        pendingMouseButton = nil
        mouseConfirmationError = nil
        mouseConfirmationErrorButton = nil
        mouseConfirmationErrorDetail = nil
        mouseConfirmationDetectedLabel = nil
        confirmationGeneration &+= 1
        isCommittingConfirmation = true
        defer { isCommittingConfirmation = false }
        let ok = apply(ShortcutConfiguration(trigger: .mouseButton(button: button), behavior: configuration.behavior))
        if !ok {
            // Compact row text so long persistence/registration errors cannot clip;
            // full diagnostic stays in the tooltip.
            let full = lastError ?? Self.mouseConfirmationUnavailableMessage
            mouseConfirmationError = Self.mouseConfirmationUnchangedMessage
            mouseConfirmationErrorButton = errorButton
            mouseConfirmationErrorDetail = full
        }
        objectWillChange.send()
        onMouseConfirmationChange?()
    }

    func handleConfirmationTimeout(generation: UInt64) {
        guard generation == confirmationGeneration, let target = pendingMouseButton else { return }
        stopConfirmationKeepingError()
        // Bounded 10s timeout reports in the same row; no hardware diagnosis.
        mouseConfirmationError = Self.mouseConfirmationTimeoutMessage
        mouseConfirmationErrorButton = target
        mouseConfirmationErrorDetail = nil
        objectWillChange.send()
        onMouseConfirmationChange?()
    }

    private func handleConfirmationMonitorFailure(generation: UInt64) {
        guard generation == confirmationGeneration, pendingMouseButton != nil else { return }
        // Tap failure (sleep/lock/tap loss): cancel silently, restore row.
        stopConfirmationSilently(notify: true)
    }

    // MARK: Activation events (called by registrars; testable directly)

    public func handlePress(isRepeat: Bool = false, downTime: TimeInterval? = nil) {
        // Suspend activation while the transient key recorder owns the keyboard
        // or a mouse-button confirmation is pending (its gesture never activates).
        guard !isCapturingKeys, !isConfirmingMouseButton else { return }
        menuCancel?()
        // Permission gates only potential new starts (idle). Stopping, finishing,
        // or arming a tap-off while recording/busy never requires insertion
        // permission: Finish falls back to clipboard-only.
        if engine.canChangeSettings, let check = permissionCheck, !check() { return }
        _ = engine.press(isRepeat: isRepeat, downTime: downTime)
    }
    public func handleRelease() {
        guard !isCapturingKeys, !isConfirmingMouseButton else { return }
        _ = engine.release()
    }
    public func handleInterruption() {
        let wasConfirming = isConfirmingMouseButton
        if wasConfirming {
            // Sleep/lock/tap failure cancels confirmation; prior binding stays working.
            stopConfirmationSilently(notify: false)
        }
        engine.handleInterruption()
        // Reset pending native input and invalidate queued callbacks without
        // losing registration or notifying recursively.
        activeRegistrar?.resetPendingInput()
        if (activeRegistrar as AnyObject?) !== (eventTap as AnyObject) {
            eventTap.resetPendingInput()
        }
        if wasConfirming {
            objectWillChange.send()
            onMouseConfirmationChange?()
        }
        onAction?("interrupt")
    }

    func beginObservingSystemInterruptions() {
        guard interruptionObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] as [NSNotification.Name] {
            interruptionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleInterruption() }
            })
        }
        interruptionObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleInterruption() }
        })
    }

    // MARK: Native key recorder (transient panel owns the keyboard)

    public func beginKeyCapture() {
        // Starting key capture cancels bounded mouse confirmation (changing selection).
        if isConfirmingMouseButton { stopConfirmationSilently(notify: false) }
        guard engine.canChangeSettings else {
            lastError = "Finish or stop recording before changing shortcuts."
            return
        }
        cancelKeyCapture()
        isCapturingKeys = true
        objectWillChange.send()
        // Unit tests (no runloop) drive handleCapturedKey directly; only show UI live.
        guard NSApplication.shared.isRunning else { return }
        let panel = ShortcutKeyRecorderPanel()
        recorderPanel = panel
        panel.onCancel = { [weak self] in self?.cancelKeyCapture() }
        panel.onChord = { [weak self, weak panel] code, mods in
            guard let self else { return false }
            let ok = self.apply(ShortcutConfiguration(trigger: .keyChord(keyCode: code, modifiers: mods), behavior: self.configuration.behavior))
            if ok {
                self.cancelKeyCapture()
            } else {
                panel?.showError(self.lastError ?? "That chord cannot be used.")
            }
            return ok
        }
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    public func cancelKeyCapture() {
        isCapturingKeys = false
        recorderPanel?.orderOut(nil)
        recorderPanel = nil
        objectWillChange.send()
    }
    @discardableResult
    public func handleCapturedKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let config = ShortcutConfiguration(trigger: .keyChord(keyCode: keyCode, modifiers: modifiers), behavior: configuration.behavior)
        let ok = apply(config)
        // Direct (non-panel) path always ends capture; the transient panel instead
        // stays open on failure for retry and closes itself on success.
        if isCapturingKeys { cancelKeyCapture() }
        return ok
    }
    public func applyBehavior(_ behavior: ShortcutBehavior) -> Bool {
        apply(ShortcutConfiguration(trigger: configuration.trigger, behavior: behavior))
    }
    public func applyModifierOnly(key: ModifierKey, side: ModifierSide) -> Bool {
        apply(ShortcutConfiguration(trigger: .modifierOnly(key: key, side: side), behavior: configuration.behavior))
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= ShortcutConfiguration.controlFlag }
        if flags.contains(.option) { mods |= ShortcutConfiguration.optionFlag }
        if flags.contains(.shift) { mods |= ShortcutConfiguration.shiftFlag }
        if flags.contains(.command) { mods |= ShortcutConfiguration.cmdFlag }
        if flags.contains(.function) { mods |= 0x800000 }
        return mods
    }

    /// Start/Finish menu key equivalent reflecting the WORKING binding.
    nonisolated static func menuKeyEquivalent(for config: ShortcutConfiguration) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard case .keyChord(let code, let mods) = config.trigger else { return ("", []) }
        let key = ShortcutLabels.keyName(keyCode: code).lowercased()
        guard key.count == 1 else { return ("", []) }
        var flags: NSEvent.ModifierFlags = []
        if mods & ShortcutConfiguration.controlFlag != 0 { flags.insert(.control) }
        if mods & ShortcutConfiguration.cmdFlag != 0 { flags.insert(.command) }
        if mods & ShortcutConfiguration.optionFlag != 0 { flags.insert(.option) }
        if mods & ShortcutConfiguration.shiftFlag != 0 { flags.insert(.shift) }
        if flags.isEmpty { return ("", []) }
        return (key, flags)
    }
}
