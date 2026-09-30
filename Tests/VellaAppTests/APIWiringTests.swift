import XCTest
import AppKit
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// The API through the app's own launch wiring (AppDelegate + its Models table + RuntimeBridge + `startAPI`), with the
/// bundled catalog, an isolated support dir holding a registry and config like the shipped 1.0.0 user's, and the fake
/// stdio worker. Regression for b33: `APIService` held its model source weakly, so `GET /v1/models` listed nothing and
/// no model name (not even `whisper-1`) resolved, although a model was downloaded and loaded.
final class APIWiringTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-api-wiring-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "condition not reached within \(timeout) s")
    }

    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// Support dir shaped like the 1.0.0 user's (26 Sep 2026): Parakeet v3 Ultra BF16 in the launch set and selected,
    /// Parakeet v3 4-bit downloaded, Qwen3 ASR 1.7B BF16 registered from an outside folder, an imported Whisper, and
    /// three streaming models. Returns the Ultra and Parakeet v3 4-bit paths.
    private func tobyLikeSupport() throws -> (ultra: String, v3: String) {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let models = support.appendingPathComponent("Models", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        func folder(_ base: URL, _ name: String, config: String = "{}") throws -> String {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: url.appendingPathComponent("config.json"))
            return url.path
        }
        let ultra = try folder(models, "parakeet-ultra-mlx-bf16"), v3 = try folder(models, "parakeet-tdt-0.6b-v3-mlx-4bit")
        let nemo8 = try folder(models, "nemotron-3.5-asr-streaming-0.6b-8bit")
        let registry: [String: InstalledModel] = [
            "Qwen3-ASR-1.7B-bf16": InstalledModel(path: try folder(outside, "qwen3-asr-1.7b-bf16"), name: "Qwen3 ASR · 1.7B", quantization: "BF16"),
            "Voxtral-Mini-4B-Realtime-2602-4bit": InstalledModel(path: try folder(models, "Voxtral-Mini-4B-Realtime-2602-4bit"), revision: "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e", name: "Voxtral Mini Realtime · 4B", quantization: "4-bit"),
            "imported-whisper-large-v3-q8": InstalledModel(path: try folder(outside, "whisper-large-v3-q8", config: #"{"model_type": "whisper", "quantization": {"group_size": 64, "bits": 8}}"#),
                                                           name: "Whisper large-v3", quantization: "8-bit"),
            "nemotron-3.5-asr-streaming-0.6b-8bit": InstalledModel(path: nemo8, revision: "7279359e4481b5e9e185a318bd618e429c6d86cd", name: "Nemotron 3.5 ASR · 0.6B", quantization: "8-bit"),
            "nemotron-3.5-asr-streaming-0.6b-bf16": InstalledModel(path: try folder(models, "nemotron-3.5-asr-streaming-0.6b-bf16"), revision: "e550040c0478027ed679b2b6b0d055502c103663", name: "Nemotron 3.5 ASR · 0.6B", quantization: "BF16"),
            "parakeet-tdt-0.6b-v3-mlx-4bit": InstalledModel(path: v3, revision: "65247a0a9e735426eba06056a9535f7e67dcbbb9", name: "Parakeet v3", quantization: "4-bit"),
            "parakeet-ultra-mlx-bf16": InstalledModel(path: ultra, revision: "b554592c50b2a48471add2daa3d46fa9f00fef5e", name: "Parakeet v3 Ultra", quantization: "BF16"),
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: support.appendingPathComponent("models-installed.json"))
        let config: [String: Any] = [
            "preferredMicrophone": "Shure MV7i", "fallbackMicrophone": "MacBook Pro Microphone", "lastLoaded": [String: String](),
            "executable": "/nonexistent/python", "mode": "dictation", "model": ultra, "streamingModel": nemo8,
            "residency": ["manualIdleMinutes": 0, "onDemandIdleMinutes": 15, "allowSwap": false,
                          "launchSet": [["precision": "BF16", "diskBytes": 1254840214, "path": ultra, "id": "parakeet-v3-ultra", "mode": "dictation",
                                         "memoryMB": 1747, "precisionOptions": ["BF16", "8b", "4b"], "name": "Parakeet v3 Ultra"]]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: support.appendingPathComponent("config.json"))
        return (ultra, v3)
    }

    @MainActor func testLaunchWiringListsDownloadedModelsAndResolvesWhisper1() async throws {
        _ = NSApplication.shared
        let (ultra, v3) = try tobyLikeSupport()
        let runtime = try Runtime.isolated(root)
        XCTAssertEqual(runtime.settings.launchSet.map(\.id), ["parakeet-v3-ultra"])
        let resources = repo.appendingPathComponent("Resources", isDirectory: true)
        let registry = runtime.support.appendingPathComponent("models-installed.json")
        let controller = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                          streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: resources.appendingPathComponent("benchmarks.json"))
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 10, runtime: runtime)
        let stream = StreamingBackend(helper: try FakeStreamingWorker.install(in: root), timeout: 5, runtime: runtime)
        let model = Model(configurationURL: runtime.configURL, streamingBackend: stream, backend: backend)
        XCTAssertTrue(runtime.dictation === backend)
        let delegate = AppDelegate(model: model)
        delegate.modelsMenu = delegate.makeModelsMenu(controller: controller)
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(delegate)
        // Launch migration (29 Sep 2026): the removed Voxtral leaves the registry; the imported Whisper q8 (affine-8 g64)
        // is Whisper large-v3's 8 tier.
        bridge.migrateRegistry()
        let registered = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: runtime.support.appendingPathComponent("models-installed.json")))
        XCTAssertNil(registered["Voxtral-Mini-4B-Realtime-2602-4bit"])
        XCTAssertNil(registered["imported-whisper-large-v3-q8"])
        XCTAssertEqual(registered["whisper-large-v3-8bit"]?.path, root.appendingPathComponent("outside/whisper-large-v3-q8").path)
        XCTAssertNotNil(registered["parakeet-tdt-0.6b-v3-mlx-4bit"], "an absent tier's files stay registered (not shown)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.support.appendingPathComponent("Models/Voxtral-Mini-4B-Realtime-2602-4bit").path),
                      "the registry migration never deletes files")
        runtime.start()
        let host = APIHost()
        defer { host.stop(); model.shutdown(); backend.shutdown(); stream.shutdown() }
        try await waitUntil { runtime.status.models["parakeet-v3-ultra"] != nil }
        delegate.startAPI(host)   // App.swift's launch call, on its own host
        try await waitUntil { runtime.apiPort != nil }
        let base = "http://127.0.0.1:\(try XCTUnwrap(runtime.apiPort))"
        func get(_ path: String) async throws -> (Int, [String: Any]) {
            let (data, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
            return ((response as! HTTPURLResponse).statusCode, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }

        // GET /v1/models: every dictation family with weights of an offered tier here; the loaded one loaded and current.
        // Parakeet v3's only files are 4-bit, an absent tier: not listed (and never replaced by another tier).
        let (code, list) = try await get("/v1/models")
        XCTAssertEqual(code, 200)
        let data = try XCTUnwrap(list["data"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: data.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(Set(byID.keys), ["parakeet-v3-ultra", "whisper-large-v3", "qwen3-asr-1.7b"], "\(data)")
        XCTAssertEqual(byID["parakeet-v3-ultra"]?["precision"] as? String, "BF16")
        XCTAssertEqual(byID["parakeet-v3-ultra"]?["loaded"] as? Bool, true)
        XCTAssertEqual(byID["parakeet-v3-ultra"]?["current"] as? Bool, true)
        // A launch-set model from before selections existed ran Optimized Fast; the fake worker reports stock MLX, so
        // what runs is Standard and the request is reported beside it.
        XCTAssertEqual((byID["parakeet-v3-ultra"]?["selection"] as? [String: Any])?["recipe"] as? String, "standard")
        XCTAssertEqual((byID["parakeet-v3-ultra"]?["requested_selection"] as? [String: Any])?["recipe"] as? String, "optimized_fast")
        XCTAssertEqual(byID["whisper-large-v3"]?["precision"] as? String, "8b")
        XCTAssertEqual(byID["whisper-large-v3"]?["loaded"] as? Bool, false)
        XCTAssertEqual((byID["whisper-large-v3"]?["selection"] as? [String: Any])?["tier"] as? String, "8")
        XCTAssertEqual((byID["whisper-large-v3"]?["selection"] as? [String: Any])?["recipe"] as? String, "optimized_fast", "never loaded: Optimized · Fast")
        XCTAssertEqual(byID["qwen3-asr-1.7b"]?["precision"] as? String, "BF16")
        // Streaming families are never listed; the status names the current dictation model.
        let (_, status) = try await get("/status")
        XCTAssertEqual((status["dictation_model"] as? [String: Any])?["id"] as? String, "parakeet-v3-ultra")

        // Model names: whisper-1 and the other aliases are the current model; family ids resolve case-insensitively.
        let service = try XCTUnwrap(host.service)
        for alias in ["whisper-1", "", "vella", "default", "current"] {
            XCTAssertEqual(try service.resolve(alias)?.path, ultra, alias)
        }
        XCTAssertThrowsError(try service.resolve("Parakeet-V3")) { XCTAssertTrue("\($0)".contains("not downloaded"), "\($0)") }
        _ = v3
        let whisper = root.appendingPathComponent("outside/whisper-large-v3-q8").path
        XCTAssertEqual(try service.resolve("Whisper-Large-V3")?.path, whisper)
        XCTAssertThrowsError(try service.resolve("nemotron-3.5-streaming-0.6b")) { XCTAssertTrue("\($0)".contains("Streaming model"), "\($0)") }
        let (one, retrieved) = try await get("/v1/models/whisper-large-v3")
        XCTAssertEqual(one, 200); XCTAssertEqual(retrieved["precision"] as? String, "8b")

        // POST /v1/audio/transcriptions: whisper-1 runs on the loaded Ultra; a named family loads on demand.
        let speech = resources.appendingPathComponent("Calibration/speech.wav")
        func transcribe(_ name: String) async throws -> (Int, String) {
            let boundary = "vella-\(UUID().uuidString)"
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(name)\r\n".utf8)
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n".utf8)
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body += try Data(contentsOf: speech) + Data("\r\n--\(boundary)--\r\n".utf8)
            var request = URLRequest(url: URL(string: base + "/v1/audio/transcriptions")!)
            request.httpMethod = "POST"; request.timeoutInterval = 30; request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        let (first, text) = try await transcribe("whisper-1")
        XCTAssertEqual(first, 200, text)
        XCTAssertTrue(text.contains("Fixture recognized speech."), text)
        XCTAssertEqual(Set(runtime.status.models.keys), ["parakeet-v3-ultra"], "whisper-1 used the loaded model")
        let (second, other) = try await transcribe("whisper-large-v3")
        XCTAssertEqual(second, 200, other)
        XCTAssertEqual(runtime.loadedRef("whisper-large-v3")?.path, whisper)
        XCTAssertEqual(runtime.loadedRef("whisper-large-v3")?.precision, "8b")
        XCTAssertEqual(runtime.loadedRef("whisper-large-v3")?.selection, ModelSelection(tier: .t8, path: .optimized, mode: .fast))
        XCTAssertEqual(runtime.status.models["whisper-large-v3"]?.selection?.segmentKey, .optimized_fast)
        let (missing, reason) = try await transcribe("qwen3-asr-0.6b")
        XCTAssertEqual(missing, 404, reason)
        XCTAssertTrue(reason.contains("not downloaded"), reason)
    }
}
