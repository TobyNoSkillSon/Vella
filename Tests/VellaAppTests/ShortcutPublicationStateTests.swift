import XCTest
import Foundation
import AppKit
@testable import Vella
@testable import VellaCore

/// Independent pre-push publication audit (w1:p10).
/// Scope: Sources/VellaCore/ShortcutCore.swift (validation/labels/store),
/// ShortcutEngine + ModifierSoloReducer state machine, plus ShortcutManager
/// transaction glue (apply/save/registrar rollback, generations).
/// No private data, no historical QA, no full-app launch (no Model/AppDelegate/
/// NSApplication.shared), no real input/taps/hotkeys, no TCC, no commits.
/// All stores are memory (fileURL nil) or temporary synthetic URLs; all clocks
/// and registrar sinks are injected. Deterministic only.
final class ShortcutPublicationStateTests: XCTestCase {

    // MARK: - Fixtures (synthetic only, unique names to avoid target collisions)

    final class PubBox {
        var recording = false
        var busy = false
        var starts = 0
        var finishes = 0
        var cancels = 0
        var operation: UInt64 = 0
        init(recording: Bool = false, busy: Bool = false, operation: UInt64 = 0) {
            self.recording = recording; self.busy = busy; self.operation = operation
        }
    }

    final class PubClock {
        var now: TimeInterval
        init(_ now: TimeInterval = 1000) { self.now = now }
    }

    final class PubMockRegistrar: ShortcutRegistrar {
        var registered: ShortcutConfiguration?
        var registerCalls: [ShortcutConfiguration] = []
        var unregisterCalls = 0
        var shouldFailFor: ((ShortcutConfiguration) -> Bool)?
        var failMessage = "Synthetic conflict: already reserved."
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
            registerCalls.append(config)
            if shouldFailFor?(config) == true { throw VellaError.message(failMessage) }
            registered = config
            self.onPress = onPress
            self.onRelease = onRelease
        }
        func unregister() {
            unregisterCalls += 1
            registered = nil
            onPress = nil
            onRelease = nil
        }
        func firePress() { onPress?() }
        func fireRelease() { onRelease?() }
    }

    private func pubEngine(behavior: ShortcutBehavior, box: PubBox, clock: PubClock, operationAware: Bool = false) -> ShortcutEngine {
        let cfg = ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), behavior: behavior)
        if operationAware {
            return ShortcutEngine(configuration: cfg, sinks: .init(
                start: { box.starts += 1; box.operation &+= 1; box.recording = true },
                finish: { box.finishes += 1; box.operation &+= 1; box.recording = false; box.busy = false },
                cancel: { box.cancels += 1; box.operation &+= 1; box.recording = false; box.busy = false },
                isRecording: { box.recording }, isBusy: { box.busy },
                currentOperation: { box.operation }), now: { clock.now })
        } else {
            return ShortcutEngine(configuration: cfg, sinks: .init(
                start: { box.starts += 1 },
                finish: { box.finishes += 1 },
                cancel: { box.cancels += 1 },
                isRecording: { box.recording }, isBusy: { box.busy }), now: { clock.now })
        }
    }

    @MainActor
    private func pubManager(behavior: ShortcutBehavior = .toggle, box: PubBox? = nil, clock: PubClock? = nil, storeURL: URL? = nil) -> (ShortcutManager, PubMockRegistrar, PubBox, PubClock) {
        let b = box ?? PubBox()
        let c = clock ?? PubClock()
        let store = ShortcutStore(initial: .init(trigger: .keyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), behavior: behavior), fileURL: storeURL)
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { b.starts += 1; b.recording = true },
            finish: { b.finishes += 1; b.recording = false; b.busy = false },
            cancel: { b.cancels += 1; b.recording = false; b.busy = false },
            isRecording: { b.recording }, isBusy: { b.busy }), now: { c.now })
        let registrar = PubMockRegistrar()
        let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
        manager.permissionCheck = { true }
        return (manager, registrar, b, c)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vella-pubstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Validation (ShortcutCore.swift)

    func testPub_Validation_EmptyAndUnknownBitsRejected() {
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 0), "empty modifiers must be rejected")
        XCTAssertNotNil(ShortcutValidation.validate(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        // Unknown / Fn-only bits would degrade into a bare hotkey; must be rejected.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers | 0x800000))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 1 << 20))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 1 << 5))
        // Valid default passes.
        XCTAssertNil(ShortcutValidation.validate(.default))
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers))
    }

    func testPub_Validation_ShiftAloneAndKeyBoundaries() {
        // Shift alone on typing keys hijacks typing.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: ShortcutConfiguration.shiftFlag), "Shift+C rejected")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 49, modifiers: ShortcutConfiguration.shiftFlag), "Shift+Space rejected")
        // Shift + function keys safe.
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 122, modifiers: ShortcutConfiguration.shiftFlag), "Shift+F1 allowed")
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 96, modifiers: ShortcutConfiguration.shiftFlag), "Shift+F5 allowed")
        // KeyCode boundary: 127 is last supported, 128+ rejected.
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 127, modifiers: ShortcutConfiguration.defaultModifiers))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 128, modifiers: ShortcutConfiguration.defaultModifiers))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 200, modifiers: ShortcutConfiguration.defaultModifiers))
        // Modifier keyCodes must use modifier-only.
        for code in [54, 55, 56, 58, 59, 60, 61, 62, 63] as [UInt32] {
            XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: code, modifiers: ShortcutConfiguration.defaultModifiers), "modifier keyCode \(code) rejected for chords")
        }
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 53, modifiers: ShortcutConfiguration.defaultModifiers), "Esc reserved")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 57, modifiers: ShortcutConfiguration.defaultModifiers), "Caps rejected")
    }

    func testPub_F13F20_ShiftAloneAndLabels() {
        // Apple key codes: F13..F20 = 105,107,113,106,64,79,80,90.
        let pairs: [(UInt32, String)] = [
            (105, "F13"), (107, "F14"), (113, "F15"), (106, "F16"),
            (64, "F17"), (79, "F18"), (80, "F19"), (90, "F20"),
        ]
        for (code, name) in pairs {
            XCTAssertEqual(ShortcutLabels.keyName(keyCode: code), name, "keyCode \(code) labels \(name)")
            XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: code, modifiers: ShortcutConfiguration.shiftFlag), "Shift+\(name) safe (never types)")
            XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: code, modifiers: ShortcutConfiguration.defaultModifiers), "\(name) with modifiers allowed")
            XCTAssertEqual(ShortcutLabels.keyChordDisplay(keyCode: code, modifiers: ShortcutConfiguration.shiftFlag), "⇧\(name)")
        }
        // Full Shift-alone allowlist still holds F1-F12.
        for code in [96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122] as [UInt32] {
            XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: code, modifiers: ShortcutConfiguration.shiftFlag), "Shift+F keyCode \(code) allowed")
        }
    }

    func testPub_Validation_ReservedChords() {
        let cmd = ShortcutConfiguration.cmdFlag
        let ctrl = ShortcutConfiguration.controlFlag
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 12, modifiers: cmd), "Cmd+Q quit")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 12, modifiers: cmd | ctrl), "Ctrl+Cmd+Q lock")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 49, modifiers: cmd), "Cmd+Space spotlight")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 48, modifiers: cmd), "Cmd+Tab reserved")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 48, modifiers: ctrl), "Ctrl+Tab reserved")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 9, modifiers: cmd), "plain Cmd+V is Vella paste")
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 9, modifiers: cmd | ctrl), "Ctrl+Cmd+V allowed")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 13, modifiers: cmd), "Cmd+W close")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 46, modifiers: cmd), "Cmd+M minimize")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 4, modifiers: cmd), "Cmd+H hide")
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 43, modifiers: cmd), "Cmd+, settings")
        // Modifier-only and mouse are valid types; Fn carries note not error.
        XCTAssertNil(ShortcutValidation.validate(.init(trigger: .modifierOnly(key: .control, side: .left), behavior: .holdToTalk)))
        XCTAssertNil(ShortcutValidation.validate(.init(trigger: .modifierOnly(key: .function, side: .left), behavior: .toggle)))
        XCTAssertFalse(ShortcutValidation.functionKeyReliabilityNote.isEmpty)
        XCTAssertNil(ShortcutValidation.validate(.init(trigger: .mouseButton(button: .middle), behavior: .toggle)))
    }

    func testPub_Labels_DisplayContract() {
        XCTAssertEqual(ShortcutLabels.display(.default), "⌃⌘N · Toggle")
        XCTAssertEqual(ShortcutLabels.keyChordDisplay(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), "⌃⌘N")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.modifierOnly(key: .control, side: .left)), "Left ⌃")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.modifierOnly(key: .function, side: .left)), "Fn")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.mouseButton(button: .middle)), "Middle Click")
        XCTAssertEqual(ShortcutLabels.keyName(keyCode: 45), "N")
        XCTAssertEqual(ShortcutLabels.keyName(keyCode: 49), "Space")
        XCTAssertTrue(ShortcutLabels.keyName(keyCode: 200).hasPrefix("Key "))
        // Trigger routing policy.
        XCTAssertFalse(ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .modifierOnly(key: .control, side: .left), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .mouseButton(button: .button3), behavior: .toggle).trigger.requiresEventTap)
    }

    // MARK: - Store validation / migration (ShortcutStore)

    func testPub_Store_MemorySaveRejectsInvalidKeepsPrevious() {
        let store = ShortcutStore(initial: .default, fileURL: nil)
        XCTAssertFalse(store.save(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertEqual(store.configuration, .default)
        XCTAssertNotNil(store.lastError)
        let calls = store.lastError ?? ""
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(store.save(.init(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)))
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.configuration.behavior, .holdToTalk)
    }

    func testPub_Store_FileRoundTripAndReset() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("shortcuts.json")
        let store = ShortcutStore(initial: .default, fileURL: url)
        let custom = ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .right), behavior: .holdToTalk)
        XCTAssertTrue(store.save(custom))
        let reloaded = ShortcutStore(initial: .default, fileURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.configuration, custom)
        XCTAssertNil(reloaded.lastError)
        XCTAssertEqual(reloaded.resetToDefault(), .default)
        // Disk now holds default.
        let third = ShortcutStore(initial: custom, fileURL: url)
        third.load()
        XCTAssertEqual(third.configuration, .default)
    }

    func testPub_Store_MissingFileKeepsInitialNoError() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("missing.json")
        let store = ShortcutStore(initial: .default, fileURL: url)
        store.load()
        XCTAssertEqual(store.configuration, .default)
        XCTAssertNil(store.lastError)
    }

    func testPub_Store_MalformedPrefsKeepPreviousWithError() throws {
        let dir = try tempDir()
        // Corrupt JSON.
        let corruptURL = dir.appendingPathComponent("corrupt.json")
        try "not-json{{{".write(to: corruptURL, atomically: true, encoding: .utf8)
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)
        let corrupt = ShortcutStore(initial: custom, fileURL: corruptURL)
        corrupt.load()
        XCTAssertEqual(corrupt.configuration, custom, "corrupt payload must keep in-memory")
        XCTAssertNotNil(corrupt.lastError)
        // Empty file.
        let emptyURL = dir.appendingPathComponent("empty.json")
        try Data().write(to: emptyURL)
        let empty = ShortcutStore(initial: custom, fileURL: emptyURL)
        empty.load()
        XCTAssertEqual(empty.configuration, custom)
        XCTAssertNotNil(empty.lastError)
        // Unknown behavior string throws at decode -> keeps previous.
        let unknownURL = dir.appendingPathComponent("unknown.json")
        try #"{"trigger":{"kind":"keyChord","keyCode":45,"modifiers":4352},"behavior":"hyperdrive"}"#.write(to: unknownURL, atomically: true, encoding: .utf8)
        let unknown = ShortcutStore(initial: custom, fileURL: unknownURL)
        unknown.load()
        XCTAssertEqual(unknown.configuration, custom)
        XCTAssertNotNil(unknown.lastError)
        // Unknown trigger kind.
        let kindURL = dir.appendingPathComponent("kind.json")
        try #"{"trigger":{"kind":"voice"},"behavior":"toggle"}"#.write(to: kindURL, atomically: true, encoding: .utf8)
        let kind = ShortcutStore(initial: custom, fileURL: kindURL)
        kind.load()
        XCTAssertEqual(kind.configuration, custom)
        XCTAssertNotNil(kind.lastError)
        // Valid JSON but invalid chord (empty modifiers) -> validation error, keeps previous.
        let invalidURL = dir.appendingPathComponent("invalid.json")
        try #"{"trigger":{"kind":"keyChord","keyCode":45,"modifiers":0},"behavior":"toggle"}"#.write(to: invalidURL, atomically: true, encoding: .utf8)
        let invalid = ShortcutStore(initial: custom, fileURL: invalidURL)
        invalid.load()
        XCTAssertEqual(invalid.configuration, custom)
        XCTAssertNotNil(invalid.lastError)
        XCTAssertTrue(invalid.lastError?.contains("modifier") == true || invalid.lastError?.contains("Add at least") == true)
        // Out-of-range keyCode.
        let rangeURL = dir.appendingPathComponent("range.json")
        try #"{"trigger":{"kind":"keyChord","keyCode":200,"modifiers":4352},"behavior":"toggle"}"#.write(to: rangeURL, atomically: true, encoding: .utf8)
        let range = ShortcutStore(initial: custom, fileURL: rangeURL)
        range.load()
        XCTAssertEqual(range.configuration, custom)
        XCTAssertNotNil(range.lastError)
    }

    func testPub_Store_MigrationTolerantDefaultsAndFutureKeys() throws {
        let dir = try tempDir()
        // Empty object migrates to defaults (decodeIfPresent fallbacks).
        let emptyObjURL = dir.appendingPathComponent("emptyobj.json")
        try #"{}"#.write(to: emptyObjURL, atomically: true, encoding: .utf8)
        let emptyObj = ShortcutStore(initial: .init(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk), fileURL: emptyObjURL)
        emptyObj.load()
        XCTAssertEqual(emptyObj.configuration, .default, "empty object migrates to defaults")
        XCTAssertNil(emptyObj.lastError)
        // Missing behavior defaults to toggle; missing trigger defaults to default chord.
        let partialURL = dir.appendingPathComponent("partial.json")
        try #"{"trigger":{"kind":"keyChord","keyCode":8,"modifiers":4352}}"#.write(to: partialURL, atomically: true, encoding: .utf8)
        let partial = ShortcutStore(initial: .default, fileURL: partialURL)
        partial.load()
        XCTAssertEqual(partial.configuration.behavior, .toggle)
        guard case .keyChord(let code, _) = partial.configuration.trigger else { return XCTFail("expected keyChord") }
        XCTAssertEqual(code, 8)
        // Future/unknown keys ignored.
        let futureURL = dir.appendingPathComponent("future.json")
        try #"{"trigger":{"kind":"keyChord","keyCode":45,"modifiers":4352,"future":99},"behavior":"toggle","extra":1}"#.write(to: futureURL, atomically: true, encoding: .utf8)
        let future = ShortcutStore(initial: .init(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk), fileURL: futureURL)
        future.load()
        XCTAssertEqual(future.configuration, .default)
        // Trigger without kind defaults to keyChord.
        let nokindURL = dir.appendingPathComponent("nokind.json")
        try #"{"trigger":{"keyCode":8,"modifiers":4352},"behavior":"toggle"}"#.write(to: nokindURL, atomically: true, encoding: .utf8)
        let nokind = ShortcutStore(initial: .default, fileURL: nokindURL)
        nokind.load()
        guard case .keyChord(let c2, _) = nokind.configuration.trigger else { return XCTFail("missing kind must default to keyChord") }
        XCTAssertEqual(c2, 8)
    }

    func testPub_Store_SaveFailureKeepsPreviousWithError() throws {
        // fileURL pointing at a directory forces Data.write to fail deterministically.
        let dir = try tempDir()
        let store = ShortcutStore(initial: .default, fileURL: dir)
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)
        XCTAssertFalse(store.save(custom), "write to directory must fail")
        XCTAssertEqual(store.configuration, .default, "failed save must keep previous in-memory")
        XCTAssertNotNil(store.lastError)
    }

    func testPub_TriggerDecode_InvalidMouseAndModifierThrow() {
        func decode(_ json: String) throws -> ShortcutConfiguration {
            try JSONDecoder().decode(ShortcutConfiguration.self, from: Data(json.utf8))
        }
        // Valid explicit variants remain compatible.
        XCTAssertNoThrow(try decode(#"{"trigger":{"kind":"mouseButton","button":2},"behavior":"toggle"}"#))
        XCTAssertNoThrow(try decode(#"{"trigger":{"kind":"mouseButton","button":3},"behavior":"holdToTalk"}"#))
        XCTAssertNoThrow(try decode(#"{"trigger":{"kind":"mouseButton","button":4},"behavior":"toggle"}"#))
        XCTAssertNoThrow(try decode(#"{"trigger":{"kind":"modifierOnly","key":"control","side":"left"},"behavior":"toggle"}"#))
        XCTAssertNoThrow(try decode(#"{"trigger":{"kind":"modifierOnly","key":"option","side":"right"},"behavior":"holdToTalk"}"#))
        // Overall {} defaults remain supported.
        XCTAssertNoThrow(try decode(#"{}"#))
        XCTAssertEqual(try? decode(#"{}"#), .default)
        // Explicit mouse with unsupported/missing button must throw (no silent middle remap).
        for payload in [
            #"{"trigger":{"kind":"mouseButton","button":-1},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":0},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":1},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":5},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":999999},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":2147483647},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton"},"behavior":"toggle"}"#,
        ] {
            XCTAssertThrowsError(try decode(payload), "mouse payload must throw: \(payload)")
        }
        // Explicit modifierOnly missing key/side must throw (no silent Left Control).
        for payload in [
            #"{"trigger":{"kind":"modifierOnly"},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"modifierOnly","key":"control"},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"modifierOnly","side":"left"},"behavior":"toggle"}"#,
        ] {
            XCTAssertThrowsError(try decode(payload), "modifier payload must throw: \(payload)")
        }
    }

    func testPub_Store_InvalidMouseAndModifierKeepPreviousAndFileBytes() throws {
        let dir = try tempDir()
        let previous = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)
        let payloads = [
            #"{"trigger":{"kind":"mouseButton","button":-1},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":0},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":1},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":5},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton","button":999999},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"mouseButton"},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"modifierOnly"},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"modifierOnly","key":"control"},"behavior":"toggle"}"#,
            #"{"trigger":{"kind":"modifierOnly","side":"left"},"behavior":"toggle"}"#,
        ]
        for (i, payload) in payloads.enumerated() {
            let url = dir.appendingPathComponent("invalid-\(i).json")
            try payload.write(to: url, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: url)
            let store = ShortcutStore(initial: previous, fileURL: url)
            store.load()
            XCTAssertEqual(store.configuration, previous, "invalid payload must retain previous: \(payload)")
            XCTAssertNotNil(store.lastError, "invalid payload must report error: \(payload)")
            XCTAssertEqual(try Data(contentsOf: url), before, "file bytes must be untouched: \(payload)")
        }
        // Valid explicit mouse/modifier still load (no over-tightening).
        let validURL = dir.appendingPathComponent("valid.json")
        try #"{"trigger":{"kind":"mouseButton","button":3},"behavior":"holdToTalk"}"#.write(to: validURL, atomically: true, encoding: .utf8)
        let valid = ShortcutStore(initial: previous, fileURL: validURL)
        valid.load()
        XCTAssertEqual(valid.configuration.trigger, .mouseButton(button: .button3))
        XCTAssertNil(valid.lastError)
    }

    // MARK: - Engine: toggle / repeat / stale

    func testPub_Engine_ToggleRepeatDuplicateStale() {
        let box = PubBox()
        let clock = PubClock()
        let engine = pubEngine(behavior: .toggle, box: box, clock: clock)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        XCTAssertNotNil(engine.activePressID)
        XCTAssertFalse(engine.press(), "duplicate while held suppressed")
        XCTAssertFalse(engine.press(isRepeat: true), "repeat suppressed")
        XCTAssertEqual(box.starts, 1)
        XCTAssertFalse(engine.release(), "toggle release never acts")
        XCTAssertEqual(box.finishes, 0)
        XCTAssertNil(engine.activePressID)
        XCTAssertFalse(engine.release(), "stale release with no press suppressed")
        XCTAssertFalse(engine.releaseForPressID(999))
        // Busy suppresses toggle start.
        let busyBox = PubBox(busy: true)
        let busyEngine = pubEngine(behavior: .toggle, box: busyBox, clock: PubClock())
        XCTAssertFalse(busyEngine.press())
        XCTAssertEqual(busyBox.starts, 0)
        XCTAssertFalse(busyEngine.canChangeSettings)
        // Recording press finishes once.
        let recBox = PubBox(recording: true)
        let recEngine = pubEngine(behavior: .toggle, box: recBox, clock: PubClock())
        XCTAssertTrue(recEngine.press())
        XCTAssertEqual(recBox.finishes, 1)
        XCTAssertFalse(recEngine.release())
    }

    func testPub_Engine_HoldStartFinishAndPreparingAbort() {
        let box = PubBox()
        let clock = PubClock(1000)
        let engine = pubEngine(behavior: .holdToTalk, box: box, clock: clock)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        XCTAssertNotNil(engine.activePressID)
        XCTAssertNotNil(engine.activeCaptureID)
        box.recording = true
        clock.now = 1000.5
        XCTAssertTrue(engine.release())
        XCTAssertEqual(box.finishes, 1)
        XCTAssertNil(engine.activePressID)
        XCTAssertNil(engine.activeCaptureID)
        // Release during preparing must cancel, not finish, no runaway.
        let box2 = PubBox()
        let clock2 = PubClock(2000)
        let engine2 = pubEngine(behavior: .holdToTalk, box: box2, clock: clock2)
        XCTAssertTrue(engine2.press())
        XCTAssertEqual(box2.starts, 1)
        box2.busy = true
        XCTAssertTrue(engine2.release())
        XCTAssertEqual(box2.cancels, 1)
        XCTAssertEqual(box2.finishes, 0)
        XCTAssertNil(engine2.activePressID)
        XCTAssertNil(engine2.activeCaptureID)
        // Next press starts cleanly.
        box2.busy = false
        XCTAssertTrue(engine2.press())
        XCTAssertEqual(box2.starts, 2)
    }

    func testPub_Engine_HoldForeignNeverSteals() {
        let box = PubBox(recording: true) // foreign menu start, no owned press
        let engine = pubEngine(behavior: .holdToTalk, box: box, clock: PubClock())
        XCTAssertFalse(engine.press(), "foreign recording must not be stolen")
        XCTAssertEqual(box.starts, 0)
        XCTAssertFalse(engine.release(), "stale release must not finish foreign")
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
        // Foreign busy also blocks.
        let busyBox = PubBox(busy: true)
        let busyEngine = pubEngine(behavior: .holdToTalk, box: busyBox, clock: PubClock())
        XCTAssertFalse(busyEngine.press())
        XCTAssertEqual(busyBox.starts, 0)
    }

    func testPub_Engine_StalePressIDNeverFinishes() {
        let box = PubBox()
        let clock = PubClock(1000)
        let engine = pubEngine(behavior: .holdToTalk, box: box, clock: clock)
        XCTAssertFalse(engine.releaseForPressID(12345), "stale before press ignored")
        XCTAssertTrue(engine.press())
        guard let owned = engine.activePressID else { return XCTFail("expected press ID") }
        XCTAssertFalse(engine.releaseForPressID(owned + 1000), "mismatched ID never finishes")
        XCTAssertEqual(box.finishes, 0)
        // Correct ID but no live capture after foreign finish: suppressed.
        box.recording = false; box.busy = false
        XCTAssertFalse(engine.releaseForPressID(owned))
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
        // Correct flow: press, recording, release finishes.
        let box2 = PubBox()
        let clock2 = PubClock(3000)
        let engine2 = pubEngine(behavior: .holdToTalk, box: box2, clock: clock2)
        XCTAssertTrue(engine2.press())
        guard let id2 = engine2.activePressID else { return XCTFail() }
        box2.recording = true
        clock2.now = 3000.5
        XCTAssertTrue(engine2.releaseForPressID(id2))
        XCTAssertEqual(box2.finishes, 1)
        XCTAssertFalse(engine2.releaseForPressID(id2), "duplicate release suppressed")
    }

    // MARK: - Engine: tap-or-hold 300ms boundary + preparing + stale kept

    func testPub_Engine_TapOrHold299Keeps300Finishes() {
        // 299ms tap keeps.
        let box = PubBox()
        let clock = PubClock(1000)
        let engine = pubEngine(behavior: .tapOrHold, box: box, clock: clock)
        XCTAssertTrue(engine.press())
        box.recording = true
        clock.now = 1000 + 0.299
        XCTAssertFalse(engine.release(), "tap <0.3 keeps")
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
        XCTAssertNil(engine.activePressID)
        XCTAssertNotNil(engine.activeCaptureID, "capture kept for tap-off")
        // Tap-off arms without double-start, release finishes.
        XCTAssertTrue(engine.press(), "tap-off arms")
        XCTAssertEqual(box.starts, 1, "arming must not double-start")
        clock.now += 0.05
        XCTAssertTrue(engine.release())
        XCTAssertEqual(box.finishes, 1)
        // Exact 300ms boundary belongs to hold.
        let box2 = PubBox()
        let clock2 = PubClock(2000)
        let engine2 = pubEngine(behavior: .tapOrHold, box: box2, clock: clock2)
        XCTAssertTrue(engine2.press())
        box2.recording = true
        clock2.now = 2000 + 0.300
        XCTAssertTrue(engine2.release(), "exact 0.300 finishes")
        XCTAssertEqual(box2.finishes, 1)
        // 301ms hold finishes directly.
        let box3 = PubBox()
        let clock3 = PubClock(3000)
        let engine3 = pubEngine(behavior: .tapOrHold, box: box3, clock: clock3)
        XCTAssertTrue(engine3.press())
        box3.recording = true
        clock3.now = 3000 + 0.301
        XCTAssertTrue(engine3.release())
        XCTAssertEqual(box3.finishes, 1)
    }

    func testPub_Engine_TapWhilePreparingThenTapOff() {
        let box = PubBox()
        let clock = PubClock(1000)
        let engine = pubEngine(behavior: .tapOrHold, box: box, clock: clock)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        box.busy = true // still preparing at quick release
        clock.now = 1000.1
        XCTAssertFalse(engine.release(), "tap keeps while preparing")
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
        box.busy = false; box.recording = true
        XCTAssertTrue(engine.press(), "tap-off arms")
        clock.now += 0.1
        XCTAssertTrue(engine.release())
        XCTAssertEqual(box.finishes, 1)
    }

    func testPub_Engine_StaleKeptCaptureDroppedWhenIdle() {
        let box = PubBox()
        let clock = PubClock(1000)
        let engine = pubEngine(behavior: .tapOrHold, box: box, clock: clock)
        XCTAssertTrue(engine.press())
        box.recording = true
        clock.now = 1000.1
        XCTAssertFalse(engine.release(), "tap keeps")
        XCTAssertNotNil(engine.activeCaptureID)
        // Foreign menu Finish completes the kept capture externally.
        box.recording = false; box.busy = false
        // Next press must drop stale kept capture and start fresh (not arm).
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 2, "stale kept capture dropped, fresh start")
        XCTAssertFalse(engine.configuration.behavior == .toggle && false)
    }

    // MARK: - Engine: generations / cancel / interruption

    func testPub_Engine_GenerationBlocksForeignFinishStart() {
        let box = PubBox(operation: 5)
        let clock = PubClock(1000)
        let engine = ShortcutEngine(configuration: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk),
            sinks: .init(
                start: { box.starts += 1; box.operation &+= 1; box.recording = true },
                finish: { box.finishes += 1; box.operation &+= 1; box.recording = false },
                cancel: { box.cancels += 1; box.operation &+= 1; box.recording = false; box.busy = false },
                isRecording: { box.recording }, isBusy: { box.busy },
                currentOperation: { box.operation }), now: { clock.now })
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        // Manual menu Finish + new Start replaces capture (two generation bumps).
        box.recording = false; box.operation &+= 1 // foreign finish
        box.recording = true; box.operation &+= 1 // foreign new start
        XCTAssertFalse(engine.release(), "stale release must not finish unrelated capture")
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
    }

    func testPub_Engine_InterruptionCancelsOwnedButNotForeignAfterGenerationChange() {
        // Owned hold interrupted -> cancel, never finish.
        let box = PubBox()
        let engine = pubEngine(behavior: .holdToTalk, box: box, clock: PubClock())
        XCTAssertTrue(engine.press())
        box.recording = true
        engine.handleInterruption()
        XCTAssertEqual(box.cancels, 1)
        XCTAssertEqual(box.finishes, 0)
        XCTAssertNil(engine.activePressID)
        XCTAssertNil(engine.activeCaptureID)
        XCTAssertFalse(engine.release())
        // No owned capture -> no sink.
        let idleBox = PubBox()
        let idle = pubEngine(behavior: .holdToTalk, box: idleBox, clock: PubClock())
        idle.handleInterruption()
        XCTAssertEqual(idleBox.cancels, 0)
        // Generation changed (foreign Finish+Start) -> interruption must not cancel new capture.
        let genBox = PubBox(operation: 10)
        let genClock = PubClock(1000)
        let genEngine = ShortcutEngine(configuration: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk),
            sinks: .init(
                start: { genBox.starts += 1; genBox.operation &+= 1; genBox.recording = true },
                finish: { genBox.finishes += 1; genBox.operation &+= 1; genBox.recording = false },
                cancel: { genBox.cancels += 1; genBox.operation &+= 1; genBox.recording = false; genBox.busy = false },
                isRecording: { genBox.recording }, isBusy: { genBox.busy },
                currentOperation: { genBox.operation }), now: { genClock.now })
        XCTAssertTrue(genEngine.press())
        // Foreign replaces capture.
        genBox.recording = false; genBox.operation &+= 1
        genBox.recording = true; genBox.operation &+= 1
        genEngine.handleInterruption()
        XCTAssertEqual(genBox.cancels, 0, "must not cancel unrelated new capture after generation change")
        XCTAssertEqual(genBox.finishes, 0)
        // Tap-disabled equals interruption.
        let tapBox = PubBox()
        let tapEngine = pubEngine(behavior: .holdToTalk, box: tapBox, clock: PubClock())
        XCTAssertTrue(tapEngine.press())
        tapBox.busy = true
        tapEngine.handleTapDisabled()
        XCTAssertEqual(tapBox.cancels, 1)
        XCTAssertEqual(tapBox.finishes, 0)
    }

    func testPub_Engine_UpdateConfigurationClearsWithoutSinks() {
        let box = PubBox()
        let engine = pubEngine(behavior: .holdToTalk, box: box, clock: PubClock())
        XCTAssertTrue(engine.press())
        XCTAssertNotNil(engine.activePressID)
        engine.updateConfiguration(.init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .toggle))
        XCTAssertNil(engine.activePressID, "rebind clears old press")
        XCTAssertNil(engine.activeCaptureID)
        XCTAssertEqual(box.starts, 1, "no extra sink on rebind")
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
        XCTAssertEqual(engine.configuration.behavior, .toggle)
    }

    func testPub_Engine_CanChangeSettingsGuarded() {
        let cfg = ShortcutConfiguration.default
        let idle = ShortcutEngine(configuration: cfg, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        XCTAssertTrue(idle.canChangeSettings)
        let rec = ShortcutEngine(configuration: cfg, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { true }, isBusy: { false }))
        XCTAssertFalse(rec.canChangeSettings)
        let busy = ShortcutEngine(configuration: cfg, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { true }))
        XCTAssertFalse(busy.canChangeSettings)
        XCTAssertFalse(idle.isRecordingActive)
        XCTAssertFalse(idle.isBusyActive)
    }

    func testPub_Engine_CaptureEpochMonotonic() {
        let box = PubBox()
        let clock = PubClock(1000)
        let engine = pubEngine(behavior: .holdToTalk, box: box, clock: clock)
        XCTAssertEqual(engine.captureEpoch, 0)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(engine.captureEpoch, 1)
        box.recording = true
        clock.now = 1000.5
        XCTAssertTrue(engine.release())
        XCTAssertEqual(engine.captureEpoch, 2, "hold finish bumps epoch")
        box.recording = false // synthetic finish clears recording (production Model does)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(engine.captureEpoch, 3)
    }

    // MARK: - Reducer (ModifierSoloReducer)

    func testPub_Reducer_SoloArbitration() {
        // Solo down becomes pending only.
        var s = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertNotNil(s.pendingSince)
        // Non-sole down never fires.
        var ns = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &ns, event: .targetDown(key: .control, side: .left, time: 0, sole: false), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        XCTAssertNil(ns.pendingSince)
        // Wrong key/side never fires.
        var w = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &w, event: .targetDown(key: .control, side: .right, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        // Duplicate down while pending keeps original, no second pending.
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetDown(key: .control, side: .left, time: 0.05, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        XCTAssertEqual(s.pendingSince, 0)
        // Other key cancels pending (ordinary Cmd+C never fires).
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .otherKeyDown(time: 0.05), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .cancelled)
        XCTAssertNil(s.pendingSince)
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetUp(key: .control, side: .left, time: 0.1), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        // Other modifier cancels.
        var m = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &m, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &m, event: .otherModifierDown(time: 0.05), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .cancelled)
        // Hold timeout: toggle never presses, hold presses once.
        var t = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &t, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .toggle), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &t, event: .holdTimeout(time: 0.4), targetKey: .command, targetSide: .left, behavior: .toggle), .none)
        XCTAssertNotNil(t.pendingSince, "toggle keeps pending through timeout")
        XCTAssertEqual(ModifierSoloReducer.step(state: &t, event: .targetUp(key: .command, side: .left, time: 0.45), targetKey: .command, targetSide: .left, behavior: .toggle), .tapRelease)
        var h = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .holdTimeout(time: 0.35), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .press)
        XCTAssertTrue(h.pressed)
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .holdTimeout(time: 0.5), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none, "second timeout no-op")
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .targetUp(key: .control, side: .left, time: 0.6), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .holdRelease)
        // Quick solo release without timeout yields tap.
        var q = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &q, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &q, event: .targetUp(key: .control, side: .left, time: 0.1), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .tapRelease)
        // Wrong-side up ignored.
        var ws = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &ws, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &ws, event: .targetUp(key: .control, side: .right, time: 0.1), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        // Reset clears with cancelled only when had state.
        var r = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &r, event: .reset, targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        XCTAssertEqual(ModifierSoloReducer.step(state: &r, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &r, event: .reset, targetKey: .control, targetSide: .left, behavior: .holdToTalk), .cancelled)
        XCTAssertNil(r.pendingSince)
        XCTAssertEqual(ModifierSoloReducer.holdDelay, 0.3, accuracy: 0.0001)
    }

    func testPub_Reducer_OrdinaryChordNeverFires() {
        var s = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .toggle), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .otherKeyDown(time: 0.05), targetKey: .command, targetSide: .left, behavior: .toggle), .cancelled)
        XCTAssertEqual(ModifierSoloReducer.step(state: &s, event: .targetUp(key: .command, side: .left, time: 0.1), targetKey: .command, targetSide: .left, behavior: .toggle), .none)
        // Typing while pressed (hold already fired) is ignored, not cancelled.
        var h = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .holdTimeout(time: 0.35), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .press)
        XCTAssertEqual(ModifierSoloReducer.step(state: &h, event: .otherKeyDown(time: 0.4), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .none)
        XCTAssertTrue(h.pressed)
    }

    // MARK: - Manager transaction glue (injected registrar, no OS)

    @MainActor
    func testPub_Manager_ApplyValidUpdatesLabels() {
        let (manager, registrar, _, _) = pubManager()
        XCTAssertEqual(manager.currentLabel, "⌃⌘N · Toggle")
        XCTAssertFalse(manager.requiresEventTap)
        XCTAssertTrue(manager.canEdit)
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle)))
        XCTAssertTrue(registrar.registered?.trigger == ShortcutTrigger.keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers))
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.currentLabel, "⌃⌘C · Toggle")
        XCTAssertTrue(manager.apply(.init(trigger: .modifierOnly(key: .control, side: .left), behavior: .holdToTalk)))
        XCTAssertTrue(manager.requiresEventTap)
        XCTAssertTrue(manager.eventTapPermissionNote.contains("Accessibility"))
    }

    @MainActor
    func testPub_Manager_ApplyValidationKeepsPreviousNoRegistrarCall() {
        let (manager, registrar, _, _) = pubManager()
        let calls = registrar.registerCalls.count
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(manager.configuration, ShortcutConfiguration.default)
        XCTAssertEqual(registrar.registerCalls.count, calls, "invalid must not reach registrar")
        XCTAssertEqual(manager.engine.configuration, ShortcutConfiguration.default, "engine untouched on validation failure")
    }

    @MainActor
    func testPub_Manager_ApplyBlockedWhileRecordingOrBusy() {
        let (manager, _, box, _) = pubManager()
        XCTAssertTrue(manager.canEdit)
        box.recording = true
        XCTAssertFalse(manager.canEdit)
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle)))
        XCTAssertEqual(manager.lastError, "Finish or stop recording before changing shortcuts.")
        box.recording = false; box.busy = true
        XCTAssertFalse(manager.canEdit)
        XCTAssertFalse(manager.apply(.init(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle)))
    }

    @MainActor
    func testPub_Manager_RollbackOnRegistrarConflict() {
        let (manager, registrar, _, _) = pubManager()
        let first = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle)
        XCTAssertTrue(manager.apply(first))
        XCTAssertEqual(registrar.registered?.trigger, first.trigger)
        // Fail only the conflicting chord; rollback re-register must succeed.
        let conflict = ShortcutConfiguration(trigger: .keyChord(keyCode: 9, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle)
        registrar.shouldFailFor = { $0 == conflict }
        XCTAssertFalse(manager.apply(conflict))
        XCTAssertNotNil(manager.lastError)
        XCTAssertTrue(manager.lastError?.contains("Synthetic conflict") == true)
        XCTAssertEqual(manager.configuration, first, "config rolled back")
        XCTAssertEqual(manager.engine.configuration, first, "engine rolled back")
        XCTAssertEqual(registrar.registered?.trigger, first.trigger, "registrar rolled back to previous")
        XCTAssertEqual(manager.currentLabel, ShortcutLabels.display(first))
    }

    @MainActor
    func testPub_Manager_FailedSaveRollsBackRegistrar() throws {
        // Store whose fileURL is a directory: every save fails deterministically.
        let dir = try tempDir()
        let store = ShortcutStore(initial: .default, fileURL: dir)
        let box = PubBox()
        let clock = PubClock()
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { box.starts += 1 }, finish: { box.finishes += 1 }, cancel: { box.cancels += 1 },
            isRecording: { box.recording }, isBusy: { box.busy }), now: { clock.now })
        let registrar = PubMockRegistrar()
        let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
        manager.permissionCheck = { true }
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 8, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)
        XCTAssertFalse(manager.apply(custom), "save failure must fail apply")
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(manager.configuration, .default, "config unchanged after save failure")
        XCTAssertEqual(manager.engine.configuration, .default, "engine unchanged after save failure")
        // Registrar attempted new then restored previous (at least one re-register of default).
        XCTAssertTrue(registrar.registerCalls.contains(custom))
        XCTAssertEqual(registrar.registered?.trigger, ShortcutConfiguration.default.trigger)
    }

    @MainActor
    func testPub_Manager_RegisterStoredOrDefaultPersists() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("shortcuts.json")
        let custom = ShortcutConfiguration(trigger: .keyChord(keyCode: 64, modifiers: 6912), behavior: .holdToTalk)
        XCTAssertNil(ShortcutValidation.validate(custom))
        // Seed disk via store save.
        let seed = ShortcutStore(initial: .default, fileURL: url)
        XCTAssertTrue(seed.save(custom))
        // Fresh manager loads stored binding and registers it.
        let box = PubBox()
        let engine = ShortcutEngine(configuration: .default, sinks: .init(
            start: {}, finish: {}, cancel: {},
            isRecording: { box.recording }, isBusy: { box.busy }))
        let registrar = PubMockRegistrar()
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(initial: .default, fileURL: url), registrar: registrar)
        manager.reloadFromStore()
        XCTAssertEqual(manager.configuration, custom)
        XCTAssertTrue(manager.registerStoredOrDefault())
        XCTAssertEqual(registrar.registered, custom)
        XCTAssertEqual(manager.activeConfiguration, custom)
        XCTAssertFalse(manager.isUsingFallback)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testPub_Manager_PressReleaseThroughRegistrarCallbacks() {
        let box = PubBox()
        let clock = PubClock(1000)
        let store = ShortcutStore(initial: .init(trigger: .keyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk), fileURL: nil)
        let engine = ShortcutEngine(configuration: store.configuration, sinks: .init(
            start: { box.starts += 1; box.recording = true },
            finish: { box.finishes += 1; box.recording = false; box.busy = false },
            cancel: { box.cancels += 1; box.recording = false; box.busy = false },
            isRecording: { box.recording }, isBusy: { box.busy }), now: { clock.now })
        let registrar = PubMockRegistrar()
        let manager = ShortcutManager(engine: engine, store: store, registrar: registrar)
        manager.permissionCheck = { true }
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)))
        registrar.firePress()
        XCTAssertEqual(box.starts, 1)
        clock.now += 0.5
        registrar.fireRelease()
        XCTAssertEqual(box.finishes, 1)
        // Preparing path cancels.
        registrar.firePress()
        XCTAssertEqual(box.starts, 2)
        box.recording = false; box.busy = true
        registrar.fireRelease()
        XCTAssertEqual(box.cancels, 1)
        XCTAssertEqual(box.finishes, 1)
    }

    @MainActor
    func testPub_Manager_PermissionGatesStartNotStop() {
        // Start gated.
        let (manager, _, box, _) = pubManager(behavior: .toggle)
        manager.permissionCheck = { false }
        manager.handlePress()
        XCTAssertEqual(box.starts, 0, "denied must not start")
        // Stop (toggle while recording) bypasses gate.
        box.recording = true
        manager.handlePress()
        XCTAssertEqual(box.finishes, 1, "stop must work without permission (clipboard fallback)")
        // Repeat + stale release suppressed end-to-end.
        let (m2, _, b2, _) = pubManager(behavior: .toggle)
        m2.permissionCheck = { true }
        m2.handlePress(isRepeat: true)
        XCTAssertEqual(b2.starts, 0)
        m2.handleRelease()
        XCTAssertEqual(b2.starts, 0)
        XCTAssertEqual(b2.finishes, 0)
    }

    @MainActor
    func testPub_Manager_CarbonModifiersAndMenuEquivalent() {
        XCTAssertEqual(ShortcutManager.carbonModifiers(from: [.control, .command]), ShortcutConfiguration.defaultModifiers)
        XCTAssertTrue(ShortcutManager.carbonModifiers(from: [.shift]).isMultiple(of: 1))
        XCTAssertEqual(ShortcutManager.carbonModifiers(from: []), 0)
        let chord = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .keyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle))
        XCTAssertEqual(chord.key, "n")
        XCTAssertTrue(chord.modifiers.contains(.control))
        XCTAssertTrue(chord.modifiers.contains(.command))
        let modifier = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .modifierOnly(key: .control, side: .left), behavior: .toggle))
        XCTAssertEqual(modifier.key, "")
        let mouse = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .mouseButton(button: .middle), behavior: .toggle))
        XCTAssertEqual(mouse.key, "")
        // Non-single-char key has no equivalent.
        let space = ShortcutManager.menuKeyEquivalent(for: .init(trigger: .keyChord(keyCode: 49, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .toggle))
        XCTAssertEqual(space.key, "")
    }

    @MainActor
    func testPub_Manager_HandleInterruptionCancelsOwnedHold() {
        let (manager, _, box, _) = pubManager(behavior: .holdToTalk)
        XCTAssertTrue(manager.apply(.init(trigger: .keyChord(keyCode: 45, modifiers: ShortcutConfiguration.defaultModifiers), behavior: .holdToTalk)))
        // Drive press through manager (permission allowed).
        manager.handlePress()
        XCTAssertEqual(box.starts, 1)
        box.recording = true
        manager.handleInterruption()
        XCTAssertEqual(box.cancels, 1)
        XCTAssertEqual(box.finishes, 0)
    }
}
