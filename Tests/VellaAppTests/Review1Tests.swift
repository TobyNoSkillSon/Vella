import XCTest
import AppKit
import CryptoKit
import Darwin
@testable import Vella
import VellaCore

/// Regression tests for Review 1 (lab/notes/REVIEW.md), one per finding, built from the review's repro: the real
/// app/runtime wiring with fake stdio workers, an isolated support dir, a fake memory probe and mocked HTTP.
/// Nothing touches the user's support dir, models or the network.
final class Review1Tests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-review1-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ message: String = "", _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "condition not reached within \(timeout) s \(message)")
    }
    private func recording(_ name: String, config: Configuration, seconds: [Int] = [1]) throws -> RecordingSession {
        let session = try RecordingSession(root: root.appendingPathComponent(name), config: config)
        let writer = try SegmentedPCMWriter(session: session)
        for count in seconds { try [Float](repeating: 0.1, count: 16_000 * count).withUnsafeBufferPointer { try writer.append($0) } }
        try writer.finish(userStopped: true)
        return session
    }

    // MARK: R1 — first-dictation Get through the real download permission hook

    @MainActor func testR1GetDownloadsThroughRealPermissionHookThenTranscribesClipboardOnly() async throws {
        _ = NSApplication.shared
        // Catalog: one offered dictation family, one pinned 4b variant served by the mocked Hub.
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let variant = CatalogVariant(id: "fixture-v3-4bit", repository: "org/fixture", revision: String(repeating: "a", count: 40),
                                     downloadBytes: 4_200, architecture: "parakeet")
        let family = ModelFamily(id: "fixture-v3", name: "Fixture v3", mode: .dictation, languages: ["en"], params: "0.6B",
                                 license: "test", native: "4b", variants: ["4b": variant])
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [family])).write(to: resources.appendingPathComponent("models.json"))
        let files: [String: Data] = [
            "config.json": Data(#"{"target":"nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel","quantization":{"bits":4}}"#.utf8),
            "model.safetensors": Data(repeating: 42, count: 4096)]
        var served: [String] = []
        Review1HubStub.handler = { request in
            served.append(request.url!.lastPathComponent)
            if request.url!.path.contains("/api/models/") {
                let siblings: [[String: Any]] = files.map { name, data in
                    ["rfilename": name, "size": data.count, "lfs": ["sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]]
                }
                return (200, try JSONSerialization.data(withJSONObject: ["sha": variant.revision, "siblings": siblings]))
            }
            guard let data = files[request.url!.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            return (200, data)
        }
        let registry = root.appendingPathComponent("support/models-installed.json")
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [Review1HubStub.self]
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry)
        dictation.downloadConfiguration = http
        let controller = ModelsController(dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: root.appendingPathComponent("no-benchmarks.json"),
                                          selectionsURL: root.appendingPathComponent("model-precision.json"))

        let runtime = try Runtime.isolated(root)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        var requested: [String] = []
        let model = Model(pasteboard: pasteboard, transcriptionRequest: { _, config in requested.append(config.model); return "words after get" },
                          configurationURL: runtime.configURL)
        defer { model.shutdown() }
        // The real AppDelegate wiring: its `mayChangeModel` permission closure and the RuntimeBridge fetch.
        let delegate = AppDelegate(model: model)
        delegate.modelsMenu = delegate.makeModelsMenu(controller: controller)
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(delegate)

        let session = try recording("first", config: Configuration(model: ""))
        model.recover(session.directory)
        try await waitUntil { model.pendingModelRequest != nil }
        XCTAssertEqual(model.pendingModelRequest?.id, variant.id)
        XCTAssertTrue(served.isEmpty, "nothing downloads before Get")

        delegate.getPendingModel()
        XCTAssertEqual(model.phase, .preparing, "the model is busy while it waits for the download")
        XCTAssertFalse(dictation.mayChangeModel(), "the general permission hook still refuses (not relaxed)")
        try await waitUntil(10) { model.phase == .success || model.phase == .idle || model.phase == .failed }
        XCTAssertEqual(model.phase, .success, model.message)
        XCTAssertTrue(served.contains("model.safetensors"), "an actual (mocked) HTTP download ran")
        let path = try XCTUnwrap(dictation.installed[variant.id]?.path)
        XCTAssertEqual(requested, [path])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)).model, path)
        XCTAssertFalse(model.insertionWasAutomatic, "a recording transcribed after Get is clipboard-only")
        XCTAssertEqual(pasteboard.string(forType: .string), "words after get")
        XCTAssertNil(model.pendingModelRequest)
    }
}

final class Review1HubStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
