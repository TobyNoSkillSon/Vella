import XCTest
@testable import Vella
@testable import VellaCore

/// An API request uses the model that is committed when its turn comes, never the one it saw on arrival: it cannot
/// load a precision over the user's later Reload, it keeps the current dictation model (not an earlier one) out of
/// eviction, and the current model is always reported at the precision the next dictation uses.
final class APISelectionConsistencyTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-api-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(5)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
    /// The app's API service over the fixture's controller and runtime; `hold` keeps requests waiting as a dictation does.
    @MainActor private func service(_ f: TwoFamilyFixture, hold: @escaping () -> Bool) -> APIService {
        let transcriber = APITranscriber(backend: f.backend, root: root.appendingPathComponent("api-jobs"))
        transcriber.pollNanoseconds = 5_000_000
        transcriber.dictationActive = hold
        f.runtime.apiToken = "test-token"
        return APIService(transcriber: transcriber, models: f.source, scratch: root.appendingPathComponent("parts"), version: "test")
    }
    /// A JSON request naming a local file, as `vella transcribe` sends it.
    @MainActor private func request(_ audio: URL, model: String) throws -> APIRequest {
        let head = try XCTUnwrap(HTTPHead.parse(Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nX-Vella-Token: test-token".utf8)))
        let body = try JSONSerialization.data(withJSONObject: ["path": audio.path, "model": model])
        return APIRequest(head: head, body: .memory(body))
    }
    private func audio() throws -> URL {
        let url = root.appendingPathComponent("speech.wav")
        try writeTestWAV(url, bursts: [0.1], gap: 0.01)
        return url
    }

    @MainActor func testWaitingRequestUsesThePrecisionReloadedMeanwhile() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "4b")
        var hold = true
        let service = service(f, hold: { hold })
        let pending = try request(try audio(), model: "whisper-1")
        let job = Task { await service.handle(pending) }
        try await waitUntil { service.transcriber.running == 1 }
        try await f.load(f.alpha, "BF16")
        hold = false
        let response = await job.value
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))

        let config = try f.config()
        XCTAssertEqual(URL(fileURLWithPath: config.model).lastPathComponent, "alpha-bf16")
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.path, config.model, "the API did not load its arrival-time 4-bit over the Reload")
        XCTAssertEqual(f.controller.selected(f.alpha), "BF16")
        XCTAssertEqual(f.runtime.settings.launchSet.map(\.path), [config.model])
        let alias = try XCTUnwrap(service.resolve("whisper-1"))
        XCTAssertEqual(alias.path, config.model)
        XCTAssertEqual(alias.precision, "BF16")
    }

    @MainActor func testShieldFollowsTheCurrentModelSelectedWhileTheRequestWaits() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "4b")
        let gamma = ModelFamily(id: "gamma", name: "Gamma", mode: .dictation, languages: ["en"], params: "1B", license: "test", native: "BF16", variants: [
            "BF16": CatalogVariant(id: "gamma-bf16", repository: "org/g", revision: String(repeating: "d", count: 40), downloadBytes: 1000, architecture: "parakeet")])
        f.controller.catalog.families.append(gamma)
        let folder = root.appendingPathComponent("gamma-bf16")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        f.controller.dictation.installed["gamma-bf16"] = InstalledModel(path: folder.path)
        var hold = true
        let service = service(f, hold: { hold })
        let pending = try request(try audio(), model: "gamma")
        let job = Task { await service.handle(pending) }
        try await waitUntil { service.transcriber.running == 1 }
        // Zeta becomes the current dictation model while the request waits; memory then fits only one more model.
        try await f.load(f.zeta, "BF16")
        try f.runtime.setAvailableMB(2500)
        hold = false
        let response = await job.value
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        XCTAssertTrue(f.runtime.isLoaded("zeta"), "the current dictation model is kept")
        XCTAssertEqual(f.runtime.status.evictions?.map(\.model), ["alpha"], "the model that is no longer current made room")
    }

    /// Between a Load finishing and its selection being written, loaded and selected disagree: API work waits it out.
    @MainActor func testRequestWaitsWhileALoadAndSelectIsInFlight() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "4b")
        let service = service(f, hold: { false })
        f.runtime.beginSelection()
        let pending = try request(try audio(), model: "zeta")
        let job = Task { await service.handle(pending) }
        try await waitUntil { service.transcriber.running == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(f.runtime.isLoaded("zeta"), "nothing loads until the selection is written")
        f.runtime.endSelection()
        let response = await job.value
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        XCTAssertTrue(f.runtime.isLoaded("zeta"))
    }

    @MainActor func testCurrentModelIsReportedAndUsedAtItsSelectedPrecision() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "BF16")
        let selected = try f.config().model
        // A saved recording retried with its older precision loads Alpha 4-bit without changing the selection.
        let older = f.bridge.ref(f.alpha, "4b", path: try f.path(f.alpha, "4b"))
        try await f.backend.preload(older, residency: .onDemand)
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.precision, "4b")
        XCTAssertEqual(try f.config().model, selected)

        let service = service(f, hold: { false })
        let current = try XCTUnwrap(service.resolve("whisper-1"))
        XCTAssertEqual(current.precision, "BF16", "the precision the next dictation uses")
        XCTAssertFalse(current.loaded)
        let status = try XCTUnwrap(service.status()["dictation_model"] as? [String: Any])
        XCTAssertEqual(status["precision"] as? String, "BF16")

        let response = await service.handle(try request(try audio(), model: "whisper-1"))
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.path, selected, "the request ran on the selected precision")
        XCTAssertEqual(try f.config().model, selected)
    }
}
