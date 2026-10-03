import Foundation

public struct Microphone: Equatable {
    public let id: UInt32
    public let name: String
    public init(id: UInt32, name: String) { self.id = id; self.name = name }
}
public struct MicrophoneSelection: Equatable {
    public let device: Microphone
    public let followsSystemDefault: Bool
}
/// An empty preference means System Default, never a retained legacy fallback. Explicit choices retain their fallback.
public func microphoneSelection(_ devices: [Microphone], preferred: String, fallback: String, systemDefaultID: UInt32? = nil) -> MicrophoneSelection? {
    if !preferred.isEmpty {
        if let device = devices.first(where: { $0.name == preferred }) { return MicrophoneSelection(device: device, followsSystemDefault: false) }
        if !fallback.isEmpty, let device = devices.first(where: { $0.name == fallback }) { return MicrophoneSelection(device: device, followsSystemDefault: false) }
    }
    guard let device = devices.first(where: { $0.id == systemDefaultID }) ?? devices.first else { return nil }
    return MicrophoneSelection(device: device, followsSystemDefault: true)
}
public func selectMicrophone(_ devices: [Microphone], preferred: String, fallback: String, systemDefaultID: UInt32? = nil) -> Microphone? {
    microphoneSelection(devices, preferred: preferred, fallback: fallback, systemDefaultID: systemDefaultID)?.device
}
/// Map microphone RMS to a visible, bounded level. Silence stays still.
public func visualLevel(rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 55) / 45))
}
