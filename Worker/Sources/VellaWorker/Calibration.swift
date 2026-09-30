import Foundation
import CryptoKit
import Darwin
import MLX
import Cmlx
import VellaWorkerSupport
import VellaWire

private enum CalibrationFailure: Error {
    case message(String)
}

struct CalibrationSample {
    static let audioSHA256 = "e36af54bcd25cbbb9c1adba8ff28bc7a4001a91f6bfdbc3360df9efd395bafa2"
    static let textSHA256 = "5d1772325ea342a62f30872e6ce9fb4c109dc20aa997bd921e9c92385a997d7e"
    let audio: URL
    let seconds: Double

    init(_ path: String) throws {
        let source = try localPath(path)
        let directory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let folder = directory ? source : source.deletingLastPathComponent()
        audio = directory ? folder.appendingPathComponent("speech.wav") : source
        let manifest = try jsonObject(folder.appendingPathComponent("manifest.json"))
        func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        guard try digest(audio) == Self.audioSHA256,
              manifest["sha256"] as? String == Self.audioSHA256,
              try digest(folder.appendingPathComponent("text.txt")) == Self.textSHA256,
              manifest["textSHA256"] as? String == Self.textSHA256 else {
            throw CalibrationFailure.message("Calibration sample identity mismatch")
        }
        let checked: Audio
        do { checked = try Audio(audio.path) }
        catch { throw CalibrationFailure.message("Unexpected calibration audio format") }
        seconds = checked.seconds
        guard (3...15).contains(seconds), let declared = manifest["audioSeconds"] as? Double,
              abs(declared - seconds) <= 0.0001 else {
            throw CalibrationFailure.message("Unexpected calibration duration")
        }
    }
}

enum CalibrationCommand {
    static func run(arguments: [String], output: Int32) async -> Int32 {
        alarm(120) // One deadline covers admission, load and all three passes.
        defer { alarm(0) }
        let worker = Worker()
        var loadingStarted = false
        defer { if loadingStarted { try? worker.release() } }
        func emit(_ event: String, _ payload: [String: Any]) throws {
            var object = payload; object["event"] = event
            guard writeAll(output, try responseBytes(object)) else { throw CocoaError(.fileWriteUnknown) }
        }
        do {
            guard arguments.count == 4 else { throw CalibrationFailure.message("Invalid calibration arguments") }
            var options: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                guard ["--model", "--sample"].contains(key), options[key] == nil else {
                    throw CalibrationFailure.message("Invalid calibration arguments")
                }
                options[key] = arguments[index+1]
            }
            guard let modelArgument = options["--model"], let sampleArgument = options["--sample"] else {
                throw CalibrationFailure.message("Invalid calibration arguments")
            }
            let path = try localPath(modelArgument)
            let architecture = try admit(path)
            let sample = try CalibrationSample(sampleArgument)
            try emit("progress", ["message": "Calibrating: loading local weights…"])
            loadingStarted = true
            let loadStart = ProcessInfo.processInfo.systemUptime
            worker.model = try await withError { try await worker.load(path, architecture: architecture) }
            try withError { Stream.gpu.synchronize() }
            let loadSeconds = ProcessInfo.processInfo.systemUptime-loadStart
            func measure() throws -> Double {
                try withError { Stream.gpu.synchronize() }
                let start = ProcessInfo.processInfo.systemUptime
                let text = try worker.infer(Audio(sample.audio.path))
                guard text.unicodeScalars.count >= 10 else {
                    throw CalibrationFailure.message("Calibration produced no usable speech text")
                }
                let elapsed = ProcessInfo.processInfo.systemUptime-start
                guard elapsed.isFinite, elapsed > 0 else { throw CalibrationFailure.message("Invalid inference timing") }
                return elapsed
            }
            try emit("progress", ["message": "Calibrating: first request…"])
            let first = try measure()
            var warm: [Double] = []
            for pass in 1...2 {
                try emit("progress", ["message": "Calibrating: warm pass \(pass)/2…"])
                warm.append(try measure())
            }
            var version = mlx_string_new()
            mlx_version(&version)
            let mlxVersion = String(cString: mlx_string_data(version))
            mlx_string_free(version)
            var parameters: [String: Any] = [:]
            // Match the reference's inspect.signature filtering of supported options.
            if architecture != .parakeet { parameters["verbose"] = false }
            if architecture == .qwen3ASR { parameters["max_tokens"] = 1024 }
            if [.parakeet, .qwen3ASR, .whisper].contains(architecture) { parameters["chunk_duration"] = 30.0 }
            parameters["stream"] = false
            try emit("result", ["result": [
                "audioSeconds": sample.seconds, "loadSeconds": loadSeconds,
                "firstRequestSeconds": first, "warmSeconds": warm,
                "speed": sample.seconds / ((warm[0]+warm[1])/2),
                "sampleSHA256": CalibrationSample.audioSHA256,
                "mlxVersion": mlxVersion, "mlxAudioVersion": "mlx-audio-swift@01dec7c9+vella-parity",
                "parameters": parameters
            ]])
            return 0
        } catch {
            let message: String
            if case CalibrationFailure.message(let value) = error { message = value }
            else { message = "Local calibration failed." }
            try? emit("error", ["message": message])
            return 1
        }
    }
}
