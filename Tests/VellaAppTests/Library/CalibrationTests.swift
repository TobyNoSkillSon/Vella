import XCTest
import VellaCore
@testable import Vella

final class CalibrationTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor func testObservationPersistenceIdentityExpiryAndInvalidValues() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        var key: String? = "device-model-quant-runtime-v1"
        var date = Date()
        let store = CalibrationStore(directory: dir, identity: { _ in key }, now: { date })
        XCTAssertNil(store.speed(modelPath: "/fake/a"))
        store.observe(modelPath: "/fake/a", audioSeconds: 10, processingSeconds: 2)
        XCTAssertEqual(store.speed(modelPath: "/fake/a"), 5)
        XCTAssertNil(store.speed(modelPath: "/fake/b"))
        for value in [0, -1, Double.nan, Double.infinity] {
            store.observe(modelPath: "/fake/a", audioSeconds: value, processingSeconds: 2)
            store.observe(modelPath: "/fake/a", audioSeconds: 10, processingSeconds: value)
        }
        XCTAssertEqual(store.speed(modelPath: "/fake/a"), 5)
        let reloaded = CalibrationStore(directory: dir, identity: { _ in key }, now: { date })
        XCTAssertEqual(reloaded.speed(modelPath: "/fake/a"), 5)
        key = "changed-quantization"
        XCTAssertNil(store.speed(modelPath: "/fake/a"))
        key = nil
        XCTAssertNil(store.speed(modelPath: "/fake/a"))
        key = "device-model-quant-runtime-v1"
        date = date.addingTimeInterval(31 * 86400)
        XCTAssertNil(store.speed(modelPath: "/fake/a"))
    }
    @MainActor func testObservationComputesIdentityOnlyOnce() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        var scans = 0
        let store = CalibrationStore(
            directory: dir,
            identity: { _ in
                scans += 1; return "identity"
            })
        store.observe(modelPath: "/fake", audioSeconds: 10, processingSeconds: 1)
        scans = 0
        store.observe(modelPath: "/fake", audioSeconds: 10, processingSeconds: 1)
        XCTAssertEqual(scans, 1)
    }
    @MainActor func testStatDetectsSameSizeReplacement() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("weights.safetensors")
        try Data("aaaa".utf8).write(to: file)
        let before = try CalibrationStore.stamp(file)
        try Data("bbbb".utf8).write(to: file, options: .atomic)
        XCTAssertNotEqual(before, try CalibrationStore.stamp(file))
    }
    @MainActor func testRealRuntimeIdentityWithoutLoadingWeights() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let config = model.appendingPathComponent("config.json")
        try Data("{\"model_type\":\"whisper\"}".utf8).write(to: config)
        try Data("fake".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        guard let runtimePath = ProcessInfo.processInfo.environment["VELLA_CALIBRATION_TEST_WORKER"] else {
            throw XCTSkip("Set VELLA_CALIBRATION_TEST_WORKER for the read-only runtime identity check")
        }
        let runtime = URL(fileURLWithPath: runtimePath)
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else { throw XCTSkip("Local runtime not installed") }
        let store = CalibrationStore(directory: dir.appendingPathComponent("results"), worker: { runtime })
        let start = Date()
        let original = try XCTUnwrap(store.identity(modelPath: model.path))
        print("Calibration runtime identity check (no inference): \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(original.components(separatedBy: ":").count, 4)
        try Data("{\"model_type\":\"whisper\",\"quantization\":{\"bits\":4}}".utf8).write(to: config)
        XCTAssertNotEqual(original, store.identity(modelPath: model.path))
        try FileManager.default.removeItem(at: model.appendingPathComponent("model.safetensors"))
        XCTAssertNil(store.identity(modelPath: model.path))
    }
    @MainActor func testRuntimeMutationInvalidatesObservation() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("model")
        let bin = dir.appendingPathComponent("bin")
        for folder in [model, bin] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("{\"model_type\":\"whisper\"}".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("fake".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        let worker = bin.appendingPathComponent("VellaWorker")
        try Data("#!/bin/sh\necho before\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let store = CalibrationStore(directory: dir.appendingPathComponent("results"), worker: { worker })
        store.observe(modelPath: model.path, audioSeconds: 10, processingSeconds: 2)
        XCTAssertEqual(store.speed(modelPath: model.path), 5)
        try Data("#!/bin/sh\necho after!\n".utf8).write(to: worker, options: .atomic)
        XCTAssertNil(store.speed(modelPath: model.path))
    }
    @MainActor private func fakeStore(_ dir: URL, script: String) throws -> CalibrationStore {
        let worker = dir.appendingPathComponent("VellaWorker")
        try ("#!/bin/sh\n" + script).write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        // Inject a synthetic native helper; no Python/MLX/model load occurs.
        return CalibrationStore(
            directory: dir.appendingPathComponent("results"), resources: dir,
            worker: { worker }, identity: { _ in "isolated-test" })
    }
    private var success: String {
        """
        echo '{"event":"progress","message":"warm pass"}'
        echo '{"event":"result","result":{"audioSeconds":8,"loadSeconds":9,"firstRequestSeconds":6,"warmSeconds":[2,4],"speed":2.6666666666666665,"sampleSHA256":"\(CalibrationStore.sampleHash)","mlxVersion":"test","mlxAudioVersion":"test","parameters":{"max_tokens":1024,"stream":false}}}'
        """
    }
    @MainActor func testWorkerSuccessPersistsOnlyAfterExit() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try fakeStore(dir, script: success)
        var completed = false, messages: [String] = []
        XCTAssertTrue(
            store.calibrate(
                modelPath: "/fake", status: { messages.append($0) },
                completion: { error in
                    XCTAssertNil(error); completed = true
                }))
        XCTAssertNil(store.speed(modelPath: "/fake"))
        for _ in 0..<100 where !completed { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(completed)
        XCTAssertEqual(store.speed(modelPath: "/fake") ?? 0, 8 / 3, accuracy: 0.00001)
        XCTAssertTrue(messages.contains("warm pass"))
        XCTAssertFalse(store.calibrate(modelPath: "/fake", status: { _ in }, completion: { _ in }))
    }
    @MainActor func testNonzeroExitDiscardsEvenValidResult() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try fakeStore(dir, script: success + "\nexit 7\n")
        var completed = false
        XCTAssertTrue(
            store.calibrate(
                modelPath: "/fake", status: { _ in },
                completion: { error in
                    XCTAssertNotNil(error); completed = true
                }))
        for _ in 0..<100 where !completed { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(completed); XCTAssertNil(store.speed(modelPath: "/fake"))
    }
    @MainActor func testMalformedSuccessfulResponseIsNotCalibration() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try fakeStore(dir, script: success.replacingOccurrences(of: "[2,4]", with: "[-2,4]"))
        var completed = false
        XCTAssertTrue(
            store.calibrate(
                modelPath: "/fake", status: { _ in },
                completion: { error in
                    XCTAssertNotNil(error); completed = true
                }))
        for _ in 0..<100 where !completed { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(completed); XCTAssertNil(store.speed(modelPath: "/fake"))
    }
    @MainActor func testChangedIdentityDuringWorkerDiscardsResult() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        try ("#!/bin/sh\n" + success).write(to: dir.appendingPathComponent("VellaWorker"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("VellaWorker").path)
        var identity = "before"
        let store = CalibrationStore(
            directory: dir.appendingPathComponent("results"), resources: dir,
            worker: { dir.appendingPathComponent("VellaWorker") }, identity: { _ in identity })
        var completed = false
        XCTAssertTrue(
            store.calibrate(
                modelPath: "/fake", status: { _ in },
                completion: { error in
                    XCTAssertNotNil(error); completed = true
                }))
        identity = "after"
        for _ in 0..<100 where !completed { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(completed); XCTAssertNil(store.speed(modelPath: "/fake"))
    }
    @MainActor func testDeadlineAndCancellationReapWorker() async throws {
        for cancel in [false, true] {
            let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
            let store = try fakeStore(dir, script: "trap '' TERM\nwhile :; do :; done\n")
            var completed = false
            XCTAssertTrue(
                store.calibrate(
                    modelPath: "/fake", timeout: cancel ? 10 : 0.05, status: { _ in },
                    completion: { error in
                        XCTAssertTrue(error?.contains(cancel ? "cancelled" : "timed out") == true); completed = true
                    }))
            if cancel { store.cancel() }
            for _ in 0..<150 where !completed { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(completed); XCTAssertFalse(store.isRunning); XCTAssertNil(store.speed(modelPath: "/fake"))
        }
    }
    @MainActor func testInstallRemainsRegisteredWhenCalibrationFails() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try fakeStore(dir, script: "exit 3\n")
        let library = ModelLibrary(registryURL: dir.appendingPathComponent("registry.json"), calibration: store)
        let active = library.activeModelPath, id = "Qwen3-ASR-1.7B-bf16"
        let path = library.modelsDirectory.appendingPathComponent(id).path
        library.installed[id] = InstalledModel(path: path, revision: library.models.first(where: { $0.id == id })!.revision)
        try library.saveRegistry(updating: id)
        var completed = false, failure: String?
        XCTAssertTrue(
            store.calibrate(
                modelPath: path, status: { _ in },
                completion: { error in
                    failure = error; completed = true
                }))
        for _ in 0..<100 where !completed { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(library.installed[id]); XCTAssertFalse(store.isRunning)
        XCTAssertEqual(library.activeModelPath, active)
        XCTAssertNotNil(failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.registryURL.path))
    }
}
