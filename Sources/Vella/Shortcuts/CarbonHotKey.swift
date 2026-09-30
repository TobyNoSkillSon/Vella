import AppKit
import SwiftUI
import AVFoundation
import Carbon
import ApplicationServices
import QuartzCore
import VellaCore

final class GlobalShortcut {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var currentID: EventHotKeyID?
    private var callbackGeneration: UInt64 = 0
    var registeredHotKeyID: EventHotKeyID? { currentID }
    private static var nextHotKeyID: UInt32 = 1
    var action: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    func register() -> Bool {
        do {
            try registerChord(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | cmdKey), onPress: { [weak self] in self?.action?() }, onRelease: {})
            return true
        } catch { return false }
    }
    func registerChord(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        unregister()
        // Capture the generation via unique hotkey ID: async delivery checks the ID
        // at event time so a queued old press can never invoke a rebind's closure.
        let assigned = EventHotKeyID(signature: 0x56454C41, id: Self.nextHotKeyID)
        Self.nextHotKeyID &+= 1
        self.onPress = onPress
        self.onRelease = onRelease
        self.currentID = assigned
        let pressType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let releaseType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Non-capturing Carbon handler: all state arrives via `data`.
        // Foreign hotkey IDs are ignored; closures are captured at event time so a
        // queued old press can never invoke a rebind's new closure.
        let handlerUPP: EventHandlerUPP = { _, event, data in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue()
            var received = EventHotKeyID(signature: 0, id: 0)
            let paramStatus = withUnsafeMutablePointer(to: &received) { ptr in
                GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, ptr)
            }
            guard paramStatus == noErr, let expected = hotkey.currentID,
                  received.signature == expected.signature, received.id == expected.id else {
                return OSStatus(eventNotHandledErr)
            }
            let generation = hotkey.callbackGeneration
            let kind = GetEventKind(event)
            guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
                return OSStatus(eventNotHandledErr)
            }
            let action = kind == UInt32(kEventHotKeyPressed) ? (hotkey.onPress ?? hotkey.action) : hotkey.onRelease
            DispatchQueue.main.async { [weak hotkey] in
                guard let hotkey, hotkey.callbackGeneration == generation,
                      let current = hotkey.currentID,
                      current.signature == expected.signature, current.id == expected.id else { return }
                action?()
            }
            return noErr
        }
        var specs = [pressType, releaseType]
        let installed: OSStatus = withUnsafeMutablePointer(to: &handler) { handlerPtr in
            specs.withUnsafeMutableBufferPointer { buffer in
                InstallEventHandler(GetApplicationEventTarget(), handlerUPP, buffer.count, buffer.baseAddress, context, handlerPtr)
            }
        }
        guard installed == noErr else {
            unregister()
            throw VellaError.message("Could not register \(ShortcutLabels.keyChordDisplay(keyCode: keyCode, modifiers: modifiers)). Choose another shortcut.")
        }
        let status = RegisterEventHotKey(keyCode, modifiers, assigned, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            unregister()
            throw VellaError.message("\(ShortcutLabels.keyChordDisplay(keyCode: keyCode, modifiers: modifiers)) is already in use or unavailable. Choose another shortcut.")
        }
    }
    func unregister() {
        callbackGeneration &+= 1
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        onPress = nil; onRelease = nil; currentID = nil
    }
    func updateHandlers(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        callbackGeneration &+= 1
        self.onPress = onPress
        self.onRelease = onRelease
    }
    deinit { if let ref { UnregisterEventHotKey(ref) }; if let handler { RemoveEventHandler(handler) } }
}
