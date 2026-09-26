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

    // MARK: Streaming fixtures

    /// Family id = folder name before "@", precision after it (default 8b); 1,000 MB measured.
    static let resolver: (String, RecognitionMode) -> ModelRef? = { path, mode in
        let name = URL(fileURLWithPath: path).lastPathComponent
        let family = name.components(separatedBy: "@").first!
        let precision = name.contains("@") ? name.components(separatedBy: "@")[1] : "8b"
        return ModelRef(id: family, precision: precision, path: path, mode: mode, name: family, memoryMB: 1000, precisionOptions: ["4b", "8b", "BF16"])
    }
    @MainActor private func streaming(_ runtime: Runtime) throws -> StreamingBackend {
        let backend = StreamingBackend(helper: try FakeStreamingWorker.install(in: root), timeout: 5, runtime: runtime)
        runtime.streaming = backend
        runtime.resolver = Self.resolver
        return backend
    }
    @MainActor private func dictation(_ runtime: Runtime) throws -> Backend {
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        runtime.dictation = backend
        runtime.resolver = Self.resolver
        return backend
    }
    private func streamConfig(_ path: String) throws -> Configuration {
        try Configuration(executable: "/usr/bin/python3", model: "/fixture/dictation", mode: .streaming, streamingModel: path).forRecording()
    }
    private func path(_ name: String) -> String { root.appendingPathComponent("models/\(name)").path }
    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    // MARK: R2 — replacing the hot streaming model through start keeps process ownership

    @MainActor func testR2StartWithAnotherModelRetiresTheOldChildAndIgnoresItsLateOutput() async throws {
        let runtime = try Runtime.isolated(root)
        let backend = try streaming(runtime); defer { backend.shutdown() }
        // B hot and idle; its child ignores SIGTERM and, after stdin EOF, writes a late status line and a stray reply.
        try await backend.preload(runtime.resolve(path("streamB-lateexit"), mode: .streaming), residency: .onDemand)
        let old = try XCTUnwrap(backend.processID)
        try await backend.start(config: streamConfig(path("streamA")))
        let new = try XCTUnwrap(backend.processID)
        XCTAssertNotEqual(new, old)
        XCTAssertFalse(alive(old), "the replaced child was retired and awaited before the new one launched")
        try await Task.sleep(nanoseconds: 700_000_000) // any late output of the old child has been read by now
        XCTAssertEqual(backend.processID, new, "late output of the old child cannot retire the replacement")
        XCTAssertEqual(Set(runtime.status.models.keys), ["streamA"], "the old family's runtime entry is gone")
        XCTAssertEqual(runtime.status.models["streamA"]?.pid, new)
        XCTAssertNil(runtime.status.error)
        try await backend.feed(Data(repeating: 0, count: 6400))
        let final = try await backend.finish(expectedFrames: 1600)
        XCTAssertEqual(final, "hello world")
        XCTAssertEqual(backend.processID, new, "a clean finish keeps the replacement hot")
    }

    // MARK: R3 — a refused or failed streaming Reload keeps / restores the working model

    @MainActor func testR3StreamingReloadRefusalKeepsAndLoadFailureRestoresTheWorkingModel() async throws {
        let runtime = try Runtime.isolated(root, availableMB: 10_000)
        let backend = try streaming(runtime); defer { backend.shutdown() }
        runtime.start(loadLaunchSet: false)
        try await runtime.load(runtime.resolve(path("nemo@8b"), mode: .streaming)) // manual
        let pid = try XCTUnwrap(backend.processID)
        // Refused BF16 (raw 1,000 − 1,000 loaded + 1,000 credit = 1,000 < 1,512): nothing is unloaded.
        try runtime.setAvailableMB(1_000)
        do { try await runtime.load(runtime.resolve(path("nemo@BF16"), mode: .streaming)); XCTFail("reload admitted") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("nemo at BF16 needs"), error.localizedDescription) }
        XCTAssertTrue(alive(pid), "the working worker survives a refusal")
        XCTAssertEqual(backend.processID, pid)
        XCTAssertEqual(runtime.status.models["nemo"]?.precision, "8b")
        // Admitted but the load fails: the previous precision comes back, still manual, launch set unchanged.
        try runtime.setAvailableMB(10_000)
        do { try await runtime.load(runtime.resolve(path("nemo@BF16-loadfail"), mode: .streaming)); XCTFail("failed load accepted") } catch { }
        XCTAssertEqual(runtime.status.models["nemo"]?.precision, "8b")
        XCTAssertEqual(runtime.status.models["nemo"]?.residency, "manual")
        XCTAssertEqual(runtime.settings.launchSet.map(\.precision), ["8b"])
        let restored = try XCTUnwrap(backend.processID)
        XCTAssertTrue(alive(restored))
        // The restored worker serves a session.
        try await backend.start(config: streamConfig(path("nemo@8b")))
        XCTAssertEqual(backend.processID, restored, "same model: no relaunch")
        try await backend.feed(Data(repeating: 0, count: 6400))
        let final = try await backend.finish(expectedFrames: 1600)
        XCTAssertEqual(final, "hello world")
    }

    // MARK: R4 — a failed or refused Load/Reload does not become the dictation selection

    /// A Models controller over a fixture catalog (no benchmarks) with the given variants installed in an isolated registry.
    @MainActor private func controller(_ families: [ModelFamily], installed: [String: String]) throws -> ModelsController {
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: families)).write(to: resources.appendingPathComponent("models.json"))
        let registry = root.appendingPathComponent("support/models-installed.json")
        let controller = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                          streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: root.appendingPathComponent("no-benchmarks.json"),
                                          selectionsURL: root.appendingPathComponent("model-precision.json"))
        for (id, path) in installed {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            controller.dictation.installed[id] = InstalledModel(path: path)
        }
        return controller
    }
    private func variant(_ id: String) -> CatalogVariant {
        CatalogVariant(id: id, repository: "org/\(id)", revision: String(repeating: "b", count: 40), downloadBytes: 100_000_000, architecture: "parakeet")
    }

    @MainActor func testR4FailedOrRefusedReloadKeepsTheWorkingModelSelected() async throws {
        let family = ModelFamily(id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "0.6B", license: "test",
                                 native: "BF16", variants: ["8b": variant("alpha-8bit"), "4b": variant("alpha-4bit"), "BF16": variant("alpha-bf16")])
        let p8 = path("alpha-8b"), p4 = path("alpha-4b-loadfail"), p16 = path("alpha-bf16")
        let controller = try controller([family], installed: ["alpha-8bit": p8, "alpha-4bit": p4, "alpha-bf16": p16])
        let runtime = try Runtime.isolated(root)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        runtime.dictation = backend
        defer { backend.shutdown() }
        let model = Model(configurationURL: runtime.configURL); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: model)
        runtime.start(loadLaunchSet: false)
        func selected() throws -> String { try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)).model }

        controller.setPrecision(family, "8b"); controller.perform(family) // Load 8b
        try await waitUntil { (try? selected()) == p8 && runtime.status.models["alpha"]?.precision == "8b" }

        // Reload to 4b fails to load: the selection stays 8b and the next dictation is served by the working 8b worker.
        controller.setPrecision(family, "4b")
        XCTAssertEqual(controller.action(family), .reload)
        controller.perform(family)
        try await waitUntil { controller.lastError != nil }
        XCTAssertEqual(try selected(), p8)
        XCTAssertEqual(controller.dictation.activeModelPath, p8)
        XCTAssertEqual(runtime.status.models["alpha"]?.precision, "8b")
        let next = try recording("next", config: Configuration(model: p8))
        let wav = try next.wav(for: next.manifest.segments[0])
        let text = try await backend.transcribe(wav, config: try backend.configuration())
        XCTAssertEqual(text, "Fixture recognized speech.")
        XCTAssertEqual(runtime.status.models["alpha"]?.precision, "8b", "the next request used the still-working model")

        // Reload to BF16 refused for memory: same outcome.
        controller.lastError = nil
        try runtime.setAvailableMB(900)
        controller.setPrecision(family, "BF16"); controller.perform(family)
        try await waitUntil { controller.lastError != nil }
        XCTAssertTrue(controller.lastError?.hasPrefix("Alpha at BF16 needs") == true, controller.lastError ?? "")
        XCTAssertEqual(try selected(), p8)
        XCTAssertEqual(runtime.status.models["alpha"]?.precision, "8b")
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

/// A streaming worker speaking the app's stdio protocol, Keep Hot like the real one (a clean finish keeps the process
/// and model). Folder name selects behaviour: `loadfail` answers load/start with an error and exits; `slowload`
/// takes 0.5 s to load; `lateexit` ignores SIGTERM and, after stdin EOF, writes a late status line and a stray reply.
enum FakeStreamingWorker {
    static let script = #"""
#!/usr/bin/env python3
import json,sys,os,base64,time,signal
model=None; frames=0
fp=float(os.environ.get('FAKE_FOOTPRINT_MB','1000'))
def push(ev):
    print(json.dumps({'status':{'worker':'streaming','pid':os.getpid(),'event':ev,'model':model,'engine':'mlx','memory':{'footprint_mb':fp}}}),flush=True)
late=False
for line in sys.stdin:
    q=json.loads(line); op=q.get('op'); r={'id':q['id'],'frames':frames}
    if op in ('load','start'):
        name=q['model'].rstrip('/').split('/')[-1]
        if 'loadfail' in name:
            r['error']='The streaming model failed to load.'; print(json.dumps(r),flush=True); break
        if 'lateexit' in name: late=True; signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if 'slowload' in name and op=='load': time.sleep(0.5)
        if model!=q['model']: model=q['model']; push('load')
        if op=='start': frames=0; r['frames']=0
        else: r['loaded']=True
    elif op=='audio':
        frames+=len(base64.b64decode(q['pcm']))//4; r.update(frames=frames,partial='hello',committed='')
    elif op=='finish':
        r.update(frames=frames,done=True,committed='hello world',partial='')
    print(json.dumps(r),flush=True)
if late:
    time.sleep(0.3); push('late')
    print(json.dumps({'id':'00000000-0000-0000-0000-000000000000','frames':0,'error':'late'}),flush=True)
"""#
    static func install(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("fake-streaming-worker.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
