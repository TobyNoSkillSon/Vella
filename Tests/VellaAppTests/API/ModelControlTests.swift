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

final class ModelControlTests: XCTestCase {
    @MainActor func fixture() throws -> TwoFamilyFixture {
        try Integration.require()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-controls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try TwoFamilyFixture(root)
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
        let (refused, _, prompt) = try await APIClientTests.run(APIClientTests.cli, ["get", "alpha"], environment: environment)
        XCTAssertEqual(refused, 1)
        XCTAssertTrue(prompt.contains("bytes") && prompt.contains("org/a4"))
        let (loaded, effective, _) = try await APIClientTests.run(APIClientTests.cli, ["get", "alpha", "--yes"], environment: environment)
        XCTAssertEqual(loaded, 0)
        XCTAssertTrue(effective.contains("Standard") && effective.contains("loaded"))
        let (deleteRefused, _, deletedPrompt) = try await APIClientTests.run(APIClientTests.cli,
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
