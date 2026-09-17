import XCTest
import AppKit
import Carbon
import VellaCore
import IOKit.hidsystem
@testable import Vella

/// Native Carbon registration/dispatch, without posting keyboard input or starting capture.
final class ShortcutNativeDispatchTests: XCTestCase {
    @MainActor func testTapDisableInvalidatesPressAlreadyQueuedForDelivery() throws {
        let tap = EventTapShortcutRegistrar()
        defer { tap.unregister() }
        var starts = 0, interruptions = 0
        tap.primeForTesting(.init(trigger: .mouseButton(button: .middle), behavior: .toggle),
                            onPress: { starts += 1 }, onRelease: {})
        tap.interruptionHandler = { interruptions += 1 }
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .otherMouseDown
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        XCTAssertTrue(tap.processTapEvent(type: .otherMouseDown, event: event))
        XCTAssertFalse(tap.processTapEvent(type: .tapDisabledByTimeout, event: event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(starts, 0, "A disabled tap must invalidate a queued activation before it can start capture")
        XCTAssertEqual(interruptions, 1)
    }

    @MainActor func testNativeModifierSidesCannotRearmOnOppositeSideRelease() throws {
        let pairs: [(ModifierKey, CGEventFlags, Int32, Int32)] = [
            (.command, .maskCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK),
            (.control, .maskControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK),
            (.option, .maskAlternate, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK),
            (.shift, .maskShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK)
        ]
        for (key, aggregate, left, right) in pairs {
            for side in [ModifierSide.left, .right] {
                let targetMask = side == .left ? left : right
                let oppositeMask = side == .left ? right : left
                let opposite: ModifierSide = side == .left ? .right : .left
                let tap = EventTapShortcutRegistrar()
                defer { tap.unregister() }
                var starts = 0
                let config = ShortcutConfiguration(trigger: .modifierOnly(key: key, side: side), behavior: .holdToTalk)
                tap.primeForTesting(config, onPress: { starts += 1 }, onRelease: {})
                func flags(_ side: ModifierSide, _ mask: Int32) throws {
                    let event = try XCTUnwrap(CGEvent(source: nil))
                    event.type = .flagsChanged
                    event.setIntegerValueField(.keyboardEventKeycode,
                                               value: Int64(EventTapShortcutRegistrar.modifierCode(key: key, side: side)))
                    event.flags = CGEventFlags(rawValue: aggregate.rawValue | UInt64(mask))
                    XCTAssertFalse(tap.processTapEvent(type: .flagsChanged, event: event))
                }
                try flags(side, targetMask)
                try flags(opposite, left | right)
                try flags(side, oppositeMask) // Target is UP, aggregate flag remains set.
                XCTAssertEqual(tap.simulateSoloEvent(.holdTimeout(time: 1)), .none)
                XCTAssertEqual(starts, 0, "Opposite-side hold must not rearm \(key) \(side)")
                tap.primeForTesting(config, onPress: { starts += 1 }, onRelease: {})
                try flags(side, left | right) // Opposite was already down at target-down.
                XCTAssertEqual(tap.simulateSoloEvent(.holdTimeout(time: 1)), .none)
                XCTAssertEqual(starts, 0)
                tap.primeForTesting(config, onPress: { starts += 1 }, onRelease: {})
                try flags(side, targetMask)
                XCTAssertEqual(tap.simulateSoloEvent(.holdTimeout(time: 1)), .press)
                XCTAssertEqual(starts, 1, "A genuine solo hold must still work")
            }
        }
    }

    @MainActor func testPermissionLossDoesNotDisableFinishingAnActiveRecording() {
        var finishes = 0
        let engine = ShortcutEngine(configuration: .default, sinks: .init(
            start: { XCTFail("Must not start") }, finish: { finishes += 1 }, cancel: {},
            isRecording: { true }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: NativeMenuFixtureRegistrar())
        manager.permissionCheck = { false }
        manager.handlePress()
        XCTAssertEqual(finishes, 1, "Losing insertion permission must not disable the stop shortcut")
    }

    @MainActor private func dispatch(_ id: EventHotKeyID?, kind: UInt32 = UInt32(kEventHotKeyPressed)) throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0,
                                   EventAttributes(kEventAttributeNone), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        if var id {
            XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                            &id), noErr)
        }
        _ = SendEventToEventTarget(created, GetApplicationEventTarget())
    }

    @MainActor func testNativeCallbacksRequireCurrentRegistrationAndGeneration() throws {
        _ = NSApplication.shared
        let shortcut = GlobalShortcut()
        defer { shortcut.unregister() }
        var first = 0, replacement = 0, releases = 0
        try shortcut.registerChord(keyCode: UInt32(kVK_F17),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey),
                                   onPress: { first += 1 }, onRelease: { releases += 1 })
        let id = try XCTUnwrap(shortcut.registeredHotKeyID)
        try dispatch(id)
        try dispatch(id, kind: UInt32(kEventHotKeyReleased))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(releases, 1)
        try dispatch(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(first, 1, "Malformed native events must be ignored")
        try dispatch(id)
        shortcut.updateHandlers(onPress: { replacement += 1 }, onRelease: {})
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(first, 1, "Queued old callbacks must be cancelled, not merely copied")
        XCTAssertEqual(replacement, 0)
        try dispatch(id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(replacement, 1)
        try dispatch(id)
        shortcut.unregister()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(replacement, 1, "Unregister must invalidate queued delivery")
    }

    @MainActor func testChangingBehaviorKeepsSameNativeChordRegistered() throws {
        _ = NSApplication.shared
        let registrar = CarbonShortcutRegistrar()
        defer { registrar.unregister() }
        let trigger = ShortcutTrigger.keyChord(keyCode: UInt32(kVK_F18),
                                              modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        try registrar.register(.init(trigger: trigger, behavior: .toggle), onPress: {}, onRelease: {})
        XCTAssertNoThrow(try registrar.register(.init(trigger: trigger, behavior: .holdToTalk),
                                                onPress: {}, onRelease: {}))
        XCTAssertEqual(registrar.registered?.behavior, .holdToTalk)
    }

    @MainActor func testBehaviorSelectionPreservesTrackedNativeMenu() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(configurationURL: root.appendingPathComponent("config.json"))
        defer { model.shutdown() }
        let engine = ShortcutEngine(configuration: .default, sinks: .init(
            start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false }))
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: NativeMenuFixtureRegistrar())
        let delegate = AppDelegate(model: model, shortcutManager: manager)
        delegate.rebuildMenu()
        let original = delegate.menu.items
        let submenu = try XCTUnwrap(delegate.menu.item(withTitle: "Shortcuts")?.submenu)
        let hold = try XCTUnwrap(submenu.item(withTitle: "Hold to Talk") as? SettingsMenuItem)
        delegate.menuWillOpen(delegate.menu)
        defer { delegate.menuDidClose(delegate.menu) }
        hold.control.performClick(nil)
        XCTAssertEqual(manager.configuration.behavior, .holdToTalk)
        XCTAssertTrue(delegate.menu.item(withTitle: "Shortcuts")?.submenu === submenu)
        XCTAssertEqual(original.count, delegate.menu.items.count)
        for (before, after) in zip(original, delegate.menu.items) { XCTAssertTrue(before === after) }
        XCTAssertEqual(hold.control.state, .on)
    }

    @MainActor func testForeignCarbonHotkeyIsNotAnActivation() throws {
        _ = NSApplication.shared
        let shortcut = GlobalShortcut()
        defer { shortcut.unregister() }
        var activations = 0
        try shortcut.registerChord(keyCode: UInt32(kVK_F20),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey),
                                   onPress: { activations += 1 }, onRelease: {})
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   0, EventAttributes(kEventAttributeNone), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var foreignID = EventHotKeyID(signature: 0x51545453, id: 0x7ffffffe)
        XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                        &foreignID), noErr)
        _ = SendEventToEventTarget(created, GetApplicationEventTarget())
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(activations, 0, "Only this registration's hotkey ID may activate Vella")
    }

    @MainActor func testNativeRegistrationConflictDoesNotDestroyExistingBinding() throws {
        _ = NSApplication.shared
        let first = GlobalShortcut(), second = GlobalShortcut()
        defer { first.unregister(); second.unregister() }
        let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        try first.registerChord(keyCode: UInt32(kVK_F19), modifiers: modifiers,
                                onPress: {}, onRelease: {})
        XCTAssertThrowsError(try second.registerChord(keyCode: UInt32(kVK_F19), modifiers: modifiers,
                                                       onPress: {}, onRelease: {}))
        // The first reservation must still be held after the failed second registration.
        XCTAssertThrowsError(try second.registerChord(keyCode: UInt32(kVK_F19), modifiers: modifiers,
                                                       onPress: {}, onRelease: {}))
        first.unregister()
        XCTAssertNoThrow(try second.registerChord(keyCode: UInt32(kVK_F19), modifiers: modifiers,
                                                  onPress: {}, onRelease: {}))
    }
}

private final class NativeMenuFixtureRegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void,
                  onRelease: @escaping () -> Void) throws { registered = config }
    func unregister() { registered = nil }
}
