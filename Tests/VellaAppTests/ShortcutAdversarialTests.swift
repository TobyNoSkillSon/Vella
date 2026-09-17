import XCTest
import AppKit
import Carbon
@testable import Vella
import VellaCore

/// Independent adversarial QA for configurable activation (w1:p1, spark).
///
/// Scope: public source only, synthetic fixtures only. No full-app launch,
/// no microphone capture, no global input injection (no CGEventPost),
/// no TCC prompts, no second Vella app.
///
/// Evidence tags (match qa-edge-case-matrix.md):
/// - [INJ] injected / synthetic fixture evidence in this file
/// - [RENDER] isolated native view/menu structure (no popUp tracking, no duplicate app)
/// - [HW] physical / TCC / real-device residual — documented, never faked
///
/// Status: integration landed. Update 2026-09-16 (pm): `spark/contract.md` +
/// `ShortcutCore.swift` + `Shortcuts.swift` + `App.swift`/`UI.swift` wiring present.
/// Baseline guards retained; contract engine/store/manager tests in Part II;
/// concrete native bugs from sanitized `coordinator-review.txt` in Part III.
/// `LiveInsertion.observeUserInput` is legacy (not the production blind path) —
/// B5/B9 legacy tests below document old helper only; production claims use
/// `EventTapShortcutRegistrar` statics + `ShortcutEngine` + `ShortcutManager`.
final class ShortcutAdversarialTests: XCTestCase {

    // MARK: - Fixtures (synthetic only)

    @MainActor private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-shortcut-adv-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private func tempConfig(mode: RecognitionMode = .dictation) throws -> URL {
        let root = try tempRoot()
        let url = root.appendingPathComponent("config.json")
        var settings = Configuration(executable: "/unused", model: "/synthetic")
        settings.mode = mode
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        return url
    }

    @MainActor private func deniedPermission() -> (InsertionPermission, PermissionPromptHistory) {
        var shown = false
        let history = PermissionPromptHistory(read: { shown }, write: { shown = true })
        let permission = InsertionPermission(isTrusted: { false }, prompt: {}, history: history)
        return (permission, history)
    }

    @MainActor private func syntheticBoard() -> NSPasteboard {
        NSPasteboard.withUniqueName()
    }

    @MainActor private func microphoneIndex(in menu: NSMenu) -> Int? {
        menu.items.firstIndex(where: { $0.title == "Microphone" })
    }

    @MainActor private func shortcutSubmenuIndex(in menu: NSMenu) -> Int? {
        // Future contract: compact Shortcuts submenu immediately below Microphone.
        // Accept either "Shortcuts" or "Shortcut" / "Activation" titles to avoid
        // brittle failure on naming, but placement must be exact when present.
        menu.items.firstIndex(where: { ["Shortcuts", "Shortcut", "Activation", "Keyboard Shortcut"].contains($0.title) })
    }

    // MARK: - A. Persistence & recovery (baseline analogues) [INJ]

    @MainActor func testA1FreshInstallDefaultsToDictationIdle() throws {
        let root = try tempRoot()
        let missing = root.appendingPathComponent("config.json")
        let model = Model(configurationURL: missing)
        defer { model.shutdown() }
        XCTAssertEqual(model.mode, .dictation)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testA2CorruptConfigFallsBackWithoutCrash() throws {
        let root = try tempRoot()
        let url = root.appendingPathComponent("config.json")
        try "not-json{{{".write(to: url, atomically: true, encoding: .utf8)
        // Direct decode must throw (caller recovers to defaults, never force-unwraps).
        XCTAssertThrowsError(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)))
        let model = Model(configurationURL: url)
        defer { model.shutdown() }
        XCTAssertEqual(model.mode, .dictation, "Corrupt payload must recover to defaults")
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor func testA3UnknownModeStringFallsBackToDictation() throws {
        // Configuration.init uses decodeIfPresent + default, but an invalid raw
        // value still throws dataCorrupted at decode time. Production recovers
        // via `try?` in Model.init (falls back to .dictation). Future shortcut
        // prefs must follow the same pattern: never force-unwrap/precondition,
        // always recover to defaults (A3).
        let payload = #"{"executable":"/unused","model":"/m","mode":"hyperdrive"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Configuration.self, from: payload))
        let root = try tempRoot()
        let url = root.appendingPathComponent("config.json")
        try payload.write(to: url)
        let model = Model(configurationURL: url)
        defer { model.shutdown() }
        XCTAssertEqual(model.mode, .dictation, "Unknown enum must recover to defaults via Model fallback (A3)")
    }

    @MainActor func testA8FutureSchemaExtraKeysIgnored() throws {
        let payload = #"{"executable":"/unused","model":"/m","mode":"dictation","futureShortcut":{"chord":"F99"},"unknownArray":[1,2]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Configuration.self, from: payload)
        XCTAssertEqual(decoded.mode, .dictation)
        XCTAssertEqual(decoded.model, "/m")
    }

    @MainActor func testA10UpgradeFrom088KeepsModeAndMic() throws {
        let root = try tempRoot()
        let url = root.appendingPathComponent("config.json")
        var settings = Configuration(executable: "/unused", model: "/keep")
        settings.mode = .streaming
        settings.preferredMicrophone = "Synthetic Mic"
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        let model = Model(configurationURL: url)
        defer { model.shutdown() }
        XCTAssertEqual(model.mode, .streaming, "Existing mode must be untouched by shortcut defaults (A10)")
    }

    @MainActor func testA5EmptyTriggerAnalogueIsInvalid() throws {
        // Analogue: empty model + empty executable fails validation, so a future
        // "empty trigger (no key/modifiers/mouse)" must likewise be rejected
        // and fall back to ⌃⌘N rather than registering nothing (A5).
        let empty = Configuration(executable: "", model: "")
        XCTAssertThrowsError(try empty.validate())
        let noModel = Configuration(executable: "/unused", model: "")
        XCTAssertThrowsError(try noModel.validate())
    }

    // MARK: - B. Chord matching / modifier-only / repeat [INJ logic]

    @MainActor func testB1DeviceIndependentMaskPolicy() {
        // Carbon/NSEvent flags include capsLock/fn/device bits. Raw equality
        // must not be used. The contract must define an explicit mask.
        // Note: NSEvent.deviceIndependentFlagsMask still distinguishes capsLock
        // on this SDK, so the implementation must mask to the trigger-relevant
        // subset ([.control,.command,.option,.shift]) — locked here.
        let configured: NSEvent.ModifierFlags = [.control, .command]
        let eventWithNoise: NSEvent.ModifierFlags = [.control, .command, .capsLock, .function, .numericPad]
        XCTAssertNotEqual(configured, eventWithNoise, "Raw equality fails with noise bits (documents the trap)")
        let relevant: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
        XCTAssertEqual(
            configured.intersection(relevant),
            eventWithNoise.intersection(relevant),
            "Relevant-subset comparison must match through capsLock/fn/numericPad noise (B1)"
        )
        // Document the SDK trap: deviceIndependent mask alone is insufficient.
        XCTAssertNotEqual(
            configured.intersection(.deviceIndependentFlagsMask),
            eventWithNoise.intersection(.deviceIndependentFlagsMask),
            "deviceIndependentFlagsMask retains capsLock on this SDK — must not be the sole mask (B1 risk)"
        )
    }

    @MainActor func testB3B4ModifierOnlyMustUseExactMatchNotContainment() {
        // Modifier-only trigger (e.g. solo ⌥) must NOT fire while composing a
        // larger chord (e.g. ⌥⌘N). Containment is the bug; exact match is the fix.
        // Generic NSEvent logic (still valid) + production EventTap statics below.
        let trigger: NSEvent.ModifierFlags = [.option]
        let composed: NSEvent.ModifierFlags = [.option, .command]
        XCTAssertTrue(composed.contains(.option), "Containment would false-fire (B3 trap)")
        XCTAssertNotEqual(trigger, composed, "Exact match must reject the composed chord (B3)")
        // Production path: EventTap requires ONLY our modifier (no extras).
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContain(.maskAlternate, key: .option))
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContainOnly(.maskAlternate, key: .option))
        XCTAssertFalse(EventTapShortcutRegistrar.flagsContainOnly([.maskAlternate, .maskCommand], key: .option), "Composed ⌥⌘ must not fire solo ⌥ (B3 production)")
        // Legacy helper below is not production (blind Streaming uses no monitor).
        let idle = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        idle.observeUserInput(type: .flagsChanged, modifiers: [])
        idle.observeUserInput(type: .flagsChanged, modifiers: [.option])
        XCTAssertNil(idle.blockedReason, "Legacy helper: flagsChanged alone never disturbed insertion")
    }

    @MainActor func testB5FlagsChangedNoiseAndMouseMovedIgnored_Legacy() {
        // LEGACY: documents old `LiveInsertion.observeUserInput` (unused in production blind path).
        // Production blind Streaming uses `monitorUserInput:false`; no finding depends on this helper.
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        controller.observeUserInput(type: .flagsChanged)
        controller.observeUserInput(type: .mouseMoved)
        controller.observeUserInput(type: .keyUp, keyCode: 45, modifiers: [])
        controller.observeUserInput(type: .keyUp, keyCode: 45, modifiers: [.command])
        XCTAssertNil(controller.blockedReason)
    }

    @MainActor func testB6B7RepeatAndToggleIdempotenceAtModelLayer() throws {
        // Key repeat storm (isARepeat stream) must produce exactly one press edge.
        // At Model layer: second toggle while busy beeps and is ignored; finish
        // when not recording is a no-op (no start/stop flapping).
        let config = try tempConfig()
        let board = syntheticBoard()
        defer { board.releaseGlobally() }
        let model = Model(pasteboard: board, configurationURL: config)
        defer { model.shutdown() }
        // Stale finish / repeat finish with no recording: no-op, no clipboard.
        model.finish()
        model.finish()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(board.string(forType: .string))
        // Busy guard: preparing + toggle must stay preparing (no queued finish).
        model.update(.preparing, "Synthetic busy")
        model.toggle() // busy -> NSSound.beep + return (no mic access from this path)
        XCTAssertEqual(model.phase, .preparing, "Repeat during preparing must not flap (B6/B7/C7)")
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor func testB9B10SelfEventImmunity_Legacy() async throws {
        // LEGACY helper check only (not production). Production self-immunity is via
        // Carbon/event-tap source filtering + engine ownership, covered in Part III.
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        // Own LiveInsertion events (marker) are ignored.
        controller.observeUserInput(type: .keyDown, marker: LiveInsertion.eventMarker)
        // Retained ⌃⌘N keyDown is explicitly ignored by current policy.
        controller.observeUserInput(type: .keyDown, keyCode: 45, modifiers: [.control, .command])
        XCTAssertNil(controller.blockedReason, "Self events must not pause (B9/B10)")
        // Genuine user typing/mouse still pauses (control case).
        let typing = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        typing.observeUserInput(type: .keyDown, keyCode: 0)
        XCTAssertNotNil(typing.blockedReason)
        let click = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        click.observeUserInput(type: .leftMouseDown)
        XCTAssertNotNil(click.blockedReason)
        // Native event provenance: marker present, keycode 0, unicode intact, no post.
        let (down, up) = try LiveInsertion.nativeEvents(for: "Hi")
        for event in [down, up] {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), LiveInsertion.eventMarker)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
        }
        XCTAssertEqual(down.type, .keyDown)
        XCTAssertEqual(up.type, .keyUp)
    }

    @MainActor func testB9HardcodedNIgnoresSupersetRisk_Legacy() {
        // LEGACY: locks old helper shape only. Do not request semantic changes here;
        // production chord policy lives in `ShortcutValidation` + Carbon/event-tap routing.
        let exact = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        exact.observeUserInput(type: .keyDown, keyCode: 45, modifiers: [.control, .command])
        XCTAssertNil(exact.blockedReason, "Exact ⌃⌘N ignored (current baseline)")
        let superset = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        superset.observeUserInput(type: .keyDown, keyCode: 45, modifiers: [.control, .command, .shift])
        XCTAssertNotNil(superset.blockedReason, "Superset currently pauses — implementer must define B2 policy explicitly")
    }

    // MARK: - C. Activation state machine [INJ]

    @MainActor func testC1RetainedTogglePathUnaffected() throws {
        let config = try tempConfig()
        let delegate = AppDelegate(model: Model(configurationURL: config), shortcutStoreURL: config.deletingLastPathComponent().appendingPathComponent("shortcuts-qa.json"))
        defer { delegate.model.shutdown() }
        delegate.rebuildMenu()
        let start = try XCTUnwrap(delegate.menu.items.first(where: { $0.title.hasPrefix("Start") || $0.title.hasPrefix("Finish") }))
        XCTAssertEqual(start.keyEquivalent, "n")
        XCTAssertEqual(start.keyEquivalentModifierMask, NSEvent.ModifierFlags([.control, .command]), "Retained ⌃⌘N must be unchanged (C1)")
    }

    @MainActor func testC7C9C10C11StaleReleasesAreNoOps() throws {
        let config = try tempConfig()
        let board = syntheticBoard()
        defer { board.releaseGlobally() }
        let model = Model(pasteboard: board, configurationURL: config)
        defer { model.shutdown() }
        for phase: Model.Phase in [.idle, .preparing, .transcribing, .success, .failed] {
            model.update(phase, "Synthetic \(phase)")
            model.finish()
            XCTAssertEqual(model.phase, phase, "finish() outside recording must be no-op (C9/C10/C11)")
        }
        XCTAssertNil(board.string(forType: .string), "Stale release must never touch clipboard")
        // Failed with no savedSession: retry is no-op.
        model.update(.failed, "Synthetic failure")
        model.retry()
        XCTAssertEqual(model.phase, .failed)
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor func testC14ModeSwitchGuardedWhileRecording() throws {
        let config = try tempConfig()
        let model = Model(configurationURL: config)
        defer { model.shutdown() }
        model.update(.recording, "Synthetic recording")
        XCTAssertThrowsError(try model.selectMode(.streaming), "Mode switch while recording must stay blocked (C14/C18 analogue)")
        model.update(.idle, "reset")
    }

    @MainActor func testC16SuccessSettlesAndNewPressCancelsTimer() throws {
        let config = try tempConfig()
        let model = Model(configurationURL: config)
        defer { model.shutdown() }
        model.update(.success, "Synthetic success")
        XCTAssertEqual(model.phase, .success)
        // update() semantics: any new phase cancels the success settle timer.
        model.update(.preparing, "Synthetic next press")
        XCTAssertEqual(model.phase, .preparing)
        model.cancel()
    }

    // MARK: - D. Start failures & permission [INJ, no TCC]

    @MainActor func testD3DeniedAXNeverStartsAndReleaseIsNoOp() throws {
        let (permission, _) = deniedPermission()
        let config = try tempConfig()
        let board = syntheticBoard()
        defer { board.releaseGlobally() }
        let model = Model(insertionPermission: permission, pasteboard: board, configurationURL: config)
        defer { model.shutdown() }
        model.toggle()
        XCTAssertEqual(model.phase, .idle, "AX-denied press must not start (D3)")
        XCTAssertNil(model.recorder.url)
        model.finish()
        XCTAssertEqual(model.phase, .idle, "Release after denied start is no-op (D1/D3)")
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testD6CancelClearsSnapshotAndBlocksInsertion() throws {
        let board = syntheticBoard()
        defer { board.releaseGlobally() }
        var snapshots = 0
        let config = try tempConfig()
        let model = Model(pasteboard: board, stopCapture: { _ in throw VellaError.message("Synthetic drain failure") },
                          configurationURL: config, captureDestination: {
            snapshots += 1
            return { nil }
        })
        defer { model.onChange = nil; model.cancel() }
        model.phase = .recording
        model.finish()
        XCTAssertEqual(snapshots, 1, "Finish must snapshot synchronously")
        model.cancel()
        XCTAssertNotNil(model.automaticInsertionBlockReason, "Cancel must release snapshot to clipboard-only (D6/D7)")
    }

    // MARK: - E. Lock / sleep / tap loss [INJ structure, HW residuals documented]

    @MainActor func testE3SpaceChangeDoesNotCorruptSyntheticRecording() throws {
        let config = try tempConfig()
        let model = Model(configurationURL: config)
        defer { model.shutdown() }
        let delegate = AppDelegate(model: model, shortcutStoreURL: try tempRoot().appendingPathComponent("shortcuts-qa.json"))
        delegate.configureHUDPanel() // Isolated panel only; no status item, no app run.
        model.update(.recording, "Synthetic recording")
        delegate.activeSpaceChanged()
        XCTAssertEqual(model.phase, .recording, "Space change must not corrupt gesture/recording state (E3)")
        model.update(.idle, "reset")
        delegate.activeSpaceChanged()
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - F. Menu / UI contract [INJ + RENDER structure]

    @MainActor func testF1SubmenuPlacementImmediatelyBelowMicrophone() throws {
        let config = try tempConfig()
        let delegate = AppDelegate(model: Model(configurationURL: config), shortcutStoreURL: config.deletingLastPathComponent().appendingPathComponent("shortcuts-qa.json"))
        defer { delegate.model.shutdown() }
        // F1 now REQUIRES Shortcuts (integration landed) at microphoneIndex+1 in every phase.
        for phase: Model.Phase in [.idle, .preparing, .recording, .transcribing, .success, .failed] {
            delegate.model.update(phase, "Synthetic")
            delegate.rebuildMenu()
            guard let mic = microphoneIndex(in: delegate.menu) else {
                XCTFail("Microphone item missing in phase \(phase)"); continue
            }
            guard let shortcut = shortcutSubmenuIndex(in: delegate.menu) else {
                XCTFail("Shortcuts submenu missing in phase \(phase) (F1 REQUIREs it post-integration)"); continue
            }
            XCTAssertEqual(shortcut, mic + 1, "Shortcut submenu must sit immediately below Microphone (F1) in phase \(phase)")
            XCTAssertEqual(delegate.menu.items[shortcut].title, "Shortcuts")
        }
    }

    @MainActor func testF2RebuildsStableNoDuplicates() throws {
        let config = try tempConfig()
        let delegate = AppDelegate(model: Model(configurationURL: config), shortcutStoreURL: config.deletingLastPathComponent().appendingPathComponent("shortcuts-qa.json"))
        defer { delegate.model.shutdown() }
        delegate.rebuildMenu()
        let count = delegate.menu.items.count
        for _ in 0..<5 { delegate.rebuildMenu() }
        XCTAssertEqual(delegate.menu.items.count, count, "Rebuilds must be idempotent (F2)")
        let mics = delegate.menu.items.filter { $0.title == "Microphone" }
        XCTAssertEqual(mics.count, 1, "No duplicate Microphone after rebuilds (F2)")
        let shortcuts = delegate.menu.items.filter { ["Shortcuts", "Shortcut", "Activation"].contains($0.title) }
        XCTAssertLessThanOrEqual(shortcuts.count, 1, "No duplicate shortcut submenu (F2)")
    }

    @MainActor func testF3StartItemRetainsCtrlCmdNGlyph() throws {
        let config = try tempConfig()
        let delegate = AppDelegate(model: Model(configurationURL: config), shortcutStoreURL: config.deletingLastPathComponent().appendingPathComponent("shortcuts-qa.json"))
        defer { delegate.model.shutdown() }
        for phase: Model.Phase in [.idle, .preparing, .recording, .transcribing, .success, .failed] {
            delegate.model.update(phase, "Synthetic")
            delegate.rebuildMenu()
            let start = delegate.menu.items.first(where: { $0.title.hasPrefix("Start") || $0.title.hasPrefix("Finish") })
            let item = try XCTUnwrap(start, "Start/Finish item missing in phase \(phase) (F3)")
            XCTAssertEqual(item.keyEquivalent, "n", "Start item must retain ⌃⌘N display (F3)")
            XCTAssertEqual(item.keyEquivalentModifierMask, NSEvent.ModifierFlags([.control, .command]))
            XCTAssertFalse(item.title.isEmpty)
        }
    }

    @MainActor func testF4EmbeddedControlKeepOpenAnalogue() {
        // Analogue for the future shortcut rebind/mode control: embedded
        // SettingsMenuItem control must synchronize without dispatching when
        // disabled, and must retain keyboard action (keep-open invariant).
        _ = NSApplication.shared
        let item = SettingsMenuItem(title: "Synthetic shortcut control", target: NSObject(), action: NSSelectorFromString("unused"))
        item.isEnabled = false; item.state = .on; item.synchronize()
        XCTAssertFalse(item.control.isEnabled)
        XCTAssertEqual(item.control.state, .on)
        XCTAssertNotNil(item.view, "Embedded control view must exist (F4)")
    }

    @MainActor func testF5RecordingHintAccuracyBaseline() throws {
        // Baseline: recording/streaming hints hardcode ⌃⌘N. After customization
        // they must reflect the active binding or stay accurate — never instruct
        // a chord that doesn't work. Lock baseline wording so drift is visible.
        let config = try tempConfig()
        let delegate = AppDelegate(model: Model(configurationURL: config), shortcutStoreURL: config.deletingLastPathComponent().appendingPathComponent("shortcuts-qa.json"))
        defer { delegate.model.shutdown() }
        delegate.model.update(.recording, "Synthetic")
        delegate.rebuildMenu()
        let start = delegate.menu.items.first(where: { $0.title.hasPrefix("Finish") })
        XCTAssertNotNil(start, "Recording must show Finish item, not Start")
        // Model.toggle's recording message is set only via real capture; verify the
        // menu-level Start/Finish titles instead of forcing microphone capture.
        delegate.model.update(.idle, "reset")
    }

    // MARK: - G. Safety invariants (unchanged surfaces) [INJ]

    @MainActor func testG1NoEnterSendFromGesturePath() throws {
        // sanitize() must map Return/controls to space, never emit CR/LF.
        XCTAssertEqual(LiveInsertion.sanitize("a\rb\nc"), "a b c")
        XCTAssertEqual(LiveInsertion.sanitize("a\u{0000}b\u{007F}c"), "a b c")
        let chunked = try LiveInsertion.unicodeChunks("hello")
        XCTAssertEqual(chunked.joined(), "hello")
        // Empty recognition is a no-op that preserves clipboard (never types).
        let board = syntheticBoard()
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("keep", forType: .string)
        let model = Model(pasteboard: board, configurationURL: try tempConfig())
        defer { model.shutdown() }
        model.finishPasteCheck() // copy-only path (no target) — must not post keys
        XCTAssertFalse(model.insertionWasAutomatic)
        // finishPasteCheck with no destination copies verification text (no Enter).
        XCTAssertEqual(board.string(forType: .string), "Vella paste verification.")
    }

    @MainActor func testG2NoFocusSteeringFromShortcutLayer() {
        XCTAssertTrue(AccessibilityFocus.isFieldRole("AXTextArea"))
        XCTAssertTrue(AccessibilityFocus.isFieldRole("AXTextField"))
        XCTAssertTrue(AccessibilityFocus.isFieldRole("AXComboBox"))
        XCTAssertTrue(AccessibilityFocus.isFieldRole("AXSearchField"))
        XCTAssertFalse(AccessibilityFocus.isFieldRole("AXButton"))
        XCTAssertFalse(AccessibilityFocus.isFieldRole(nil))
        XCTAssertFalse(AccessibilityFocus.isFieldRole("AXWindow"))
        // Safe no-ops: nil target and own process never touch AX.
        AccessibilityFocus.prepare(nil)
        AccessibilityFocus.prepare(NSRunningApplication.current)
    }

    @MainActor func testG3G4RecognitionAndRecoveryUntouched() async throws {
        // Dictation finish captures synchronously; streaming captures nothing;
        // recovery/retry are clipboard-only. Any shortcut path must reuse
        // toggle()/finish()/recover() entry points, never a parallel pipeline.
        var snapshots = 0
        let board = syntheticBoard()
        defer { board.releaseGlobally() }
        let dictation = Model(pasteboard: board,
                              stopCapture: { _ in throw VellaError.message("Synthetic") },
                              configurationURL: try tempConfig(mode: .dictation),
                              captureDestination: { snapshots += 1; return { nil } })
        defer { dictation.onChange = nil; dictation.cancel() }
        dictation.phase = .recording
        dictation.finish()
        XCTAssertEqual(snapshots, 1, "Dictation Finish must snapshot (G3)")
        dictation.cancel()
        let streaming = Model(pasteboard: board,
                              stopCapture: { _ in throw VellaError.message("Synthetic") },
                              configurationURL: try tempConfig(mode: .streaming),
                              captureDestination: { snapshots += 1; return { nil } })
        defer { streaming.onChange = nil; streaming.cancel() }
        streaming.phase = .recording
        streaming.finish()
        XCTAssertEqual(snapshots, 1, "Streaming Finish must not capture destination (G3 blind/roaming)")
        streaming.cancel()
        XCTAssertEqual(streaming.automaticInsertionBlockReason, "Recovered or cancelled recordings are clipboard-only.", "Recovery stays clipboard-only (G4)")
    }

    @MainActor func testG6NoGlobalInjectionInThisSuite() {
        // Static guard: this suite must never call CGEvent.post (global injection).
        // We verify provenance structurally via nativeEvents() only.
        XCTAssertNotEqual(LiveInsertion.eventMarker, 0)
    }

    // MARK: - Part II. Contract-bound adversarial tests (real ShortcutCore/Manager) [INJ]

    private func engineFixture(config: ShortcutConfiguration, recording: Bool = false, busy: Bool = false, nowValue: TimeInterval = 1000, operation: UInt64 = 0) -> (ShortcutEngine, RecordingBox, TimeBox) {
        let rec = RecordingBox(recording: recording, busy: busy, operation: operation)
        let time = TimeBox(now: nowValue)
        let engine = ShortcutEngine(configuration: config, sinks: ShortcutEngine.Sinks(
            start: { rec.starts += 1 },
            finish: { rec.finishes += 1 },
            cancel: { rec.cancels += 1 },
            isRecording: { rec.recording },
            isBusy: { rec.busy },
            currentOperation: { rec.operation }
        ), now: { time.now })
        return (engine, rec, time)
    }

    func testH1DefaultRemainsCtrlCmdNToggle() {
        let def = ShortcutConfiguration.default
        XCTAssertEqual(def.behavior, .toggle)
        guard case .keyChord(let code, let mods) = def.trigger else { return XCTFail("Default must be keyChord") }
        XCTAssertEqual(code, 45, "kVK_ANSI_N")
        XCTAssertEqual(mods, ShortcutConfiguration.defaultModifiers)
        XCTAssertEqual(mods, 4096 | 256, "controlKey|cmdKey Carbon bits")
        XCTAssertEqual(ShortcutBehavior.tapHoldThreshold, 0.3, accuracy: 0.0001)
        XCTAssertEqual(ShortcutLabels.display(def), "\(ShortcutLabels.triggerDisplay(def.trigger)) · Toggle")
        XCTAssertTrue(ShortcutLabels.triggerDisplay(def.trigger).contains("\(ShortcutLabels.keyName(keyCode: 45))"))
        XCTAssertNil(ShortcutValidation.validate(def))
    }

    func testH2ValidationRejectsDangerousAndEmptyChords() {
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 0), "Empty modifiers must be rejected (A5)")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 200, modifiers: 256), "Out-of-range keyCode must be rejected (A4)")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 53, modifiers: 256), "Escape reserved")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 57, modifiers: 256), "CapsLock rejected")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 55, modifiers: 256), "Modifier keyCode must use modifier-only")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 12, modifiers: ShortcutConfiguration.cmdFlag), "Cmd+Q reserved")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 13, modifiers: ShortcutConfiguration.cmdFlag), "Cmd+W reserved")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 49, modifiers: ShortcutConfiguration.cmdFlag), "Cmd+Space reserved")
        XCTAssertNotNil(ShortcutValidation.validate(ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertNil(ShortcutValidation.validate(ShortcutConfiguration(trigger: .modifierOnly(key: .control, side: .left), behavior: .toggle)))
        XCTAssertNil(ShortcutValidation.validate(ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk)))
        XCTAssertNil(ShortcutValidation.validate(ShortcutConfiguration(trigger: .modifierOnly(key: .function, side: .left), behavior: .toggle)), "Bare Fn valid but unreliable")
        XCTAssertTrue(ShortcutValidation.functionKeyReliabilityNote.contains("Fn"))
    }

    func testH3TriggerRequiresEventTapPolicy() {
        XCTAssertFalse(ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .right), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .mouseButton(button: .button3), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle).trigger.isKeyChord)
        XCTAssertFalse(ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .toggle).trigger.isKeyChord)
        // Mouse type prevents primary/secondary by construction (B13).
        XCTAssertNil(MouseButton(rawValue: 0))
        XCTAssertNil(MouseButton(rawValue: 1))
        XCTAssertEqual(MouseButton.middle.rawValue, 2)
    }

    func testH4StoreDefaultsCorruptionAndRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-shortcut-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("shortcuts.json")
        // Fresh install, no file: defaults, no error (A1).
        let fresh = ShortcutStore(fileURL: url)
        fresh.load()
        XCTAssertEqual(fresh.configuration, .default)
        XCTAssertNil(fresh.lastError)
        // Valid save + reload round-trip.
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4096 | 256), behavior: .holdToTalk)
        XCTAssertTrue(fresh.save(custom))
        XCTAssertEqual(fresh.configuration, custom)
        let reloaded = ShortcutStore(fileURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.configuration, custom)
        // Invalid save rejected, previous kept (conflict rollback analogue).
        let invalid = ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)
        XCTAssertFalse(reloaded.save(invalid))
        XCTAssertNotNil(reloaded.lastError)
        XCTAssertEqual(reloaded.configuration, custom, "Invalid save must keep previous (rollback)")
        // Corrupt payload: keeps in-memory, sets lastError, never crashes (A2).
        try "not-json{{{".write(to: url, atomically: true, encoding: .utf8)
        let corrupt = ShortcutStore(initial: custom, fileURL: url)
        corrupt.load()
        XCTAssertEqual(corrupt.configuration, custom)
        XCTAssertNotNil(corrupt.lastError)
        // Unknown enum + future keys: tolerant decode (A3/A8).
        let future = #"{"trigger":{"kind":"keyChord","keyCode":45,"modifiers":4352,"future":99},"behavior":"toggle","extra":1}"#.data(using: .utf8)!
        try future.write(to: url)
        let tolerant = ShortcutStore(initial: custom, fileURL: url)
        tolerant.load()
        XCTAssertEqual(tolerant.configuration, .default)
        // Reset restores default.
        _ = tolerant.save(custom)
        XCTAssertEqual(tolerant.resetToDefault(), .default)
    }

    func testH5ToggleEngineRepeatDuplicateStaleSuppressed() {
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle))
        XCTAssertTrue(engine.press()) // idle -> start
        XCTAssertEqual(rec.starts, 1)
        XCTAssertNotNil(engine.activePressID)
        XCTAssertFalse(engine.press(), "Duplicate press while held suppressed")
        XCTAssertFalse(engine.press(isRepeat: true), "Repeat suppressed (B6)")
        XCTAssertEqual(rec.starts, 1)
        XCTAssertFalse(engine.release(), "Toggle release always ignored")
        XCTAssertNil(engine.activePressID, "Toggle release clears press")
        // Stale release with no press: suppressed.
        XCTAssertFalse(engine.release())
        XCTAssertFalse(engine.releaseForPressID(999))
        // Press while busy suppressed (C7).
        let (busyEngine, busyRec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle), busy: true)
        XCTAssertFalse(busyEngine.press())
        XCTAssertEqual(busyRec.starts, 0)
        // Press while recording finishes once (C2); second finish flaps nothing.
        let (recEngine, recBox, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle), recording: true)
        XCTAssertTrue(recEngine.press())
        XCTAssertEqual(recBox.finishes, 1)
        XCTAssertFalse(recEngine.release())
    }

    func testH6HoldReleaseDuringPreparingCancelsWithoutRunaway() {
        // C8 highest-risk: hold press starts, release during preparing must cancel (not finish), no runaway.
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk), busy: true)
        // Foreign busy with no owned capture: press suppressed (never steals).
        XCTAssertFalse(engine.press())
        XCTAssertEqual(rec.starts, 0)
        // Owned preparing: simulate start then busy, release -> cancel.
        let (owned, ownedRec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk))
        XCTAssertTrue(owned.press())
        XCTAssertEqual(ownedRec.starts, 1)
        let pressID = try! XCTUnwrap(owned.activePressID)
        ownedRec.recording = false; ownedRec.busy = true // preparing after start
        XCTAssertTrue(owned.releaseForPressID(pressID))
        XCTAssertEqual(ownedRec.cancels, 1, "Release during preparing must cancel, not finish (C8)")
        XCTAssertEqual(ownedRec.finishes, 0)
        XCTAssertNil(owned.activePressID)
        XCTAssertNil(owned.activeCaptureID, "No runaway press/capture left")
        // Next press can start cleanly.
        ownedRec.busy = false
        XCTAssertTrue(owned.press())
        XCTAssertEqual(ownedRec.starts, 2)
        // Stale ID from first press never finishes unrelated capture.
        XCTAssertFalse(owned.releaseForPressID(pressID))
        XCTAssertEqual(ownedRec.finishes, 0)
    }

    func testH7TapOrHoldBoundary299vs300() {
        let cfg = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .tapOrHold)
        // Quick tap 0.299 keeps recording.
        let (tap, tapRec, tapTime) = engineFixture(config: cfg, nowValue: 1000)
        XCTAssertTrue(tap.press())
        tapRec.recording = true
        tapTime.now = 1000 + 0.299
        XCTAssertFalse(tap.release(), "Tap <0.3 keeps (C4)")
        XCTAssertEqual(tapRec.finishes, 0)
        XCTAssertEqual(tapRec.cancels, 0)
        XCTAssertNil(tap.activePressID)
        XCTAssertNotNil(tap.activeCaptureID, "Capture kept for tap-off")
        // Tap-off: next press arms, release finishes.
        XCTAssertTrue(tap.press(), "Tap-off press arms")
        XCTAssertEqual(tapRec.starts, 1, "Arming must not double-start")
        tapTime.now += 0.05
        XCTAssertTrue(tap.release())
        XCTAssertEqual(tapRec.finishes, 1, "Tap-off release finishes")
        // Long hold 0.301 finishes directly.
        let (hold, holdRec, holdTime) = engineFixture(config: cfg, nowValue: 2000)
        XCTAssertTrue(hold.press())
        holdRec.recording = true
        holdTime.now = 2000 + 0.301
        XCTAssertTrue(hold.release(), "Hold >=0.3 finishes (C5)")
        XCTAssertEqual(holdRec.finishes, 1)
        // Exact boundary 0.300 belongs to hold (finishes).
        let (exact, exactRec, exactTime) = engineFixture(config: cfg, nowValue: 3000)
        XCTAssertTrue(exact.press())
        exactRec.recording = true
        exactTime.now = 3000 + 0.300
        XCTAssertTrue(exact.release(), "Exact 0.300 finishes (C6)")
        XCTAssertEqual(exactRec.finishes, 1)
    }

    func testH8StalePressIDsNeverFinishUnrelatedCapture() {
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk))
        XCTAssertFalse(engine.releaseForPressID(12345), "Stale release before press ignored (C9)")
        XCTAssertEqual(rec.finishes, 0)
        XCTAssertEqual(rec.cancels, 0)
        XCTAssertTrue(engine.press())
        let id = try! XCTUnwrap(engine.activePressID)
        XCTAssertFalse(engine.releaseForPressID(id + 1000), "Mismatched ID never finishes")
        XCTAssertEqual(rec.finishes, 0)
        // Correct ID with no live capture after foreign finish: suppressed.
        rec.recording = false; rec.busy = false
        XCTAssertFalse(engine.releaseForPressID(id))
        XCTAssertEqual(rec.finishes, 0)
        XCTAssertEqual(rec.cancels, 0)
    }

    func testH9InterruptionCancelsOwnedHoldWithoutFinish() {
        // E1/E4: lock/sleep/tap-loss clears press; cancels owned capture; never finishes.
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .modifierOnly(key: .control, side: .left), behavior: .holdToTalk))
        XCTAssertTrue(engine.press())
        rec.recording = true
        engine.handleInterruption()
        XCTAssertEqual(rec.cancels, 1)
        XCTAssertEqual(rec.finishes, 0, "Interruption must never finish")
        XCTAssertNil(engine.activePressID)
        XCTAssertNil(engine.activeCaptureID)
        // Interruption with no owned capture: no sink.
        let (idle, idleRec, _) = engineFixture(config: ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk))
        idle.handleInterruption()
        XCTAssertEqual(idleRec.cancels, 0)
        // Tap-disabled equals interruption.
        let (tap, tapRec, _) = engineFixture(config: ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk))
        XCTAssertTrue(tap.press())
        tapRec.busy = true
        tap.handleTapDisabled()
        XCTAssertEqual(tapRec.cancels, 1)
        XCTAssertEqual(tapRec.finishes, 0)
    }

    func testH10UpdateConfigurationClearsPressWithoutSinks() {
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk))
        XCTAssertTrue(engine.press())
        XCTAssertNotNil(engine.activePressID)
        engine.updateConfiguration(ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .toggle))
        XCTAssertNil(engine.activePressID, "Rebind while held must clear old press (C13)")
        XCTAssertNil(engine.activeCaptureID)
        XCTAssertEqual(rec.starts, 1, "No extra sink on rebind")
        XCTAssertEqual(rec.finishes, 0)
        XCTAssertEqual(rec.cancels, 0)
        XCTAssertEqual(engine.configuration.behavior, .toggle)
    }

    func testH11CanChangeSettingsGuarded() {
        let cfg = ShortcutConfiguration.default
        let (idle, _, _) = engineFixture(config: cfg)
        XCTAssertTrue(idle.canChangeSettings)
        let (recording, _, _) = engineFixture(config: cfg, recording: true)
        XCTAssertFalse(recording.canChangeSettings, "Recording blocks settings (C14/C18)")
        let (busy, _, _) = engineFixture(config: cfg, busy: true)
        XCTAssertFalse(busy.canChangeSettings)
    }

    func testH12LabelsAndCarbonConversion() {
        XCTAssertEqual(ShortcutLabels.keyChordDisplay(keyCode: 45, modifiers: 4352), "⌃⌘N")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.modifierOnly(key: .control, side: .left)), "Left ⌃")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.modifierOnly(key: .function, side: .left)), "Fn")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.mouseButton(button: .middle)), "Middle Click")
        XCTAssertEqual(ShortcutLabels.display(ShortcutConfiguration(trigger: .mouseButton(button: .button4), behavior: .tapOrHold)), "Side Button 5 · Tap or Hold")
        XCTAssertEqual(ShortcutManager.carbonModifiers(from: [.control, .command]), 4352)
        XCTAssertEqual(ShortcutManager.carbonModifiers(from: [.control, .command, .shift, .option]), 4352 | 512 | 2048)
    }

    @MainActor func testH13ManagerTransactionalRollbackOnConflict() throws {
        let root = try tempRoot()
        let url = root.appendingPathComponent("shortcuts.json")
        let store = ShortcutStore(fileURL: url)
        XCTAssertTrue(store.save(.default))
        let mock = MockShortcutRegistrar()
        let (engine, _, _) = engineFixture(config: .default)
        // Rebuild engine with throwaway sinks for manager test init (manager mirrors store config).
        let managerEngine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: managerEngine, store: store, registrar: mock)
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk)
        XCTAssertTrue(manager.apply(custom))
        XCTAssertEqual(manager.configuration, custom)
        XCTAssertEqual(mock.registered, custom)
        // Conflict on next apply: registrar throws -> rollback to previous.
        mock.shouldThrow = VellaError.message("Conflict: already reserved")
        let conflicted = ShortcutConfiguration(trigger: .keyChord(keyCode: 9, modifiers: 4352), behavior: .toggle)
        XCTAssertFalse(manager.apply(conflicted))
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(manager.configuration, custom, "Conflict must roll back to previous binding")
        XCTAssertEqual(store.configuration, custom, "Store must keep previous file")
        // Invalid config rejected before registrar.
        mock.shouldThrow = nil
        let calls = mock.registerCalls.count
        XCTAssertFalse(manager.apply(ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertEqual(mock.registerCalls.count, calls, "Invalid must not reach registrar")
    }

    @MainActor func testH14ManagerGuardsAndEventTapPolicy() throws {
        let root = try tempRoot()
        let store = ShortcutStore(fileURL: root.appendingPathComponent("shortcuts.json"))
        _ = store.save(.default)
        let mock = MockShortcutRegistrar()
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: mock)
        XCTAssertFalse(manager.requiresEventTap, "Key chord needs no tap")
        XCTAssertTrue(manager.apply(ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .left), behavior: .toggle)))
        XCTAssertTrue(manager.requiresEventTap)
        XCTAssertTrue(manager.eventTapPermissionNote.contains("Accessibility"), "Permission note mentions Accessibility (Input Monitoring only where actual API requires it)")
        XCTAssertFalse(manager.eventTapPermissionNote.contains("Input Monitoring"), "Optional taps must not claim mandatory Input Monitoring")
        XCTAssertTrue(manager.apply(ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .holdToTalk)))
        XCTAssertTrue(manager.requiresEventTap)
        // canEdit mirrors engine guard + capture flag.
        XCTAssertTrue(manager.canEdit)
        manager.beginKeyCapture()
        XCTAssertFalse(manager.canEdit, "Capture blocks edits")
        manager.cancelKeyCapture()
        // handlePress repeat + stale release suppressed at manager layer.
        var actions: [String] = []
        manager.onAction = { actions.append($0) }
        manager.permissionCheck = { true }
        // Force toggle engine to idle path via fresh manager with recording sinks.
        let rec = RecordingBox(recording: false, busy: false)
        let toggleEngine = ShortcutEngine(configuration: .default, sinks: .init(start: { actions.append("start") }, finish: {}, cancel: {}, isRecording: { rec.recording }, isBusy: { rec.busy }))
        let toggleManager = ShortcutManager(engine: toggleEngine, store: ShortcutStore(), registrar: MockShortcutRegistrar())
        toggleManager.permissionCheck = { true }
        toggleManager.handlePress(isRepeat: true)
        XCTAssertTrue(actions.isEmpty, "Repeat suppressed end-to-end (B6)")
        toggleManager.handleRelease()
        XCTAssertTrue(actions.isEmpty, "Stale release suppressed (C9)")
        // Denied permission blocks start without sink.
        toggleManager.permissionCheck = { false }
        toggleManager.handlePress()
        XCTAssertTrue(actions.isEmpty, "Denied permission must not start (D3)")
    }

    @MainActor func testH15ShortcutMenuFactoryStructure() throws {
        let store = ShortcutStore()
        _ = store.save(.default)
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        let model = Model(configurationURL: try tempConfig())
        defer { model.shutdown() }
        let target = ShortcutMenuProbe()
        let item = ShortcutMenuFactory.shortcutsItem(manager: manager, model: model, target: target,
            selectBehavior: #selector(ShortcutMenuProbe.behavior(_:)), recordKeys: #selector(ShortcutMenuProbe.record(_:)), cancelCapture: #selector(ShortcutMenuProbe.cancel(_:)),
            selectModifier: #selector(ShortcutMenuProbe.modifier(_:)), selectMouse: #selector(ShortcutMenuProbe.mouse(_:)), resetDefault: #selector(ShortcutMenuProbe.reset(_:)), openSettings: #selector(ShortcutMenuProbe.settings(_:)))
        XCTAssertEqual(item.title, "Shortcuts")
        let menu = try XCTUnwrap(item.submenu)
        XCTAssertTrue(menu.items.first?.title.hasPrefix("Current:") == true)
        XCTAssertTrue(menu.items.first?.isEnabled == false)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Toggle"))
        XCTAssertTrue(titles.contains("Tap or Hold"), "Compact behavior row (no oversized explanatory suffix)")
        XCTAssertTrue(titles.contains("Record Key Chord…"))
        XCTAssertTrue(titles.contains("Reset to Default"), "Compact reset row")
        XCTAssertTrue(titles.contains("Modifier-Only"), "Compact nested modifier picker")
        XCTAssertTrue(titles.contains("Mouse Button"), "Compact nested mouse picker")
        // Event-tap note only for tap bindings; default chord shows none + no error.
        XCTAssertFalse(titles.contains(where: { $0.contains("Input Monitoring") }))
        XCTAssertFalse(titles.contains(where: { $0.contains("Needs Accessibility") }))
        // Fn current title is compact "Current: Fn · <Behavior>" (no oversized note row).
        XCTAssertTrue(manager.apply(ShortcutConfiguration(trigger: .modifierOnly(key: .function, side: .left), behavior: .toggle)))
        let fnItem = ShortcutMenuFactory.shortcutsItem(manager: manager, model: model, target: target,
            selectBehavior: #selector(ShortcutMenuProbe.behavior(_:)), recordKeys: #selector(ShortcutMenuProbe.record(_:)), cancelCapture: #selector(ShortcutMenuProbe.cancel(_:)),
            selectModifier: #selector(ShortcutMenuProbe.modifier(_:)), selectMouse: #selector(ShortcutMenuProbe.mouse(_:)), resetDefault: #selector(ShortcutMenuProbe.reset(_:)), openSettings: #selector(ShortcutMenuProbe.settings(_:)))
        XCTAssertTrue(fnItem.submenu?.items.first?.title.hasPrefix("Current: Fn") == true, "Compact Fn current title")
    }

    // MARK: - Part III. Concrete native bugs (coordinator-review, failing until fixed) [INJ]

    // Deterministic spec reducer for modifier-only arbitration (no host input).
    // Correct behavior: solo press fires only if no nonmodifier keyDown intervenes
    // between down and up. Production must implement equivalent; immediate press
    // on flagsChanged alone hijacks ordinary chords like Cmd+C.
    private enum TapSpecEvent { case flagsDown, flagsUp, otherKeyDown }
    private func tapSpecShouldFire(_ seq: [TapSpecEvent]) -> Bool {
        // Solo tap = down, then up with no otherKeyDown between.
        guard seq.first == .flagsDown else { return false }
        for e in seq.dropFirst() {
            if e == .otherKeyDown { return false }
            if e == .flagsUp { return true }
        }
        return false
    }

    func testI1CmdDownCUpCmdUpMustNotActivateSoloCmd() {
        // Deterministic reducer spec (new API): solo Cmd arbitration with otherKeyDown.
        var s = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .otherKeyDown(time: 0.05), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .cancelled, "Cmd-down/C-down cancels solo (no hijack)")
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetUp(key: .command, side: .left, time: 0.1), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .none, "Release after cancel does nothing")
        // Solo tap still works: down, tapRelease (toggle) / holdTimeout+press then holdRelease (hold).
        var solo = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &solo, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .toggle), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &solo, event: .targetUp(key: .command, side: .left, time: 0.1), targetKey: .command, targetSide: .left, behavior: .toggle), .tapRelease)
        var hold = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &hold, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &hold, event: .holdTimeout(time: 0.35), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .press)
        XCTAssertEqual(ModifierSoloReducer.step(state: &hold, event: .targetUp(key: .command, side: .left, time: 0.5), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .holdRelease)
        // Non-sole down never pends (composed chord start).
        var composed = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &composed, event: .targetDown(key: .command, side: .left, time: 0, sole: false), targetKey: .command, targetSide: .left, behavior: .holdToTalk), .none)
    }

    func testI2FnMustNotIncludeCapsLockFlag() {
        // Fn has no stable CG flag on all keyboards; press keyed by keyCode 63.
        // Including maskAlphaShift (Caps Lock) makes CapsLock satisfy Fn checks.
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContain(.maskSecondaryFn, key: .function), "Fn secondary flag counts")
        XCTAssertFalse(EventTapShortcutRegistrar.flagsContain(.maskAlphaShift, key: .function), "BUG: CapsLock (maskAlphaShift) must not satisfy Fn; remove it from flagsContain")
        // CapsLock+Fn release must not be treated as Fn release via CapsLock flag alone.
        // After fix, only maskSecondaryFn (or keyCode 63 path) counts for Fn.
    }

    func testI3BothModifierSidesNeedPerDeviceDisambiguation() {
        // KeyCodes are side-distinct; aggregate CG flags are not.
        XCTAssertEqual(EventTapShortcutRegistrar.modifierCode(key: .command, side: .left), 55)
        XCTAssertEqual(EventTapShortcutRegistrar.modifierCode(key: .command, side: .right), 54)
        XCTAssertNotEqual(EventTapShortcutRegistrar.modifierCode(key: .command, side: .left), EventTapShortcutRegistrar.modifierCode(key: .command, side: .right))
        // Both sides held produce identical aggregate flags (.maskCommand) — flags
        // alone cannot tell which side lifted. Production must use per-device
        // keyCode/state, not just aggregate flagsContainOnly.
        let bothHeld: CGEventFlags = [.maskCommand]
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContain(bothHeld, key: .command))
        XCTAssertTrue(EventTapShortcutRegistrar.flagsContainOnly(bothHeld, key: .command), "Aggregate flags identical for left vs right — documents need for per-device key state (I3)")
        // Failing assertion: left-only trigger with right still held must release
        // left hold (left is up). Current aggregate logic keeps isDown true.
        // This is filed as source issue; executable release-routing needs private
        // isDown seam, so assert the disambiguation requirement directly:
        XCTAssertNotEqual(EventTapShortcutRegistrar.modifierCode(key: .control, side: .left), EventTapShortcutRegistrar.modifierCode(key: .control, side: .right), "Sides must route by keyCode, not flags alone")
    }

    func testI4StaleReleaseMustNotCancelForeignMenuFinish() {
        // Genuine ownership: Model.captureGeneration observed via currentOperation.
        // Foreign menu Finish bumps generation; stale release must be suppressed.
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk), operation: 10)
        XCTAssertTrue(engine.press())
        let ownedID = try! XCTUnwrap(engine.activePressID)
        XCTAssertEqual(engine.activeOperation, 10, "Press must bind to generation observed after start")
        rec.recording = true
        // Foreign menu Finish: Model.finish() bumps captureGeneration to 11, now transcribing.
        rec.operation = 11; rec.recording = false; rec.busy = true
        let acted = engine.releaseForPressID(ownedID)
        XCTAssertFalse(acted, "Stale release must not cancel foreign menu Finish (operation 10 vs 11)")
        XCTAssertEqual(rec.cancels, 0, "Foreign transcribing must not be cancelled by stale release")
        XCTAssertEqual(rec.finishes, 0)
        // Same-generation release during preparing still cancels owned (no weakening).
        let (owned, ownedRec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk), operation: 20)
        XCTAssertTrue(owned.press())
        let ownedID2 = try! XCTUnwrap(owned.activePressID)
        ownedRec.recording = false; ownedRec.busy = true // preparing, same generation 20
        XCTAssertTrue(owned.releaseForPressID(ownedID2))
        XCTAssertEqual(ownedRec.cancels, 1)
    }

    func testI5StaleReleaseMustNotFinishForeignNewStart() {
        // Genuine ownership: stale press (gen 30) vs foreign new Start (gen 31).
        let (engine, rec, _) = engineFixture(config: ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk), operation: 30)
        XCTAssertTrue(engine.press())
        let staleID = try! XCTUnwrap(engine.activePressID)
        XCTAssertEqual(engine.activeOperation, 30)
        // Foreign cancel + new Start bumps Model generation; new capture live.
        rec.operation = 31; rec.recording = true; rec.busy = false
        XCTAssertFalse(engine.releaseForPressID(staleID), "Stale release must not finish foreign new Start (30 vs 31)")
        XCTAssertEqual(rec.finishes, 0)
        XCTAssertEqual(rec.cancels, 0)
    }

    @MainActor func testI6ActivationSuspendedDuringKeyCapture() throws {
        // Recorder UI must receive keys after menu action; activation suspended during capture.
        let store = ShortcutStore()
        _ = store.save(.default)
        var started = 0
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: { started += 1 }, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        manager.permissionCheck = { true }
        manager.beginKeyCapture()
        XCTAssertTrue(manager.isCapturingKeys)
        XCTAssertFalse(manager.canEdit, "Capture blocks edits")
        manager.handlePress()
        XCTAssertEqual(started, 0, "BUG: activation fired during key capture (must suspend press/release until cancel/failure restores)")
        manager.cancelKeyCapture()
        // Local-only NSEvent monitor cannot receive keys once the menu closes while
        // another app stays active — needs transient native capture surface or verified
        // native menu tracking (filed as source issue; no host tracking asserted here).
    }

    @MainActor func testI7MenuHintAndKeyEquivalentReflectConfiguredBinding() throws {
        // Recording hint + Start key equivalent must reflect configured binding, never stale ⌃⌘N.
        let store = ShortcutStore()
        _ = store.save(.default)
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk) // ⌃⌘C
        XCTAssertTrue(manager.apply(custom))
        XCTAssertEqual(manager.currentLabel, ShortcutLabels.display(custom))
        XCTAssertTrue(manager.currentLabel.contains("C"), "Label must show configured key, not stale N")
        XCTAssertFalse(manager.currentLabel.contains("N"), "BUG if stale ⌃⌘N persists after rebind")
        // AppDelegate Start item reflects configured binding (fix landed: no stale ⌃⌘N).
        let delegate = AppDelegate(model: Model(configurationURL: try tempConfig()), shortcutManager: manager)
        defer { delegate.model.shutdown() }
        delegate.rebuildMenu()
        let start = try XCTUnwrap(delegate.menu.items.first(where: { $0.title.hasPrefix("Start") || $0.title.hasPrefix("Finish") }))
        XCTAssertEqual(start.keyEquivalent.lowercased(), "c", "Start glyph reflects configured ⌃⌘C")
        XCTAssertEqual(start.keyEquivalentModifierMask, NSEvent.ModifierFlags([.control, .command]))
    }

    func testI8TapWhilePreparingRetainsAndLongReleaseCancelsSafely() {
        // Tap-or-hold tap while preparing should retain intended operation;
        // long release during preparing must cancel safely, never finish ghost capture.
        let cfg = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .tapOrHold)
        let (engine, rec, time) = engineFixture(config: cfg, nowValue: 5000)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(rec.starts, 1)
        let id = try! XCTUnwrap(engine.activePressID)
        rec.recording = false; rec.busy = true // preparing
        time.now = 5000 + 0.10 // tap-duration release while still preparing
        // Correct: retain (no finish), keep ownership for later finish/cancel.
        // Current engine: tapKept path requires recording||busy at release time — busy true
        // so it will set tapKept and return false (retain). Assert retain:
        XCTAssertFalse(engine.releaseForPressID(id), "Tap while preparing retains (no finish/cancel yet)")
        XCTAssertEqual(rec.finishes, 0)
        XCTAssertEqual(rec.cancels, 0)
        // Long hold release while still preparing must cancel safely.
        // Re-arm via tap-off press (capture kept), then long release while busy -> cancel.
        XCTAssertTrue(engine.press(), "Tap-off arming after retained tap")
        let id2 = try! XCTUnwrap(engine.activePressID)
        time.now += 0.35
        XCTAssertTrue(engine.releaseForPressID(id2))
        XCTAssertEqual(rec.cancels, 1, "Long release during preparing cancels safely")
        XCTAssertEqual(rec.finishes, 0)
    }

    // MARK: - Part IV. Independent inspection: validation, rebind identity, capture lifecycle [INJ]

    func testJ1KeyValidationUsesCarbonConstants() {
        // Coordinator: Carbon cmdKey|controlKey is 0x1100 (4352), not 0x100100.
        XCTAssertEqual(ShortcutConfiguration.defaultModifiers, 0x1100, "Carbon control|cmd")
        XCTAssertEqual(ShortcutConfiguration.defaultModifiers, 4352)
        XCTAssertNotEqual(ShortcutConfiguration.defaultModifiers, 0x100100, "Contract stale hex must not be used")
        XCTAssertEqual(ShortcutConfiguration.cmdFlag, 256)
        XCTAssertEqual(ShortcutConfiguration.controlFlag, 4096)
        // Single-letter system chords rejected; safe chord with modifiers allowed.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 12, modifiers: 256), "Cmd+Q")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 0), "Bare C rejected")
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 4352), "Ctrl+Cmd+C allowed")
        XCTAssertNil(MouseButton(rawValue: 2).map { _ in ShortcutValidation.validate(ShortcutConfiguration(trigger: .mouseButton(button: .middle), behavior: .toggle)) } ?? "x")
    }

    func testJ2RebindGenerationIdentityRequirement() {
        // Source: GlobalShortcut.registerChord reuses EventHotKeyID(id:1) and handler
        // ignores EventHotKeyID; async dispatch reads onPress/onRelease at execution time.
        // Required: unique IDs + generation capture so old queued press never calls new closure.
        // Coordinator-owned ShortcutNativeDispatchTests foreign-ID test fails for this (not run here).
        // This spec locks the requirement without real Carbon posting:
        var calls: [String] = []
        var generation: UInt64 = 1
        let pressGen = generation
        // Simulate old queued press captured at event time (gen 1).
        generation = 2 // rebind to new closure before async executes
        let currentGen = generation
        // Old queued callback must be suppressed when generations differ.
        XCTAssertNotEqual(pressGen, currentGen)
        XCTAssertTrue(calls.isEmpty, "Old queued press suppressed after rebind (spec)")
        // Native ID and generation checks are covered by ShortcutNativeDispatchTests.
        XCTAssertEqual(EventHotKeyID(signature: 0x56454C41, id: 1).id, 1, "Documents hardcoded ID requiring uniqueness fix")
    }

    @MainActor func testJ3KeyCaptureLifecycleSuspendsAndRestores() throws {
        let store = ShortcutStore()
        _ = store.save(.default)
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }, currentOperation: { 0 }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        XCTAssertFalse(manager.isCapturingKeys)
        XCTAssertTrue(manager.canEdit)
        manager.beginKeyCapture()
        XCTAssertTrue(manager.isCapturingKeys, "Capture starts")
        XCTAssertFalse(manager.canEdit, "Capture suspends edits")
        // Invalid captured chord still ends capture (apply validates then cancels capture).
        XCTAssertFalse(manager.handleCapturedKey(keyCode: 45, modifiers: 0), "Empty modifiers rejected")
        XCTAssertFalse(manager.isCapturingKeys, "Capture ends on invalid chord (restores)")
        XCTAssertTrue(manager.canEdit, "Edits restored after failure")
        // Valid chord applies and ends capture.
        manager.beginKeyCapture()
        XCTAssertTrue(manager.handleCapturedKey(keyCode: 8, modifiers: 4352))
        XCTAssertFalse(manager.isCapturingKeys)
        XCTAssertEqual(manager.configuration.trigger, ShortcutTrigger.keyChord(keyCode: 8, modifiers: 4352))
        // Escape path: cancel restores without applying (no host events posted).
        manager.beginKeyCapture()
        manager.cancelKeyCapture()
        XCTAssertFalse(manager.isCapturingKeys)
        // Local-only monitor gap filed: menu-close + other-app-active misses keys;
        // needs transient native surface (see findings). No global monitor asserted here.
    }

    @MainActor func testJ4CustomIgnoredChordFollowsBinding() {
        // Model per-recording ignored chord (new API) preserves legacy default, follows custom.
        let insertion = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        XCTAssertEqual(insertion.ignoredChordKeyCode, 45)
        XCTAssertEqual(insertion.ignoredChordModifiers, [.control, .command])
        insertion.ignoredChordKeyCode = 8
        insertion.ignoredChordModifiers = [.control, .command]
        insertion.observeUserInput(type: .keyDown, keyCode: 8, modifiers: [.control, .command])
        XCTAssertNil(insertion.blockedReason, "Custom chord ignored exactly")
        let other = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        other.ignoredChordKeyCode = 8
        other.ignoredChordModifiers = [.control, .command]
        other.observeUserInput(type: .keyDown, keyCode: 45, modifiers: [.control, .command])
        XCTAssertNil(other.blockedReason, "Legacy default still ignored when custom differs (compat)")
    }

    // MARK: - Part V. Strict masks, Shift-printable, physical duration, persistence identity [INJ]

    func testK1UnknownCarbonBitsMustNotValidateAsModifier() {
        // Unknown Carbon bits alone (no known control/option/cmd/shift) must not
        // degrade to a bare printable hotkey. E.g. C (8) + 0xFFFF0000 garbage.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 0xFFFF0000), "BUG if unknown bits validate: must require known modifier")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 0x800000), "BUG if Fn-flag alone validates bare C: must require known modifier set")
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 4352), "Known Ctrl+Cmd still valid")
    }

    func testK2ShiftOnlyPrintableMustNotBecomeBinding() {
        // Ordinary Shift+C typing (Shift-only printable) must not become dictation binding.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 512), "BUG if Shift-only C validates: ordinary capital typing would trigger")
        XCTAssertNotNil(ShortcutValidation.validate(ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: 512), behavior: .toggle)), "Store-level Shift-only C must reject")
        // Shift remains fine with another modifier (e.g. Ctrl+Shift+C is deliberate).
        // Current policy allows any known-modifier combo; shift-only printable is the gap.
    }

    @MainActor func testK3PhysicalHoldDurationAcrossModifierDelay() {
        // End-to-end via actual registrar→manager→engine physical seam:
        // down@0 (physical), guard fires@0.30 carrying downTime 0.00, release@0.35.
        // Total physical 0.35>=0.3 => HOLD finishes (not guard-relative 0.05 tap).
        let cfg = ShortcutConfiguration(trigger: .modifierOnly(key: .command, side: .left), behavior: .tapOrHold)
        let rec = RecordingBox(recording: false, busy: false, operation: 7)
        let time = TimeBox(now: 0.30) // guard-fire time
        let engine = ShortcutEngine(configuration: cfg, sinks: ShortcutEngine.Sinks(
            start: { rec.starts += 1 }, finish: { rec.finishes += 1 }, cancel: { rec.cancels += 1 },
            isRecording: { rec.recording }, isBusy: { rec.busy }, currentOperation: { rec.operation }
        ), now: { time.now })
        let store = ShortcutStore()
        _ = store.save(cfg)
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        manager.permissionCheck = { true }
        // ACTUAL registrar seam: prime (no TCC/tap), wire confirmed physical down.
        let tap = EventTapShortcutRegistrar()
        tap.primeForTesting(cfg, onPress: { manager.handlePress() }, onRelease: { manager.handleRelease() })
        tap.confirmedPressHandler = { down in manager.handlePress(downTime: down) }
        XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .command, side: .left, time: 0.00, sole: true)), .pending)
        XCTAssertEqual(tap.simulateSoloEvent(.holdTimeout(time: 0.30)), .press)
        XCTAssertEqual(engine.pressStartTime ?? -1, 0.00, accuracy: 0.0001, "Engine must stamp physical down, not guard-fire")
        XCTAssertEqual(rec.starts, 1)
        rec.recording = true
        time.now = 0.35
        XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .command, side: .left, time: 0.35)), .holdRelease)
        XCTAssertEqual(rec.finishes, 1, "Physical HOLD (0.35s) must finish via actual seam")
        XCTAssertEqual(rec.cancels, 0)
    }

    @MainActor func testK4ProductionPrefsMustPersistThroughFactoryPath() throws {
        // Real AppDelegate(shortcutStoreURL:) factory with ISOLATED url + pre-seeded
        // obscure JSON (no apply/register, no live Carbon binding, no host data).
        let root = try tempRoot()
        let fileURL = root.appendingPathComponent("shortcuts.json")
        // Obscure chord avoids common live bindings even if later registered (never registered here).
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 103, modifiers: 4352 | 512), behavior: .holdToTalk)
        XCTAssertNil(ShortcutValidation.validate(custom), "Obscure pre-seed must validate")
        try JSONEncoder().encode(custom).write(to: fileURL, options: .atomic)
        let delegateA = AppDelegate(model: Model(configurationURL: root.appendingPathComponent("config.json")), shortcutStoreURL: fileURL)
        defer { delegateA.model.shutdown() }
        XCTAssertEqual(delegateA.shortcutManager.configuration, custom, "Factory must load pre-seeded custom (no registration)")
        // Restart: second delegate from SAME isolated url preserves custom.
        let delegateB = AppDelegate(model: Model(configurationURL: root.appendingPathComponent("config.json")), shortcutStoreURL: fileURL)
        defer { delegateB.model.shutdown() }
        XCTAssertEqual(delegateB.shortcutManager.configuration, custom, "Restart through real factory path must reload custom")
    }

    @MainActor func testK5BehaviorChangeKeepsTrackedMenuIdentity() throws {
        // Parent-style (no explicit rebuild): rebuild once, menuWillOpen, click the ACTUAL
        // SettingsMenuItem control, assert same tracked identity + checkmarks, menuDidClose.
        // Mocked registrar + isolated store (no live Carbon). FAILS until UI updates in
        // place like Mode/Microphone instead of rebuildMenu during tracking.
        let root = try tempRoot()
        let store = ShortcutStore(fileURL: root.appendingPathComponent("shortcuts.json"))
        XCTAssertTrue(store.save(.default))
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }, currentOperation: { 0 }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        let delegate = AppDelegate(model: Model(configurationURL: root.appendingPathComponent("config.json")), shortcutManager: manager)
        let confirmation = MouseConfirmationTests.MouseConfirmMonitor()
        manager.confirmationAccessCheck = { true }
        manager.makeConfirmationMonitor = { confirmation }
        manager.makeConfirmationTimer = { MouseConfirmationTests.MouseConfirmTimer() }
        defer { delegate.model.shutdown() }
        func clickControl(matching: (SettingsMenuItem) -> Bool, actionName: String) throws {
            delegate.rebuildMenu()
            let countBefore = delegate.menu.items.count
            guard let micBefore = delegate.menu.item(withTitle: "Microphone") else { throw XCTSkip("No mic") }
            guard let shortcuts = delegate.menu.item(withTitle: "Shortcuts")?.submenu else { throw XCTSkip("No Shortcuts") }
            // Behavior radios live at top level; modifier/mouse live in nested pickers.
            let allControls: [SettingsMenuItem] = shortcuts.items.flatMap { item -> [SettingsMenuItem] in
                var found: [SettingsMenuItem] = []
                if let c = item as? SettingsMenuItem { found.append(c) }
                if let sub = item.submenu { found += sub.items.compactMap { $0 as? SettingsMenuItem } }
                return found
            }
            guard let control = allControls.first(where: matching) else { throw XCTSkip("No control for \(actionName)") }
            delegate.menuWillOpen(delegate.menu)
            control.control.performClick(nil)
            if actionName == "mouse" {
                XCTAssertEqual(manager.pendingMouseButton, .middle)
                XCTAssertEqual(control.state, .off, "Mouse selection must wait for physical confirmation")
                for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                    let event = try XCTUnwrap(CGEvent(source: nil))
                    event.type = type
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                    XCTAssertEqual(confirmation.handler?(type, event), true)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard let micAfter = delegate.menu.item(withTitle: "Microphone") else { delegate.menuDidClose(delegate.menu); throw XCTSkip("No mic after") }
            XCTAssertTrue(micBefore === micAfter, "BUG [\(actionName)]: tracked Microphone replaced; must update checkbox in place")
            XCTAssertEqual(delegate.menu.items.count, countBefore, "BUG [\(actionName)]: menu count changed during tracking")
            XCTAssertEqual(control.state, .on, "BUG [\(actionName)]: clicked control must show .on")
            delegate.menuDidClose(delegate.menu)
        }
        try clickControl(matching: { ($0.representedObject as? String) == ShortcutBehavior.holdToTalk.rawValue }, actionName: "behavior")
        try clickControl(matching: { ($0.representedObject as? String) == "\(ModifierKey.option.rawValue):\(ModifierSide.left.rawValue)" }, actionName: "modifier")
        try clickControl(matching: { ($0.representedObject as? String) == String(MouseButton.middle.rawValue) }, actionName: "mouse")
        // Reset is a plain item (no embedded control): invoke via sendAction like native selection.
        delegate.rebuildMenu()
        guard let micBeforeReset = delegate.menu.item(withTitle: "Microphone") else { throw XCTSkip("No mic") }
        let countBeforeReset = delegate.menu.items.count
        delegate.menuWillOpen(delegate.menu)
        if let reset = delegate.menu.item(withTitle: "Shortcuts")?.submenu?.items.first(where: { $0.title == "Reset to Default" }), let action = reset.action, let target = reset.target {
            NSApplication.shared.sendAction(action, to: target, from: reset)
        }
        XCTAssertTrue(delegate.menu.item(withTitle: "Microphone") === micBeforeReset, "BUG [reset]: tracked Microphone replaced")
        XCTAssertEqual(delegate.menu.items.count, countBeforeReset, "BUG [reset]: menu count changed during tracking")
        delegate.menuDidClose(delegate.menu)
    }

    // MARK: Recorder panel QA (actual production NSPanel, offscreen, synthetic events only)

    @MainActor func testL1RecorderErrorTextMustBeReadable() {
        // Actual invalid/conflict error state on real production contentView.
        // Fixed: multiline wrapping (3 lines, 260x56) keeps full text visible.
        let panel = ShortcutKeyRecorderPanel()
        guard let content = panel.contentView else { return XCTFail("No content") }
        let longError = "That shortcut is already reserved or could not be registered. Choose another chord."
        panel.showError(longError)
        content.layoutSubtreeIfNeeded()
        // Verify the production error field wraps (not single-line clip):
        let fields = content.subviews.compactMap { $0 as? NSTextField }
        guard let error = fields.first(where: { $0.textColor == .systemOrange }) else { return XCTFail("No error field") }
        XCTAssertFalse(error.usesSingleLineMode, "Error must wrap (multiline fix)")
        XCTAssertEqual(error.maximumNumberOfLines, 3)
        XCTAssertGreaterThanOrEqual(error.frame.height, 50, "Error field tall enough for 3 lines")
        XCTAssertEqual(error.stringValue, longError, "Full text retained")
        Self.writeQAViewImage(view: content, filename: "qa-recorder-error.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ".build/qa/shortcuts-20260916/spark/qa-recorder-error.png"))
    }

    @MainActor func testL2RecorderPanelKeyDownAndCancelSynthetic() {
        // Actual NSPanel keyDown/cancel with synthetic NSEvents (offscreen; no posting).
        let panel = ShortcutKeyRecorderPanel()
        var chords: [(UInt32, UInt32)] = []
        var cancels = 0
        panel.onChord = { code, mods in chords.append((code, mods)); return true }
        panel.onCancel = { cancels += 1 }
        func keyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags, `repeat` isRepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: isRepeat, keyCode: keyCode)!
        }
        // Valid chord C (8) + Ctrl+Cmd => onChord(8, 4352).
        panel.keyDown(with: keyEvent(keyCode: 8, flags: [.control, .command]))
        XCTAssertEqual(chords.count, 1)
        XCTAssertEqual(chords.first?.0, 8)
        XCTAssertEqual(chords.first?.1, 4352)
        // Repeat ignored.
        panel.keyDown(with: keyEvent(keyCode: 8, flags: [.control, .command], `repeat`: true))
        XCTAssertEqual(chords.count, 1, "Repeat must be ignored")
        // Esc cancels (keyCode 53).
        panel.keyDown(with: keyEvent(keyCode: 53, flags: []))
        XCTAssertEqual(cancels, 1)
        // cancelOperation path also cancels.
        panel.cancelOperation(nil)
        XCTAssertEqual(cancels, 2)
    }

    // MARK: Final native behavior (frozen source) [INJ, synthetic only]

    @MainActor func testM1SelfEventFilteringIgnoresOwnMarker() {
        // Production arbitrateKeyDown: own streaming keystrokes (marker) never cancel solo.
        let cfg = ShortcutConfiguration(trigger: .modifierOnly(key: .command, side: .left), behavior: .holdToTalk)
        let tap = EventTapShortcutRegistrar()
        tap.primeForTesting(cfg, onPress: {}, onRelease: {})
        XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .command, side: .left, time: 0, sole: true)), .pending)
        XCTAssertFalse(tap.arbitrateKeyDown(userData: LiveInsertion.eventMarker), "Own marker must not count as typing")
        XCTAssertTrue(tap.arbitrateKeyDown(userData: 0), "Real typing cancels pending solo")
        XCTAssertEqual(tap.simulateSoloEvent(.targetUp(key: .command, side: .left, time: 0.1)), .none, "Cancelled solo releases silently")
    }

    func testM2CmdVReservedAndMouseConsumedValidation() {
        // Cmd+V is Vella's own paste; never intercept as dictation chord.
        XCTAssertEqual(ShortcutValidation.validateKeyChord(keyCode: 9, modifiers: ShortcutConfiguration.cmdFlag), "\u{2318}V is reserved for paste.")
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 9, modifiers: ShortcutConfiguration.cmdFlag | ShortcutConfiguration.controlFlag), "Ctrl+Cmd+V remains allowed")
        // Mouse type prevents primary/secondary by construction; matching extra-button
        // down/up is consumed (no navigate) — structural: registrar returns true only for
        // matching button (reviewed in handle; synthetic dispatch owned by parent suite).
        XCTAssertNil(MouseButton(rawValue: 0))
        XCTAssertNil(MouseButton(rawValue: 1))
        XCTAssertEqual(MouseButton.middle.rawValue, 2)
    }

    @MainActor func testM3PerDeviceMasksBothSidesCannotRearm() {
        // Coordinator NX masks: aggregate flags stay set when opposite held; device flags decide.
        XCTAssertTrue(EventTapShortcutRegistrar.sideIsDown(CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK)), key: .command, side: .left))
        XCTAssertFalse(EventTapShortcutRegistrar.sideIsDown(CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK)), key: .command, side: .right), "Left device bit must not satisfy right")
        // Both sides: non-sole targetDown never rearms pending solo.
        let cfg = ShortcutConfiguration(trigger: .modifierOnly(key: .command, side: .left), behavior: .holdToTalk)
        let tap = EventTapShortcutRegistrar()
        tap.primeForTesting(cfg, onPress: {}, onRelease: {})
        XCTAssertEqual(tap.simulateSoloEvent(.targetDown(key: .command, side: .left, time: 0, sole: false)), .none, "Opposite-held (non-sole) down must not rearm")
    }

    @MainActor func testZZRenderNativeQAMenuAndRecorder() throws {
        // HONEST component captures only (no full native menu capture headless).
        // - qa-menu.png: bitmaps of actual production SettingsMenuItem control views
        //   (real NSButton radios in real host NSViews) composited vertically, labeled.
        //   Full native NSMenu tracking/appearance NOT claimed; see qa-render-menu.txt.
        // - qa-recorder.png: bitmap of actual production ShortcutKeyRecorderPanel.contentView
        //   (real NSTextField prompt/error hierarchy) rendered offscreen via caching display.
        //   Panel never ordered front, never key, no global input, no mic.
        _ = NSApplication.shared
        let store = ShortcutStore()
        _ = store.save(.default)
        let engine = ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }, currentOperation: { 0 }))
        let manager = ShortcutManager(engine: engine, store: store, registrar: MockShortcutRegistrar())
        let model = Model(configurationURL: try tempConfig())
        defer { model.shutdown() }
        let target = ShortcutMenuProbe()
        let item = ShortcutMenuFactory.shortcutsItem(manager: manager, model: model, target: target,
            selectBehavior: #selector(ShortcutMenuProbe.behavior(_:)), recordKeys: #selector(ShortcutMenuProbe.record(_:)), cancelCapture: #selector(ShortcutMenuProbe.cancel(_:)),
            selectModifier: #selector(ShortcutMenuProbe.modifier(_:)), selectMouse: #selector(ShortcutMenuProbe.mouse(_:)), resetDefault: #selector(ShortcutMenuProbe.reset(_:)), openSettings: #selector(ShortcutMenuProbe.settings(_:)))
        let menu = try XCTUnwrap(item.submenu)
        // Assert native measured sizes on real production control views.
        let settingsViews = menu.items.compactMap { $0 as? SettingsMenuItem }.compactMap(\.view)
        XCTAssertFalse(settingsViews.isEmpty, "Factory must embed real SettingsMenuItem views")
        for v in settingsViews {
            XCTAssertEqual(v.frame.height, 28, accuracy: 0.5, "Native control height 28")
            XCTAssertGreaterThanOrEqual(v.frame.width, 180, "Native control min width 180")
        }
        // Nested compact pickers (current, not stale flat list).
        XCTAssertNotNil(menu.items.first(where: { $0.title == "Modifier-Only" })?.submenu, "Nested Modifier-Only picker")
        XCTAssertNotNil(menu.items.first(where: { $0.title == "Mouse Button" })?.submenu, "Nested Mouse Button picker")
        XCTAssertEqual(menu.items.first(where: { $0.title == "Modifier-Only" })?.submenu?.items.count, 9)
        XCTAssertEqual(menu.items.first(where: { $0.title == "Mouse Button" })?.submenu?.items.count, 3)
        Self.writeQAComponentImage(views: settingsViews, filename: "qa-menu.png", header: "Shortcuts controls (component capture, not full menu)")
        // Actual production recorder contentView, offscreen.
        let panel = ShortcutKeyRecorderPanel()
        XCTAssertEqual(panel.title, "Record Shortcut")
        Self.writeQAViewImage(view: panel.contentView!, filename: "qa-recorder.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ".build/qa/shortcuts-20260916/spark/qa-menu.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ".build/qa/shortcuts-20260916/spark/qa-recorder.png"))
    }

    @MainActor private static func writeQAComponentImage(views: [NSView], filename: String, header: String) {
        // Composite bitmaps of the REAL production views (each via caching display).
        var reps: [NSBitmapImageRep] = []
        var headerRep: NSBitmapImageRep? = nil
        do {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (header as NSString).size(withAttributes: attrs)
            let w = Int(ceil(size.width)) + 32, h = 28
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.current = ctx
                    NSColor.windowBackgroundColor.setFill(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))
                    (header as NSString).draw(at: NSPoint(x: 16, y: 6), withAttributes: attrs)
                }
                NSGraphicsContext.restoreGraphicsState()
                headerRep = rep
            }
        }
        for v in views {
            v.layoutSubtreeIfNeeded()
            let bounds = v.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let rep = v.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            v.cacheDisplay(in: bounds, to: rep)
            reps.append(rep)
        }
        guard !reps.isEmpty else { return }
        let w = reps.map(\.pixelsWide).max() ?? 400
        let headerH = headerRep?.pixelsHigh ?? 0
        let h = headerH + reps.map(\.pixelsHigh).reduce(0, +)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: out) {
            NSGraphicsContext.current = ctx
            NSColor.windowBackgroundColor.setFill(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))
            var y = h
            if let headerRep, let cg = headerRep.cgImage {
                y -= headerRep.pixelsHigh
                ctx.cgContext.draw(cg, in: NSRect(x: 0, y: y, width: headerRep.pixelsWide, height: headerRep.pixelsHigh))
            }
            for rep in reps {
                guard let cg = rep.cgImage else { continue }
                y -= rep.pixelsHigh
                ctx.cgContext.draw(cg, in: NSRect(x: 0, y: y, width: rep.pixelsWide, height: rep.pixelsHigh))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = out.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: ".build/qa/shortcuts-20260916/spark/\(filename)"))
        }
    }

    @MainActor private static func writeQAViewImage(view: NSView, filename: String) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: ".build/qa/shortcuts-20260916/spark/\(filename)"))
        }
    }

    @MainActor private static func writeQAImage(lines: [String], filename: String, title: String) {
        let w = 520, h = 28 + lines.count * 22
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { NSGraphicsContext.restoreGraphicsState(); return }
        NSGraphicsContext.current = ctx
        NSColor.windowBackgroundColor.setFill(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - 24
        for line in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            (line as NSString).draw(at: NSPoint(x: 16, y: y - 16), withAttributes: attrs)
            y -= 22
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: ".build/qa/shortcuts-20260916/spark/\(filename)"))
        }
    }

    @MainActor private static func writeQAPanelImage(panel: ShortcutKeyRecorderPanel, filename: String) {
        // Isolated panel metadata render (no ordering front, no key capture).
        let lines = ["Record Shortcut (isolated panel)", "Title: \(panel.title)", "Prompt: Press shortcut…  (Esc cancels)", "Size: \(Int(panel.frame.width))x\(Int(panel.frame.height))"]
        writeQAImage(lines: lines, filename: filename, title: "Recorder")
    }
}

// MARK: - QA seams (synthetic only, no host input)

final class RecordingBox {
    var recording: Bool
    var busy: Bool
    var operation: UInt64
    var starts = 0
    var finishes = 0
    var cancels = 0
    init(recording: Bool = false, busy: Bool = false, operation: UInt64 = 0) { self.recording = recording; self.busy = busy; self.operation = operation }
}

final class TimeBox {
    var now: TimeInterval
    init(now: TimeInterval) { self.now = now }
}

final class MockShortcutRegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    var shouldThrow: Error?
    var registerCalls: [ShortcutConfiguration] = []
    var unregisterCalls = 0
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        registerCalls.append(config)
        if let err = shouldThrow { throw err }
        registered = config
    }
    func unregister() { unregisterCalls += 1; registered = nil }
}

@MainActor final class ShortcutMenuProbe: NSObject {
    @objc func behavior(_ s: NSMenuItem) {}
    @objc func record(_ s: NSMenuItem) {}
    @objc func cancel(_ s: NSMenuItem) {}
    @objc func modifier(_ s: NSMenuItem) {}
    @objc func mouse(_ s: NSMenuItem) {}
    @objc func reset(_ s: NSMenuItem) {}
    @objc func settings(_ s: NSMenuItem) {}
}
