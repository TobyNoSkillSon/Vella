import Foundation

@main struct Checks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func rejects(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection") } catch {}
        }
        for id in [UUID().uuidString, "00112233445566778899aabbccddeeff", "urn:uuid:00112233-4455-6677-8899-aabbccddeeff", "{00112233-4455-6677-8899-aabbccddeeff}"] { precondition(validIdentifier(id) == id) }
        for id in ["", "not-a-uuid", "00112233445566778899aabbccddeezz"] { precondition(validIdentifier(id) == nil) }
        precondition(validIdentifier(12) == nil)
        let constants = try decodeJSON(Data(#"{"value":NaN,"positive":Infinity,"negative":-Infinity,"literal":"NaN Infinity"}"#.utf8)) as! [String: Any]
        precondition(pythonTruthy(constants["value"]) && constants["literal"] as? String == "NaN Infinity")
        precondition(!pythonTruthy([] as [Any]) && !pythonTruthy([:] as [String: Any]) && !pythonTruthy(NSNull()))
        func writeConfig(_ config: [String: Any]) throws { try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("config.json")) }
        try Data().write(to: folder.appendingPathComponent("model.safetensors"))
        for arch in ["whisper", "qwen3_asr", "parakeet", "granite_speech"] {
            try writeConfig(["model_type": arch]); let admitted = try admit(folder); precondition(admitted == arch)
        }
        try writeConfig(["model_type": "sensevoice"]); rejects { _ = try admit(folder) }
        try Data().write(to: folder.appendingPathComponent("am.mvn")); let sense = try admit(folder); precondition(sense == "sensevoice")
        try writeConfig(["model_type": "parakeet", "quantization": ["bits": 2]]); rejects { _ = try admit(folder) }
        try writeConfig(["model_type": "parakeet", "auto_map": ["Model": "custom.Model"]]); rejects { _ = try admit(folder) }
        try writeConfig(["model_type": "parakeet", "quantization": ["bits": 4]])
        try Data().write(to: folder.appendingPathComponent("custom.py")); rejects { _ = try admit(folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("custom.py"))
        var wav: [UInt8] = []
        func ascii(_ s: String) { wav += Array(s.utf8) }
        func u16(_ n: Int) { wav += [UInt8(n&255),UInt8((n>>8)&255)] }
        func u32(_ n: Int) { u16(n&65535); u16(n>>16) }
        ascii("RIFF");u32(40);ascii("WAVEfmt ");u32(16);u16(1);u16(1);u32(16000);u32(32000);u16(2);u16(16);ascii("data");u32(4);u16(32767);u16(32768)
        let audio = folder.appendingPathComponent("test.wav")
        try Data(wav).write(to: audio)
        let valid = try Audio(audio.path); precondition(valid.samples == [Float(32767)/32768,-1]); precondition(valid.seconds == 0.000125)
        wav[22] = 2; try Data(wav).write(to: audio); rejects { _ = try Audio(audio.path) }
        wav[22] = 1; wav.removeLast(); try Data(wav).write(to: audio); rejects { _ = try Audio(audio.path) }
        rejects { _ = try Audio("relative.wav") }
        print("Validation checks passed")
    }
}
