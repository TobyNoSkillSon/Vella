import Foundation

public struct Microphone: Equatable {
    public let id: UInt32
    public let name: String
    public init(id: UInt32, name: String) { self.id = id; self.name = name }
}
public func selectMicrophone(_ devices: [Microphone], preferred: String, fallback: String, systemDefaultID: UInt32? = nil) -> Microphone? {
    devices.first { !$0.name.isEmpty && $0.name == preferred } ?? devices.first { !$0.name.isEmpty && $0.name == fallback }
        ?? devices.first { $0.id == systemDefaultID } ?? devices.first
}
/// Map microphone RMS to a visible, bounded level. Silence stays still.
public func visualLevel(rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 55) / 45))
}
