import AppKit
import AVFoundation
import CoreAudio

/// Notifications name the boundary; the controller owns saving and insertion policy.
@MainActor final class HardwareEvents {
    enum Event { case willSleep, didWake, microphoneChanged }
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    init(
        workspace: NotificationCenter, capture: NotificationCenter, matchesCapture: @escaping (Any?) -> Bool,
        matchesDevice: @escaping (Any?) -> Bool, monitorDefaultInput: Bool = true, defaultInputMatters: @escaping () -> Bool = { true }, receive: @escaping (Event) -> Void
    ) {
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event, matches: @escaping (Any?) -> Bool = { _ in true }) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated { if matches(notification.object) { receive(event) } }
            }
            tokens.append((center, token))
        }
        observe(workspace, NSWorkspace.willSleepNotification, .willSleep)
        observe(workspace, NSWorkspace.didWakeNotification, .didWake)
        observe(capture, AVCaptureDevice.wasDisconnectedNotification, .microphoneChanged, matches: matchesDevice)
        observe(capture, AVCaptureSession.wasInterruptedNotification, .microphoneChanged, matches: matchesCapture)
        observe(capture, AVCaptureSession.runtimeErrorNotification, .microphoneChanged, matches: matchesCapture)
        if monitorDefaultInput {
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in if defaultInputMatters() { receive(.microphoneChanged) } }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress, .main, listener) == noErr { inputListener = listener }
        }
    }
    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
        if let listener = inputListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress, .main, listener); inputListener = nil }
    }
    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
        if let listener = inputListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress, .main, listener) }
    }
}
