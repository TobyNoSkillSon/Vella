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
    public init(executable: String, model: String,
                preferredMicrophone: String = "MacBook Pro Microphone", fallbackMicrophone: String = "MacBook Pro Microphone",
                mode: RecognitionMode = .dictation, streamingModel: String = "") {
        self.executable = executable; self.model = model
        self.mode = mode; self.streamingModel = streamingModel
        self.preferredMicrophone = preferredMicrophone; self.fallbackMicrophone = fallbackMicrophone
    }
    private enum CodingKeys: String, CodingKey {
        case executable, model, mode, streamingModel, preferredMicrophone, fallbackMicrophone
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        executable = try values.decodeIfPresent(String.self, forKey: .executable) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        mode = try values.decodeIfPresent(RecognitionMode.self, forKey: .mode) ?? .dictation
        streamingModel = try values.decodeIfPresent(String.self, forKey: .streamingModel) ?? ""
        preferredMicrophone = try values.decodeIfPresent(String.self, forKey: .preferredMicrophone) ?? "MacBook Pro Microphone"
        fallbackMicrophone = try values.decodeIfPresent(String.self, forKey: .fallbackMicrophone) ?? "MacBook Pro Microphone"
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
        guard !executable.isEmpty, !requiresModel || !selectedModel.isEmpty else {
            throw VellaError.message("Set up Vella’s Python runtime, install a \(mode.title.lowercased()) model and choose Use.")
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
public func multipart(audio: Data, model: String, boundary: String) -> Data {
    var result = Data()
    func append(_ text: String) { result.append(Data(text.utf8)) }
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
    result.append(audio); append("\r\n--\(boundary)--\r\n")
    return result
}
public func transcript(from data: Data) throws -> String {
    struct Response: Decodable { let text: String }
    let text = try JSONDecoder().decode(Response.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text
}

/// Map microphone RMS to a visible, bounded level. Silence stays still.
public func visualLevel(rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 55) / 45))
}
