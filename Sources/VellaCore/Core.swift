import Foundation

public struct Configuration: Codable {
    public var executable: String
    public var model: String
    public var preferredMicrophone: String
    public var fallbackMicrophone: String
    public init(executable: String, model: String,
                preferredMicrophone: String = "MacBook Pro Microphone", fallbackMicrophone: String = "MacBook Pro Microphone") {
        self.executable = executable; self.model = model
        self.preferredMicrophone = preferredMicrophone; self.fallbackMicrophone = fallbackMicrophone
    }
    public func validate(requiresModel: Bool = true) throws {
        guard !executable.isEmpty, !requiresModel || !model.isEmpty else {
            throw VellaError.message("Set up Vella’s Python runtime, install a model and choose Use.")
        }
    }
}
public enum VellaError: LocalizedError {
    case message(String)
    case noSpeech
    case unrecognizedAudio
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .noSpeech: return "No speech detected. Try recording again."
        case .unrecognizedAudio: return "Some audio was not recognized. An explicitly marked incomplete transcript is available; nothing was automatically pasted. Retry missing segments or review the saved audio."
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
    guard !text.isEmpty else { throw VellaError.noSpeech }
    return text
}

/// Map microphone RMS to a visible, bounded level. Silence stays still.
public func visualLevel(rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 55) / 45))
}
