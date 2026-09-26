import Foundation

public enum RecognitionMode: String, Codable, CaseIterable {
    case dictation, streaming
    public var title: String { self == .dictation ? "Dictation" : "Streaming" }
}

public struct Configuration: Codable {
    public var executable: String
    /// Saved dictation selection, independent of the current mode.
    public var model: String
    public var mode: RecognitionMode
    public var streamingModel: String
    public var preferredMicrophone: String
    public var fallbackMicrophone: String
    /// Keep Hot windows, memory mode and the launch set (manual loads only; empty on a fresh install).
    public var residency = ResidencySettings()
    /// Catalog family id → the precision it was last loaded at (exact label). Written only by a successful Load or
    /// Reload, next to `model`/`streamingModel`; the Models table shows it on an unloaded row.
    public var lastLoaded: [String: String] = [:]
    public init(executable: String = "", model: String,
                preferredMicrophone: String = "MacBook Pro Microphone", fallbackMicrophone: String = "MacBook Pro Microphone",
                mode: RecognitionMode = .dictation, streamingModel: String = "") {
        self.executable = executable; self.model = model
        self.mode = mode; self.streamingModel = streamingModel
        self.preferredMicrophone = preferredMicrophone; self.fallbackMicrophone = fallbackMicrophone
    }
    private enum CodingKeys: String, CodingKey {
        case executable, model, mode, streamingModel, preferredMicrophone, fallbackMicrophone, residency, lastLoaded
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        executable = try values.decodeIfPresent(String.self, forKey: .executable) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        mode = try values.decodeIfPresent(RecognitionMode.self, forKey: .mode) ?? .dictation
        streamingModel = try values.decodeIfPresent(String.self, forKey: .streamingModel) ?? ""
        preferredMicrophone = try values.decodeIfPresent(String.self, forKey: .preferredMicrophone) ?? "MacBook Pro Microphone"
        fallbackMicrophone = try values.decodeIfPresent(String.self, forKey: .fallbackMicrophone) ?? "MacBook Pro Microphone"
        residency = (try? values.decodeIfPresent(ResidencySettings.self, forKey: .residency)) ?? ResidencySettings()
        lastLoaded = (try? values.decodeIfPresent([String: String].self, forKey: .lastLoaded)) ?? [:]
    }
    /// A successful Load/Reload: the model becomes its mode's model (what the next dictation or streaming session
    /// loads) and its family remembers the precision.
    public mutating func recordLoad(path: String, mode: RecognitionMode, family: String?, precision: String?) {
        selectModel(path, for: mode)
        if let family, let precision { lastLoaded[family] = precision }
    }
    public var selectedModel: String { mode == .dictation ? model : streamingModel }
    public mutating func selectModel(_ path: String, for mode: RecognitionMode) {
        if mode == .dictation { model = path } else { streamingModel = path }
    }
    public func forRecording() throws -> Configuration {
        try validate()
        var snapshot = self
        snapshot.model = selectedModel
        return snapshot
    }
    public func validate(requiresModel: Bool = true) throws {
        guard !requiresModel || !selectedModel.isEmpty else {
            throw VellaError.message("Install a \(mode.title.lowercased()) model and choose Use.")
        }
    }
}
public enum VellaError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}
public struct Microphone: Equatable {
    public let id: UInt32
    public let name: String
    public init(id: UInt32, name: String) { self.id = id; self.name = name }
}
public func selectMicrophone(_ devices: [Microphone], preferred: String, fallback: String) -> Microphone? {
    devices.first { $0.name == preferred } ?? devices.first { $0.name == fallback }
        ?? devices.first { $0.name.contains("MacBook") && $0.name.contains("Microphone") }
}
/// Map microphone RMS to a visible, bounded level. Silence stays still.
public func visualLevel(rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 55) / 45))
}
