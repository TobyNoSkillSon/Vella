import Combine
import CryptoKit
import Foundation
import XCTest
@testable import Vella
import VellaCore
import VellaTestSupport

/// A pinned, data-only Hub fixture. No request in this test can leave the process.
private final class ControlHub: URLProtocol {
    static var files: [String: Data] {
        ["config.json": Data(#"{"model_type":"parakeet"}"#.utf8), "model.safetensors": Data([1, 2, 3])]
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            if request.url!.path.contains("/api/models/") {
                let siblings: [[String: Any]] = Self.files.map { name, bytes in
                    ["rfilename": name, "size": bytes.count, "lfs": ["sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]]
                }
                data = try JSONSerialization.data(withJSONObject: ["sha": String(repeating: "a", count: 40), "siblings": siblings])
            } else {
                guard let bytes = Self.files[request.url!.lastPathComponent] else { throw NSError(domain: "unexpected fixture request", code: 1) }
                data = bytes
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Intentionally never completes a request; the library must cancel without a network callback.
private final class StalledControlHub: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// A transfer lasting several inactivity windows, with real bytes every quarter second. No external network.
private final class SlowControlHub: URLProtocol, @unchecked Sendable {
    static var files: [String: Data] {
        ["config.json": Data(#"{"model_type":"parakeet"}"#.utf8), "model.safetensors": Data(repeating: 1, count: 256 * 1024)]
    }
    private let lock = NSLock()
    private var stopped = false
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            if request.url!.path.contains("/api/models/") {
                let siblings: [[String: Any]] = Self.files.map { name, bytes in
                    ["rfilename": name, "size": bytes.count, "lfs": ["sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]]
                }
                data = try JSONSerialization.data(withJSONObject: ["sha": String(repeating: "a", count: 40), "siblings": siblings])
            } else {
                data = Self.files[request.url!.lastPathComponent]!
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard request.url!.lastPathComponent == "model.safetensors" else {
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self); return
            }
            let chunks = 12
            for index in 0..<chunks {
                let lower = data.count * index / chunks, upper = data.count * (index + 1) / chunks
                let bytes = data.subdata(in: lower..<upper)
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(index + 1) * 0.25) { [self] in
                    guard !lock.withLock({ stopped }) else { return }
                    client?.urlProtocol(self, didLoad: bytes)
                    if index == chunks - 1 { client?.urlProtocolDidFinishLoading(self) }
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

final class ModelControlTests: XCTestCase {
    @MainActor func fixture() throws -> TwoFamilyFixture {
        try Integration.require()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-controls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try TwoFamilyFixture(root)
    }
    @MainActor func testPinnedModelRefusesUnloadReloadAndTableActionWithoutRetiringWorker() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        try await f.load(f.alpha, "BF16")
        let pid = f.runtime.status.models["alpha"]?.pid
        let launchSet = f.runtime.settings.launchSet
        f.runtime.pin("alpha")
        defer { f.runtime.unpin("alpha") }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        for action in ["unload", "reload"] {
            do {
                _ = try await controls.perform(action, id: "alpha", fields: [:])
                XCTFail("Pinned model accepted " + action)
            } catch let error as APIError {
                XCTAssertEqual(error.status, 409)
                XCTAssertTrue(error.message.contains("transcription"))
            }
        }
        f.controller.perform(f.alpha)
        XCTAssertNotNil(f.controller.lastError)
        let unloaded = await f.runtime.unload("alpha")
        XCTAssertFalse(unloaded, "Runtime must enforce the same pin even without a controller")
        XCTAssertEqual(f.runtime.status.models["alpha"]?.pid, pid)
        XCTAssertEqual(f.runtime.loadedResidency("alpha"), .manual)
        XCTAssertEqual(f.runtime.settings.launchSet, launchSet)
        XCTAssertEqual(f.runtime.selectionsInFlight, 0)
    }

    @MainActor func testAwaitedUnloadKeepsAPISelectionTransactionUntilWorkerExit() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let ref = f.bridge.ref(f.alpha, "BF16", path: try f.path(f.alpha, "BF16"))
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        f.runtime.register(ref, residency: .manual) {
            entered = true
            await withCheckedContinuation { release = $0 }
            f.runtime.removed("alpha")
        }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let job = Task { try await controls.perform("unload", id: "alpha", fields: [:]) }
        let until = Date().addingTimeInterval(5)
        while !entered, Date() < until { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(entered)
        XCTAssertEqual(f.runtime.selectionsInFlight, 1, "API admission waits for the worker to finish exiting")
        XCTAssertTrue(f.controller.inUse(f.zeta))
        release?.resume()
        _ = try await job.value
        XCTAssertEqual(f.runtime.selectionsInFlight, 0)
        XCTAssertFalse(f.runtime.isLoaded("alpha"))
    }

    @MainActor func testActiveAPITranscriptionRefusesAuthenticatedUnloadAndReload() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let helper = f.root.appendingPathComponent("fake-worker.py")
        let delayed = FakeWorker.script.replacingOccurrences(of: "name=r['model'].split('/')[-1]; marker=", with: "time.sleep(0.5); name=r['model'].split('/')[-1]; marker=")
        try delayed.write(to: helper, atomically: true, encoding: .utf8)
        try await f.load(f.alpha, "BF16")
        let pid = try XCTUnwrap(f.runtime.status.models["alpha"]?.pid)
        let launchSet = f.runtime.settings.launchSet
        f.runtime.apiToken = "test-token"
        let transcriber = APITranscriber(backend: f.backend, root: f.root.appendingPathComponent("jobs"))
        let service = APIService(transcriber: transcriber, models: f.source, scratch: f.root.appendingPathComponent("files"))
        service.controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let audio = f.root.appendingPathComponent("test.wav")
        try writeTestWAV(audio, bursts: [0.1], gap: 0.01)
        let job = Task {
            try await transcriber.transcribe(audio, resolve: { try XCTUnwrap(f.source.models().first { $0.id == "alpha" }) }, current: { "alpha" })
        }
        defer { job.cancel() }
        let until = Date().addingTimeInterval(5)
        while !f.runtime.isModelInUse("alpha"), Date() < until { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(f.runtime.isModelInUse("alpha"))
        for action in ["unload", "reload"] {
            let head = HTTPHead.parse(
                Data(("POST /v1/models/alpha/" + action + " HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nX-Vella-Token: test-token\r\nContent-Type: application/json").utf8))!
            let response = await service.handle(APIRequest(head: head, body: .memory(Data("{}".utf8))))
            XCTAssertEqual(response.status, 409)
            XCTAssertEqual(f.runtime.status.models["alpha"]?.pid, pid)
            XCTAssertEqual(f.runtime.settings.launchSet, launchSet)
            XCTAssertEqual(f.runtime.loadedResidency("alpha"), .manual)
        }
        let result = try await job.value
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(f.runtime.status.models["alpha"]?.pid, pid, "No retirement or retry")
    }

    @MainActor func testAlreadyDownloadedGetLoadsWithoutConsentOrDownload() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        _ = try await controls.perform("get", id: "alpha", fields: ["yes": false])
        XCTAssertTrue(f.runtime.isLoaded("alpha"))
        XCTAssertNil(f.controller.dictation.downloadingID)
    }

    @MainActor func testStalledGetTimesOutOrCancelsAndReleasesPublishedControlGate() async throws {
        for cancel in [false, true] {
            let f = try fixture()
            defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
            let lib = f.controller.dictation
            lib.installed.removeValue(forKey: "alpha-bf16")
            lib.installed.removeValue(forKey: "alpha-4bit")
            try FileManager.default.removeItem(at: lib.modelsDirectory.appendingPathComponent("alpha-bf16"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StalledControlHub.self]
            lib.downloadConfiguration = configuration
            lib.downloadTimeoutSeconds = cancel ? 60 : 0.1
            let controls = ModelControls(controller: f.controller, runtime: f.runtime)
            var gates: [Set<String>] = []
            let subscription = f.controller.$controlOperations.sink { gates.append($0) }
            defer { subscription.cancel() }
            let job = Task { try await controls.perform("get", id: "alpha", fields: ["yes": true]) }
            let until = Date().addingTimeInterval(5)
            while !lib.busy, Date() < until { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(lib.busy)
            if cancel { job.cancel() }
            do { _ = try await job.value; XCTFail("Stalled Get must fail") } catch {
                if !cancel {
                    XCTAssertTrue(lib.downloadError?.contains("stalled (no new bytes for 0.1 seconds)") == true, lib.downloadError ?? "")
                }
            }
            XCTAssertFalse(lib.busy)
            XCTAssertTrue(f.controller.controlOperations.isEmpty)
            XCTAssertNil(f.controller.pendingLoads["alpha"])
            XCTAssertNil(f.controller.pendingSelections["alpha"])
            XCTAssertTrue(gates.contains(["alpha"]))
            XCTAssertEqual(gates.last, [])
            _ = try await controls.perform("load", id: "zeta", fields: [:])
            XCTAssertTrue(f.runtime.isLoaded("zeta"), "Other controls still work")
        }
    }

    @MainActor func testSlowProgressingGetCompletesThroughCLIAndReportsByteProgress() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let lib = f.controller.dictation
        lib.installed.removeValue(forKey: "alpha-bf16")
        lib.installed.removeValue(forKey: "alpha-4bit")
        try FileManager.default.removeItem(at: lib.modelsDirectory.appendingPathComponent("alpha-bf16"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowControlHub.self]
        lib.downloadConfiguration = configuration; lib.downloadTimeoutSeconds = 0.6
        f.runtime.apiToken = "test-token"
        let transcriber = APITranscriber(backend: f.backend, root: f.root.appendingPathComponent("jobs"))
        let service = APIService(transcriber: transcriber, models: f.source, scratch: f.root.appendingPathComponent("files"))
        service.controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let server = try APIServer(uploads: f.root.appendingPathComponent("uploads"), handler: service)
        defer { server.stop() }
        let port = await withCheckedContinuation { c in server.start { c.resume(returning: $0) } }
        f.runtime.apiPort = try XCTUnwrap(port); f.runtime.writeStatus()
        let environment = ["VELLA_SUPPORT_DIR": f.runtime.support.path, "VELLA_NO_LAUNCH": "1", "PATH": "/usr/bin:/bin"]
        let start = Date()
        let (code, line, progress) = try await APIClientTests.run(APIClientTests.cli, ["get", "alpha", "--yes"], environment: environment)
        XCTAssertEqual(code, 0, progress)
        XCTAssertTrue(line.contains("loaded"), line)
        XCTAssertTrue(progress.contains("Downloading from Hugging Face") && progress.contains(" of "), progress)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 2 * lib.downloadTimeoutSeconds)
        XCTAssertTrue(f.runtime.isLoaded("alpha"))
        XCTAssertNil(lib.downloadError)
        XCTAssertTrue(f.controller.controlOperations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: lib.modelsDirectory.appendingPathComponent("alpha-bf16/model.safetensors")), SlowControlHub.files["model.safetensors"])
    }

    @MainActor func testTokenComparisonRejectsMissingChangedAndDifferentLengthSecrets() {
        XCTAssertTrue(APIService.tokensEqual("test-token", "test-token"))
        for candidate in [nil, "", "Test-token", "test-tokeN", "test-token-extra", "téšt-token"] {
            XCTAssertFalse(APIService.tokensEqual(candidate, "test-token"))
        }
    }

    @MainActor func testSelectLoadReloadUnloadUseTheTableRuntimeAndSettings() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        _ = try await controls.perform("select", id: "alpha", fields: ["precision": "int4", "path": "Standard", "mode": "Fast"])
        XCTAssertEqual(f.controller.currentSelection(f.alpha).tier, .t4)
        XCTAssertFalse(f.runtime.isLoaded("alpha"), "Select is a preview, not an implicit load")
        _ = try await controls.perform("load", id: "alpha", fields: [:])
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.selection?.path, .standard)
        XCTAssertEqual(try f.config().model, try f.path(f.alpha, "4b"))
        _ = try await controls.perform("select", id: "alpha", fields: ["precision": "bf16"])
        _ = try await controls.perform("reload", id: "alpha", fields: [:])
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.precision, "BF16")
        _ = try controls.setting("keep-hot", fields: ["class": "Manually loaded", "value": "5 min idle"])
        _ = try controls.setting("memory", fields: ["value": "Allow swap (slower)"])
        XCTAssertEqual(f.runtime.settings.manualIdleMinutes, 5)
        XCTAssertTrue(f.runtime.settings.allowSwap)
        _ = try await controls.perform("unload", id: "alpha", fields: [:])
        XCTAssertFalse(f.runtime.isLoaded("alpha"))
        XCTAssertTrue(f.controller.available(f.alpha, "BF16"))
    }
    @MainActor func testGetWithoutConsentNamesSourceAndSizeAndDownloadsNothing() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        f.controller.dictation.installed.removeValue(forKey: "alpha-bf16")
        f.controller.dictation.installed.removeValue(forKey: "alpha-4bit")
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        do {
            _ = try await controls.perform("get", id: "alpha", fields: ["yes": false])
            XCTFail("Get without yes must refuse")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "download_consent_required")
            XCTAssertTrue(error.message.contains("org/a"))
            XCTAssertTrue(error.message.contains("1,000 bytes"))
        }
        XCTAssertNil(f.controller.dictation.downloadingID)
        XCTAssertFalse(f.runtime.isLoaded("alpha"))
        XCTAssertEqual(controls.catalog().count, 2, "Catalog includes not-downloaded models")
    }
    @MainActor func testConfirmedGetUsesPinnedDownloadThenTheSameLoadAction() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        // Remove only this disposable fixture's registry record; the app has no installed copy to overwrite.
        f.controller.dictation.installed.removeValue(forKey: "alpha-bf16")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: try f.path(f.alpha, "4b")).deletingLastPathComponent().appendingPathComponent("alpha-bf16"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlHub.self]
        f.controller.dictation.downloadConfiguration = configuration
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        _ = try await controls.perform("select", id: "alpha", fields: ["precision": "bf16", "path": "Standard"])
        _ = try await controls.perform("get", id: "alpha", fields: ["yes": true])
        XCTAssertTrue(f.controller.available(f.alpha, "BF16"))
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.selection?.path, .standard)
        XCTAssertNil(f.controller.pendingLoads["alpha"])
    }

    @MainActor func testSelectionRefusalsMatchTheTableAndLeaveThePreviewUnchanged() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let pending = BenchmarkCell(recipe: CellRecipe(layers: ["all": "bf16"]))
        f.controller.benchmarks.models["alpha"] = FamilyBenchmark(tiers: [
            .t16: TierBenchmark(precision: "BF16", cells: [.standard: pending, .optimized_fast: pending]),
            .t4: TierBenchmark(precision: "4b", presence: TierPresence(offered: false, reasons: ["1 clip empty"]), cells: [:])
        ])
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        for (precision, expected) in [("int4", "Not offered: 1 clip empty"), ("bf16", "Not measured yet")] {
            do {
                _ = try await controls.perform("select", id: "alpha", fields: ["precision": precision, "path": "Standard"])
                XCTFail("unavailable cell should refuse")
            } catch let error as APIError { XCTAssertEqual(error.message, expected) }
            XCTAssertFalse(f.controller.isPreviewing(f.alpha))
        }
        f.controller.benchmarks.models.removeValue(forKey: "alpha")
        f.controller.previewInUse = true
        do {
            _ = try await controls.perform("select", id: "alpha", fields: ["precision": "bf16", "path": "Standard"])
            XCTFail("busy model should refuse")
        } catch let error as APIError { XCTAssertEqual(error.status, 409) }
        XCTAssertFalse(f.controller.isPreviewing(f.alpha))
    }

    @MainActor func testModeOnlyUsesTheTableExactCouplingAndCatalogIncludesStreaming() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        let exact = BenchmarkCell(recipe: CellRecipe(layers: ["all": "bf16"]), measured: CellMeasured(hardware: "fixture"))
        let fast = BenchmarkCell(recipe: CellRecipe(layers: ["all": "affine-4"], inexact: ["fixture-kernel"]), measured: CellMeasured(hardware: "fixture"))
        f.controller.benchmarks.models["alpha"] = FamilyBenchmark(tiers: [
            .t16: TierBenchmark(precision: "BF16", cells: [.standard: exact, .optimized_fast: exact, .optimized_exact: exact]),
            .t4: TierBenchmark(precision: "4b", cells: [.standard: fast, .optimized_fast: fast])
        ])
        let controls = ModelControls(controller: f.controller, runtime: f.runtime)
        _ = try await controls.perform("select", id: "alpha", fields: ["precision": "int4", "path": "Optimized", "mode": "Fast"])
        _ = try await controls.perform("select", id: "alpha", fields: ["mode": "Exact"])
        XCTAssertEqual(f.controller.currentSelection(f.alpha).tier, .t16)
        XCTAssertEqual(f.controller.currentSelection(f.alpha).mode, .exact)
        XCTAssertEqual(f.controller.couplingNote(f.alpha), "Exact: bf16 only, was int4")
        var streaming = f.alpha
        streaming.id = "stream-fixture"; streaming.name = "Streaming fixture"; streaming.mode = .streaming
        f.controller.catalog.families.append(streaming)
        XCTAssertTrue(controls.catalog().contains { $0["id"] as? String == "stream-fixture" })
        XCTAssertTrue(f.source.unavailableReason("stream-fixture")?.contains("Streaming") == true)
    }

    @MainActor func testMutationNeedsTheLocalTokenBeforeTouchingTheController() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        f.runtime.apiToken = "test-token"
        let transcriber = APITranscriber(backend: f.backend, root: f.root.appendingPathComponent("jobs"))
        let service = APIService(transcriber: transcriber, models: f.source, scratch: f.root.appendingPathComponent("files"))
        service.controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let head = HTTPHead.parse(Data("POST /v1/models/alpha/unload HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Type: application/json".utf8))!
        let result = await service.handle(APIRequest(head: head, body: .memory(Data("{}".utf8))))
        XCTAssertEqual(result.status, 403)
    }
    @MainActor func testCLIControlsRoundTripAgainstTheRealHTTPService() async throws {
        let f = try fixture()
        defer { f.close(); try? FileManager.default.removeItem(at: f.root) }
        f.runtime.apiToken = "test-token"
        let transcriber = APITranscriber(backend: f.backend, root: f.root.appendingPathComponent("jobs"))
        let service = APIService(transcriber: transcriber, models: f.source, scratch: f.root.appendingPathComponent("files"))
        service.controls = ModelControls(controller: f.controller, runtime: f.runtime)
        let server = try APIServer(uploads: f.root.appendingPathComponent("uploads"), handler: service)
        defer { server.stop() }
        var port: Int?
        server.start { port = $0 }
        let deadline = Date().addingTimeInterval(5)
        while port == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        f.runtime.apiPort = try XCTUnwrap(port)
        f.runtime.writeStatus()
        let environment = ["VELLA_SUPPORT_DIR": f.runtime.support.path, "VELLA_NO_LAUNCH": "1", "PATH": "/usr/bin:/bin"]
        let (listed, list, _) = try await APIClientTests.run(APIClientTests.cli, ["models", "--json"], environment: environment)
        XCTAssertEqual(listed, 0)
        XCTAssertTrue(list.contains("cells") && list.contains("org/a"))
        let (picked, preview, _) = try await APIClientTests.run(
            APIClientTests.cli,
            ["select", "alpha", "--precision", "int4", "--path", "Standard", "--mode", "Fast"], environment: environment)
        XCTAssertEqual(picked, 0)
        XCTAssertTrue(preview.contains("preview int4 Standard"))
        let (ready, readyLine, _) = try await APIClientTests.run(APIClientTests.cli, ["get", "alpha"], environment: environment)
        XCTAssertEqual(ready, 0)
        XCTAssertTrue(readyLine.contains("loaded"))
        let (loaded, effective, _) = try await APIClientTests.run(APIClientTests.cli, ["get", "alpha", "--yes"], environment: environment)
        XCTAssertEqual(loaded, 0)
        XCTAssertTrue(effective.contains("Standard") && effective.contains("loaded"))
        let (deleteRefused, _, deletedPrompt) = try await APIClientTests.run(
            APIClientTests.cli,
            ["delete", "zeta", "--precision", "bf16"], environment: environment)
        XCTAssertEqual(deleteRefused, 1)
        XCTAssertTrue(deletedPrompt.contains("Size:") && deletedPrompt.contains("Trash"))
        XCTAssertTrue(f.controller.available(f.zeta, "BF16"))
        let audio = f.root.appendingPathComponent("test.wav")
        try writeTestWAV(audio, bursts: [0.1], gap: 0.01)
        let (transcribed, text, _) = try await APIClientTests.run(
            APIClientTests.cli,
            ["transcribe", audio.path, "--model", "alpha"], environment: environment)
        XCTAssertEqual(transcribed, 0)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("Keep Hot") || text.contains("Vella 2.0.0"), "transcript stdout stays clean")
    }

}
