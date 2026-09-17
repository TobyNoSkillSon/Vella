import XCTest
@testable import VellaCore

final class ShortcutCoreTests: XCTestCase {
    func testDefaultIsCtrlCmdNToggle() {
        let def = ShortcutConfiguration.default
        XCTAssertEqual(def.behavior, .toggle)
        guard case .keyChord(let code, let mods) = def.trigger else { return XCTFail("default must be keyChord") }
        XCTAssertEqual(code, 45)
        XCTAssertEqual(mods, ShortcutConfiguration.defaultModifiers)
        XCTAssertEqual(mods, 4352)
        XCTAssertFalse(def.trigger.requiresEventTap)
        XCTAssertEqual(ShortcutLabels.display(def), "⌃⌘N · Toggle")
    }
    func testKeyChordValidation() {
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 0))
        XCTAssertNotNil(ShortcutValidation.validate(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertNil(ShortcutValidation.validate(.default))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 53, modifiers: 4352)) // Esc
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 55, modifiers: 4352)) // modifier key itself
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 12, modifiers: 256)) // Cmd+Q
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 12, modifiers: 4352)) // Ctrl+Cmd+Q lock
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 49, modifiers: 256)) // Cmd+Space
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 9, modifiers: 256)) // plain Cmd+V reserved for paste
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 9, modifiers: 4352)) // Ctrl+Cmd+V allowed
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 4352))
        // Strict Carbon flags: unknown/Fn-only bits would degrade into a bare hotkey.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 4352 | 0x800000))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 45, modifiers: 1 << 20))
        // Shift alone on typing keys hijacks typing; Shift+F-keys remain safe.
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 8, modifiers: 512))
        XCTAssertNotNil(ShortcutValidation.validateKeyChord(keyCode: 49, modifiers: 512))
        XCTAssertNil(ShortcutValidation.validateKeyChord(keyCode: 122, modifiers: 512))
        // Modifier-only and mouse are valid types; Fn carries a reliability note, not an error.
        XCTAssertNil(ShortcutValidation.validate(.init(trigger: .modifierOnly(key: .control, side: .left), behavior: .holdToTalk)))
        XCTAssertNil(ShortcutValidation.validate(.init(trigger: .modifierOnly(key: .function, side: .left), behavior: .toggle)))
        XCTAssertFalse(ShortcutValidation.functionKeyReliabilityNote.isEmpty)
        XCTAssertNil(ShortcutValidation.validate(.init(trigger: .mouseButton(button: .middle), behavior: .toggle)))
    }
    func testTriggerRequiresEventTap() {
        XCTAssertFalse(ShortcutConfiguration(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .modifierOnly(key: .control, side: .left), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertTrue(ShortcutConfiguration(trigger: .mouseButton(button: .button3), behavior: .toggle).trigger.requiresEventTap)
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.modifierOnly(key: .control, side: .left)), "Left ⌃")
        XCTAssertEqual(ShortcutLabels.triggerDisplay(.mouseButton(button: .middle)), "Middle Click")
    }
    func testStoreSaveRejectsInvalidAndKeepsPrevious() {
        let store = ShortcutStore(initial: .default, fileURL: nil)
        XCTAssertFalse(store.save(.init(trigger: .keyChord(keyCode: 45, modifiers: 0), behavior: .toggle)))
        XCTAssertEqual(store.configuration, .default)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.save(.init(trigger: .keyChord(keyCode: 8, modifiers: 4352), behavior: .holdToTalk)))
        XCTAssertNil(store.lastError)
    }
    func testStoreRoundTripAndReset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vella-shortcut-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shortcuts.json")
        let store = ShortcutStore(initial: .default, fileURL: url)
        let custom = ShortcutConfiguration(trigger: .modifierOnly(key: .option, side: .right), behavior: .holdToTalk)
        XCTAssertTrue(store.save(custom))
        let reloaded = ShortcutStore(initial: .default, fileURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.configuration, custom)
        XCTAssertEqual(reloaded.resetToDefault(), .default)
        XCTAssertEqual(ShortcutStore(initial: .default, fileURL: url).configuration, .default)
    }
    // MARK: Engine
    private func engineWithFlags(behavior: ShortcutBehavior, now: @escaping () -> TimeInterval = { 1000 }) -> (ShortcutEngine, RecordingBox) {
        let box = RecordingBox()
        let engine = ShortcutEngine(configuration: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: behavior),
            sinks: .init(start: { box.starts += 1 }, finish: { box.finishes += 1 }, cancel: { box.cancels += 1 },
                isRecording: { box.recording }, isBusy: { box.busy }), now: now)
        return (engine, box)
    }
    final class RecordingBox {
        var recording = false
        var busy = false
        var starts = 0
        var finishes = 0
        var cancels = 0
    }
    func testTogglePressReleaseSemantics() {
        let (engine, box) = engineWithFlags(behavior: .toggle)
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        XCTAssertFalse(engine.release()) // release ignored
        XCTAssertEqual(box.finishes, 0)
        box.recording = true
        XCTAssertTrue(engine.press()) // second press toggles off
        XCTAssertEqual(box.finishes, 1)
        XCTAssertFalse(engine.release())
        // Repeat + duplicate + stale suppressed.
        XCTAssertFalse(engine.press(isRepeat: true))
        let (e2, b2) = engineWithFlags(behavior: .toggle)
        XCTAssertTrue(e2.press())
        XCTAssertFalse(e2.press()) // duplicate while held
        XCTAssertEqual(b2.starts, 1)
        XCTAssertFalse(ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false })).release())
    }
    func testToggleBusySuppresses() {
        let (engine, box) = engineWithFlags(behavior: .toggle)
        box.busy = true
        XCTAssertFalse(engine.press())
        XCTAssertEqual(box.starts, 0)
        XCTAssertFalse(engine.canChangeSettings)
    }
    func testHoldStartFinishAndPreparingAbort() {
        var t = 1000.0
        let (engine, box) = engineWithFlags(behavior: .holdToTalk, now: { t })
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        box.recording = true
        t += 0.5
        XCTAssertTrue(engine.release())
        XCTAssertEqual(box.finishes, 1)
        // Hold release during preparing must cancel, not run away.
        let (e2, b2) = engineWithFlags(behavior: .holdToTalk, now: { t })
        XCTAssertTrue(e2.press())
        b2.busy = true // async preparing, not yet recording
        XCTAssertTrue(e2.release())
        XCTAssertEqual(b2.cancels, 1)
        XCTAssertEqual(b2.finishes, 0)
    }
    func testHoldNeverFinishesForeignCapture() {
        let (engine, box) = engineWithFlags(behavior: .holdToTalk)
        box.recording = true // foreign menu start, no active press
        XCTAssertFalse(engine.press())
        XCTAssertEqual(box.starts, 0)
        XCTAssertFalse(engine.release()) // stale release must not finish foreign
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
    }
    func testStalePressIDNeverFinishes() {
        var t = 1000.0
        let (engine, box) = engineWithFlags(behavior: .holdToTalk, now: { t })
        XCTAssertTrue(engine.press())
        let owned = engine.activePressID!
        box.recording = true
        XCTAssertFalse(engine.releaseForPressID(owned + 999))
        XCTAssertEqual(box.finishes, 0)
        t += 0.5
        XCTAssertTrue(engine.releaseForPressID(owned))
        XCTAssertEqual(box.finishes, 1)
        XCTAssertFalse(engine.releaseForPressID(owned)) // duplicate release suppressed
    }
    func testInterruptionCancelsOwnedHold() {
        let (engine, box) = engineWithFlags(behavior: .holdToTalk)
        XCTAssertTrue(engine.press())
        box.recording = true
        engine.handleInterruption()
        XCTAssertEqual(box.cancels, 1)
        XCTAssertEqual(box.finishes, 0)
        XCTAssertNil(engine.activePressID)
        XCTAssertFalse(engine.release())
    }
    func testTapOrHoldBoundary() {
        var t = 1000.0
        // Short tap keeps.
        let (e1, b1) = engineWithFlags(behavior: .tapOrHold, now: { t })
        XCTAssertTrue(e1.press())
        b1.recording = true
        t += 0.299
        XCTAssertFalse(e1.release()) // tap keeps
        XCTAssertEqual(b1.finishes, 0)
        // Tap-off finishes on next cycle.
        XCTAssertTrue(e1.press())
        t += 0.1
        b1.recording = true
        XCTAssertTrue(e1.release())
        XCTAssertEqual(b1.finishes, 1)
        // Long hold finishes.
        t = 2000.0
        let (e2, b2) = engineWithFlags(behavior: .tapOrHold, now: { t })
        XCTAssertTrue(e2.press())
        b2.recording = true
        t += 0.300 // boundary belongs to hold
        XCTAssertTrue(e2.release())
        XCTAssertEqual(b2.finishes, 1)
    }
    func testOperationOwnershipBlocksForeignFinishStart() {
        var generation: UInt64 = 5
        let box = RecordingBox()
        let engine = ShortcutEngine(configuration: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .holdToTalk),
            sinks: .init(start: { box.starts += 1; generation &+= 1; box.recording = true },
                finish: { box.finishes += 1; generation &+= 1; box.recording = false },
                cancel: { box.cancels += 1; generation &+= 1; box.recording = false; box.busy = false },
                isRecording: { box.recording }, isBusy: { box.busy },
                currentOperation: { generation }), now: { 1000 })
        XCTAssertTrue(engine.press())
        XCTAssertEqual(box.starts, 1)
        // Manual menu Finish + new Start replaces the capture (generation bumps twice).
        box.recording = false; generation &+= 1 // foreign finish
        box.recording = true; generation &+= 1 // foreign new start
        XCTAssertFalse(engine.release()) // stale release must not finish unrelated capture
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
    }
    func testTapWhilePreparingRetainsToggle() {
        var t = 1000.0
        let box = RecordingBox()
        let engine = ShortcutEngine(configuration: .init(trigger: .keyChord(keyCode: 45, modifiers: 4352), behavior: .tapOrHold),
            sinks: .init(start: { box.starts += 1 }, finish: { box.finishes += 1 }, cancel: { box.cancels += 1 },
                isRecording: { box.recording }, isBusy: { box.busy }), now: { t })
        XCTAssertTrue(engine.press())
        box.busy = true // still preparing at quick release
        t += 0.1
        XCTAssertFalse(engine.release()) // tap keeps; preparing continues toward recording
        XCTAssertEqual(box.finishes, 0)
        XCTAssertEqual(box.cancels, 0)
        box.busy = false; box.recording = true
        XCTAssertTrue(engine.press()) // tap-off arms
        t += 0.1
        XCTAssertTrue(engine.release())
        XCTAssertEqual(box.finishes, 1)
    }
    func testSoloReducerOrdinaryChordNeverFires() {
        var state = SoloModifierState()
        // Left Cmd down sole for a Cmd+C chord, then C keyDown cancels.
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .toggle), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .otherKeyDown(time: 0.05), targetKey: .command, targetSide: .left, behavior: .toggle), .cancelled)
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .targetUp(key: .command, side: .left, time: 0.1), targetKey: .command, targetSide: .left, behavior: .toggle), .none)
    }
    func testSoloReducerSidesAndHold() {
        var state = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        // Right side does not satisfy Left target.
        XCTAssertEqual(ModifierSoloReducer.step(state: &state, event: .otherModifierDown(time: 0.05), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .cancelled)
        var solo = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &solo, event: .targetDown(key: .control, side: .left, time: 0, sole: true), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &solo, event: .holdTimeout(time: 0.35), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .press)
        XCTAssertEqual(ModifierSoloReducer.step(state: &solo, event: .targetUp(key: .control, side: .left, time: 0.5), targetKey: .control, targetSide: .left, behavior: .holdToTalk), .holdRelease)
        // Toggle never fires press on hold timeout; tap release yields tap.
        var toggle = SoloModifierState()
        XCTAssertEqual(ModifierSoloReducer.step(state: &toggle, event: .targetDown(key: .command, side: .left, time: 0, sole: true), targetKey: .command, targetSide: .left, behavior: .toggle), .pending)
        XCTAssertEqual(ModifierSoloReducer.step(state: &toggle, event: .holdTimeout(time: 0.4), targetKey: .command, targetSide: .left, behavior: .toggle), .none)
        XCTAssertEqual(ModifierSoloReducer.step(state: &toggle, event: .targetUp(key: .command, side: .left, time: 0.45), targetKey: .command, targetSide: .left, behavior: .toggle), .tapRelease)
    }
}
