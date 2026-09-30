import XCTest
@testable import Vella
import VellaCore

/// Opt-in: a real VellaWorker (`VELLA_QA_WORKER`) on damaged copies of a model folder (`VELLA_QA_MODEL`, cloned, never
/// changed). Run under lab/bin/gpulock. Each case must fail with a message and leave the saved recording intact.
final class CorruptModelQATests: XCTestCase {
    @MainActor func testCorruptModelFilesFailClearlyAndKeepTheRecording() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let worker = env["VELLA_QA_WORKER"], let source = env["VELLA_QA_MODEL"], let outPath = env["VELLA_QA_OUT"] else {
            throw XCTSkip("Opt-in corrupt-model QA (real worker)")
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let audio = ModelLibrary.resourceDirectory().appendingPathComponent("Calibration/speech.wav")
        func damaged(_ name: String, _ damage: (URL) throws -> Void) throws -> URL {
            let folder = out.appendingPathComponent(name)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: folder) // APFS clone
            try damage(folder)
            return folder
        }
        let weights = { (folder: URL) -> URL in
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "safetensors" }!
        }
        let cases: [(String, (URL) throws -> Void)] = [
            (
                "truncated-weights",
                { folder in
                    let file = try weights(folder); let handle = try FileHandle(forWritingTo: file)
                    try handle.truncate(atOffset: (try handle.seekToEnd()) / 2); try handle.close()
                }
            ),
            (
                "garbage-weights-header",
                { folder in
                    let file = try weights(folder); let handle = try FileHandle(forWritingTo: file)
                    try handle.seek(toOffset: 0); try handle.write(contentsOf: Data(repeating: 0xFF, count: 64)); try handle.close()
                }
            ),
            ("garbage-config", { folder in try Data("{not json".utf8).write(to: folder.appendingPathComponent("config.json")) }),
            ("missing-weights", { folder in try FileManager.default.removeItem(at: try weights(folder)) })
        ]
        var results: [String: String] = [:]
        for (name, damage) in cases {
            let folder = try damaged(name, damage)
            let backend = Backend(helper: URL(fileURLWithPath: worker), requestTimeout: 60, runtime: try Runtime.isolated(out.appendingPathComponent("runtime-\(name)")))
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let text = try await backend.transcribe(audio, config: Configuration(model: folder.path))
                results[name] = "UNEXPECTED SUCCESS: \(text.prefix(60))"
            } catch {
                results[name] = "\(type(of: error)): \(error.localizedDescription) (\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - started)) s)"
            }
            results[name + ".runtimeError"] = backend.runtime.status.error ?? "nil"
            backend.shutdown()
            XCTAssertFalse(results[name]!.hasPrefix("UNEXPECTED"), name)
        }
        let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: out.appendingPathComponent("corrupt-model-report.json"))
        print("QA corrupt model: \(String(decoding: json, as: UTF8.self))")
    }
}
