import XCTest
import AppKit
import CryptoKit
import Darwin
@testable import Vella
import VellaCore

/// Regression tests for model lifecycle and worker supervision, each built from a reproduction: the real
/// app/runtime wiring with fake stdio workers, an isolated support dir, a fake memory probe and mocked HTTP.
/// Nothing touches the user's support dir, models or the network.
final class RuntimeRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-runtime-regression-\(UUID())")
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

    // MARK: first-dictation Get through the real download permission hook

    @MainActor func testGetDownloadsThroughRealPermissionHookThenTranscribesClipboardOnly() async throws {
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
        MockHubProtocol.handler = { request in
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
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [MockHubProtocol.self]
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry)
        dictation.downloadConfiguration = http
        let controller = ModelsController(dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: root.appendingPathComponent("no-benchmarks.json"))

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

        // The Get row asks first; Cancel downloads nothing and keeps the offer.
        var prompts: [DownloadPrompt] = []
        bridge.presentDownload = { prompts.append($0); return false }
        delegate.getPendingModel()
        XCTAssertEqual(prompts.map(\.variantID), [variant.id])
        XCTAssertTrue(prompts[0].body.contains("transcribes the saved recording"), prompts[0].body)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(served.isEmpty, "Cancel downloads nothing")
        XCTAssertNil(dictation.downloadingID)
        XCTAssertNotNil(model.pendingModelRequest)
        bridge.presentDownload = { prompts.append($0); return true }
        delegate.getPendingModel()
        XCTAssertEqual(prompts.count, 2)
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

    // MARK: replacing the hot streaming model through start keeps process ownership

    @MainActor func testStartWithAnotherModelRetiresTheOldChildAndIgnoresItsLateOutput() async throws {
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

    // MARK: a refused or failed streaming Reload keeps / restores the working model

    @MainActor func testStreamingReloadRefusalKeepsAndLoadFailureRestoresTheWorkingModel() async throws {
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

    // MARK: a failed or refused Load/Reload does not become the dictation selection

    /// A Models controller over a fixture catalog (no benchmarks) with the given variants installed in an isolated registry.
    @MainActor private func controller(_ families: [ModelFamily], installed: [String: String]) throws -> ModelsController {
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: families)).write(to: resources.appendingPathComponent("models.json"))
        let registry = root.appendingPathComponent("support/models-installed.json")
        let controller = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                          streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: root.appendingPathComponent("no-benchmarks.json"))
        for (id, path) in installed {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            controller.dictation.installed[id] = InstalledModel(path: path)
        }
        return controller
    }
    private func variant(_ id: String) -> CatalogVariant {
        CatalogVariant(id: id, repository: "org/\(id)", revision: String(repeating: "b", count: 40), downloadBytes: 100_000_000, architecture: "parakeet")
    }

    @MainActor func testFailedOrRefusedReloadKeepsTheWorkingModelSelected() async throws {
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

        controller.preview(family, "8b"); controller.perform(family) // Load 8b
        try await waitUntil { (try? selected()) == p8 && runtime.status.models["alpha"]?.precision == "8b" }

        // Reload to 4b fails to load: the selection stays 8b and the next dictation is served by the working 8b worker.
        controller.preview(family, "4b")
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
        controller.preview(family, "BF16"); controller.perform(family)
        try await waitUntil { controller.lastError != nil }
        XCTAssertTrue(controller.lastError?.hasPrefix("Alpha at BF16 needs") == true, controller.lastError ?? "")
        XCTAssertEqual(try selected(), p8)
        XCTAssertEqual(runtime.status.models["alpha"]?.precision, "8b")
    }

    // MARK: no idle-timer churn while a model is pinned past its deadline

    @MainActor func testPinnedPastDeadlineArmsNoTimerThenUnloadsAfterTheNewIdleWindow() async throws {
        let runtime = try Runtime.isolated(root, minuteSeconds: 0.01) // on demand 15 min = 150 ms
        let backend = try streaming(runtime); defer { backend.shutdown() }
        try await backend.start(config: streamConfig(path("longstream"))) // on demand, pinned for the session
        let firingsAtStart = runtime.idleTimerFirings
        try await Task.sleep(nanoseconds: 1_000_000_000) // several idle windows past the deadline
        try await backend.feed(Data(repeating: 0, count: 6400))
        XCTAssertLessThanOrEqual(runtime.idleTimerFirings - firingsAtStart, 1, "an expired timer must not re-arm itself while pinned")
        XCTAssertNotNil(runtime.status.models["longstream"], "a pinned model never idles out")
        let final = try await backend.finish(expectedFrames: 1600) // unpin: idle window starts now
        XCTAssertEqual(final, "hello world")
        XCTAssertNotNil(runtime.status.models["longstream"])
        try await waitUntil { runtime.status.models["longstream"] == nil }
        XCTAssertEqual(runtime.status.evictions?.last?.reason, "idle: unused for 15 min (loaded on demand)")
    }

    // MARK: critical memory pressure never stops a live stream; idle models are shed

    @MainActor func testCriticalPressureShedsIdleModelsButKeepsTheLiveStream() async throws {
        let runtime = try Runtime.isolated(root)
        let dictation = try dictation(runtime); defer { dictation.shutdown() }
        let stream = try streaming(runtime); defer { stream.shutdown() }
        runtime.start(loadLaunchSet: false)
        try await runtime.load(runtime.resolve(path("alpha"), mode: .dictation)) // first manual: kept
        let beta = try recording("beta", config: Configuration(model: path("beta")))
        _ = try await dictation.transcribe(try beta.wav(for: beta.manifest.segments[0]), config: Configuration(model: path("beta"))) // idle, on demand
        try await stream.start(config: streamConfig(path("live")))
        try await stream.feed(Data(repeating: 0, count: 6400))
        let pid = try XCTUnwrap(stream.processID)
        XCTAssertEqual(Set(runtime.status.models.keys), ["alpha", "beta", "live"])

        runtime.handleMemoryPressure(critical: true) // between packet requests
        try await waitUntil { runtime.status.models["beta"] == nil }
        XCTAssertEqual(stream.processID, pid, "the pinned live stream keeps its worker")
        XCTAssertTrue(alive(pid))
        XCTAssertNotNil(runtime.status.models["live"])
        XCTAssertNotNil(runtime.status.models["alpha"])
        XCTAssertEqual(runtime.status.evictions?.map(\.model), ["beta"])
        try await stream.feed(Data(repeating: 0, count: 6400))
        let final = try await stream.finish(expectedFrames: 3200)
        XCTAssertEqual(final, "hello world")
    }

    // MARK: a manual streaming worker killed after a finished session is restarted

    @MainActor func testManualStreamingWorkerKilledAfterASessionRestarts() async throws {
        let runtime = try Runtime.isolated(root)
        let stream = try streaming(runtime); defer { stream.shutdown() }
        runtime.start(loadLaunchSet: false)
        try await runtime.load(runtime.resolve(path("nemo"), mode: .streaming)) // manual, Always
        // Killed before its first session: restarts (worked before the fix too).
        let first = try XCTUnwrap(stream.processID)
        kill(first, SIGKILL)
        try await waitUntil(8) { runtime.status.models["nemo"]?.pid.map { $0 != first } == true }
        // A finished session, then the idle worker dies: it must restart as well.
        try await stream.start(config: streamConfig(path("nemo")))
        try await stream.feed(Data(repeating: 0, count: 6400))
        let final = try await stream.finish(expectedFrames: 1600)
        XCTAssertEqual(final, "hello world")
        let idle = try XCTUnwrap(stream.processID)
        kill(idle, SIGKILL)
        try await waitUntil(8) { runtime.status.models["nemo"]?.pid.map { $0 != idle } == true }
        XCTAssertEqual(runtime.status.models["nemo"]?.residency, "manual")
        XCTAssertTrue(try String(contentsOf: runtime.logURL, encoding: .utf8).contains("nemo: streaming worker exited while idle"))
    }

    // MARK: Delete is ordered after unload and cleans the launch set even for an evicted model

    @MainActor func testDeleteUnloadsFirstCleansTheLaunchSetAndKeepsIntentOnFailure() async throws {
        _ = NSApplication.shared
        let alpha = ModelFamily(id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "0.6B", license: "test", native: "BF16",
                                variants: ["8b": variant("alpha-slowexit-8bit"), "4b": variant("alpha-4bit")])
        let beta = ModelFamily(id: "beta", name: "Beta", mode: .dictation, languages: ["en"], params: "0.6B", license: "test", native: "8b",
                               variants: ["8b": variant("beta-8bit")])
        let models = root.appendingPathComponent("support/Models")
        let a8 = models.appendingPathComponent("alpha-slowexit-8bit").path, b8 = models.appendingPathComponent("beta-8bit").path
        let controller = try controller([alpha, beta], installed: ["alpha-slowexit-8bit": a8, "beta-8bit": b8])
        let library = controller.dictation
        try JSONEncoder().encode(library.installed).write(to: library.registryURL) // deleteModel re-reads the registry
        let runtime = try Runtime.isolated(root)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        library.currentModelPath = { (try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)))?.model ?? "" }
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        runtime.dictation = backend
        defer { backend.shutdown() }
        let model = Model(configurationURL: runtime.configURL); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: model)
        runtime.start(loadLaunchSet: false)
        let menus = ModelsMenu(controller: controller)
        let host = try XCTUnwrap(menus.modelItem().submenu?.items.first?.view as? MenuTableHostingView)
        var alerts: [String] = []
        menus.presentDeletionConfirmation = { alert in alerts.append(alert.messageText); return .alertSecondButtonReturn }
        func delete(_ family: ModelFamily) { host.rootView.requestDelete(family) }

        // Manual alpha 8b (launch set), then beta: beta is selected, alpha stays hot but unselected.
        controller.preview(alpha, "8b"); controller.perform(alpha)
        try await waitUntil { runtime.status.models["alpha"] != nil }
        controller.perform(beta)
        try await waitUntil { library.activeModelPath == b8 && runtime.status.models["beta"] != nil }
        XCTAssertEqual(Set(runtime.settings.launchSet.map(\.id)), ["alpha", "beta"])
        let alphaPID = try XCTUnwrap(runtime.status.models["alpha"]?.pid)

        // Deletion failure: the launch set keeps alpha and the unloaded manual model is loaded again.
        var trashedWhileAlive: [Bool] = []
        library.trashModel = { _ in trashedWhileAlive.append(kill(alphaPID, 0) == 0); throw CocoaError(.fileWriteNoPermission) }
        delete(alpha)
        try await waitUntil { alerts.contains("Model was not deleted") }
        XCTAssertEqual(trashedWhileAlive, [false], "the worker had exited (its slow exit awaited) before files were touched")
        try await waitUntil { runtime.status.models["alpha"] != nil }
        XCTAssertEqual(Set(runtime.settings.launchSet.map(\.id)), ["alpha", "beta"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a8))

        // Hot but unselected, slow to exit: unloaded (awaited) before the files move; launch-set entry removed.
        let hotPID = try XCTUnwrap(runtime.status.models["alpha"]?.pid)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var aliveAtTrash: [Bool] = []
        library.trashModel = { source in
            aliveAtTrash.append(kill(hotPID, 0) == 0 || runtime.isLoaded("alpha"))
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target); return target
        }
        delete(alpha)
        try await waitUntil { !FileManager.default.fileExists(atPath: a8) && runtime.settings.launchSet.count == 1 }
        XCTAssertEqual(aliveAtTrash, [false])
        XCTAssertEqual(runtime.settings.launchSet.map(\.id), ["beta"])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)).residency.launchSet.map(\.id), ["beta"])

        // Already evicted: still removed from the launch set, so the next launch does not load deleted files.
        try FileManager.default.createDirectory(atPath: a8, withIntermediateDirectories: true)
        library.installed["alpha-slowexit-8bit"] = InstalledModel(path: a8)
        try JSONEncoder().encode(library.installed).write(to: library.registryURL)
        try await runtime.load(runtime.resolve(a8, mode: .dictation)) // manual again; beta stays selected
        XCTAssertEqual(library.activeModelPath, b8)
        await runtime.evict("alpha", reason: "memory: test")
        XCTAssertNil(runtime.status.models["alpha"])
        XCTAssertEqual(Set(runtime.settings.launchSet.map(\.id)), ["alpha", "beta"])
        delete(alpha)
        try await waitUntil { !FileManager.default.fileExists(atPath: a8) && runtime.settings.launchSet.count == 1 }
        XCTAssertEqual(runtime.settings.launchSet.map(\.id), ["beta"])
    }

    // MARK: a dictation that finds its model still loading waits for it

    @MainActor func testDictationDuringAPendingLoadAwaitsReadiness() async throws {
        let runtime = try Runtime.isolated(root)
        let backend = try dictation(runtime); defer { backend.shutdown() }
        runtime.start(loadLaunchSet: false)
        let model = path("alpha-delayload") // the fake takes 1 s to answer load
        try FileManager.default.createDirectory(atPath: model, withIntermediateDirectories: true)
        let loading = Task { try await runtime.load(runtime.resolve(model, mode: .dictation)) } // manual Load / launch set
        try await waitUntil { runtime.status.loading == "alpha-delayload" }
        let session = try recording("during-load", config: Configuration(model: model))
        let text = try await backend.transcribe(try session.wav(for: session.manifest.segments[0]), config: Configuration(model: model))
        XCTAssertEqual(text, "Fixture recognized speech.")
        try await loading.value
        XCTAssertEqual(backend.loadedModelIDs, ["alpha-delayload"], "one worker: the request used the loading one")
        XCTAssertEqual(runtime.status.models["alpha-delayload"]?.residency, "manual")
    }

    // MARK: one automatic retry of a segment after a worker crash mid-transcription

    @MainActor func testWorkerCrashMidSegmentRetriesOnceOnAFreshWorkerElseFailsForManualRetry() async throws {
        let runtime = try Runtime.isolated(root)
        let backend = try dictation(runtime); defer { backend.shutdown() }
        runtime.start(loadLaunchSet: false)
        let runner = SessionTranscriber(request: { url, config in try await backend.transcribe(url, config: config) })
        var retries: [Int] = []
        runner.onRetry = { index, _ in retries.append(index) }

        let once = path("crashonce"); try FileManager.default.createDirectory(atPath: once, withIntermediateDirectories: true)
        let first = try recording("once", config: Configuration(model: once))
        let text = try await runner.run(first)
        XCTAssertEqual(text, "Fixture recognized speech.")
        XCTAssertEqual(retries, [1])
        XCTAssertEqual(try RecordingSession(directory: first.directory).manifest.state, "transcribed")
        XCTAssertNotNil(runtime.status.models["crashonce"], "the retry's fresh worker is registered, not removed by the crash")

        retries = []
        let always = path("crashalways"); try FileManager.default.createDirectory(atPath: always, withIntermediateDirectories: true)
        let second = try recording("always", config: Configuration(model: always))
        do { _ = try await runner.run(second); XCTFail("a repeated crash must not succeed") }
        catch { XCTAssertTrue(error is WorkerExited, "\(error)") }
        XCTAssertEqual(retries, [1], "exactly one automatic retry")
        XCTAssertNil(try RecordingSession(directory: second.directory).manifest.segments[0].text, "left for the manual Retry")
    }

    @MainActor private final class Focus {
        var current: String? = "A"
        var snapshots: [String?] = []
        func capture() -> Model.DestinationCheck {
            let selected = current
            snapshots.append(selected)
            return { [self] in selected == nil ? "Missing field at Finish" : (selected == current ? nil : "Finish target changed") }
        }
    }

    /// Through Finish: the retry keeps the Finish-time destination snapshot and paste semantics (no new snapshot, not
    /// downgraded to clipboard-only recovery); a second crash falls back to the manual, clipboard-only Retry.
    @MainActor func testWorkerCrashRetryKeepsFinishDestinationAndPasteSemantics() async throws {
        for crashes in [1, 2] {
            let config = root.appendingPathComponent("finish-\(crashes).json")
            try JSONEncoder().encode(Configuration(executable: "/unused", model: "/synthetic")).write(to: config)
            let session = try recording("finish-\(crashes)", config: Configuration(executable: "/unused", model: "/synthetic"))
            let focus = Focus()
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            var calls = 0
            let model = Model(pasteboard: board, stopCapture: { $0.adoptForTesting(session) },
                              transcriptionRequest: { _, _ in
                                  calls += 1
                                  if calls <= crashes { throw WorkerExited() }
                                  focus.current = "C" // moved away: the Finish-time check must decide (no real paste in a test)
                                  return "retried words"
                              }, configurationURL: config, captureDestination: { focus.capture() })
            defer { model.cancel() }
            model.phase = .recording // synthetic capture: no microphone
            focus.current = "B"
            model.finish()
            try await waitUntil { model.phase == .success || model.phase == .failed }
            XCTAssertEqual(focus.snapshots, ["B"], "the destination is captured once, at Finish")
            if crashes == 1 {
                XCTAssertEqual(calls, 2)
                XCTAssertEqual(model.phase, .success, model.message)
                XCTAssertTrue(model.message.contains("Finish target changed"), "decided against the Finish-time snapshot: \(model.message)")
                XCTAssertEqual(board.string(forType: .string), "retried words")
            } else {
                XCTAssertEqual(calls, 2, "one automatic retry only")
                XCTAssertEqual(model.phase, .failed)
                XCTAssertTrue(model.message.contains("Retry resumes unfinished segments"), model.message)
                XCTAssertNil(board.string(forType: .string), "nothing pasted or copied")
                XCTAssertEqual(model.automaticInsertionBlockReason, "Recovered or cancelled recordings are clipboard-only.")
            }
        }
    }

    // MARK: a finished download does not unload hot models for calibration

    @MainActor func testDownloadCompletionKeepsHotModelsLoaded() async throws {
        _ = NSApplication.shared
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let variant = CatalogVariant(id: "fixture-v3-4bit", repository: "org/fixture", revision: String(repeating: "a", count: 40),
                                     downloadBytes: 4_200, architecture: "parakeet")
        let family = ModelFamily(id: "fixture-v3", name: "Fixture v3", mode: .dictation, languages: ["en"], params: "0.6B",
                                 license: "test", native: "4b", variants: ["4b": variant])
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [family])).write(to: resources.appendingPathComponent("models.json"))
        let files: [String: Data] = [
            "config.json": Data(#"{"target":"nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel","quantization":{"bits":4}}"#.utf8),
            "model.safetensors": Data(repeating: 7, count: 4096)]
        MockHubProtocol.handler = { request in
            if request.url!.path.contains("/api/models/") {
                let siblings: [[String: Any]] = files.map { name, data in
                    ["rfilename": name, "size": data.count, "lfs": ["sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]]
                }
                return (200, try JSONSerialization.data(withJSONObject: ["sha": variant.revision, "siblings": siblings]))
            }
            guard let data = files[request.url!.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            return (200, data)
        }
        // A hot (manual) streaming model on the Model's own streaming backend: what releaseWorkers() would unload.
        let runtime = try Runtime.isolated(root)
        let stream = try streaming(runtime)
        let model = Model(configurationURL: runtime.configURL, streamingBackend: stream); defer { model.shutdown() }
        try await runtime.load(runtime.resolve(path("nemo"), mode: .streaming))
        let pid = try XCTUnwrap(stream.processID)
        // A dictation library that calibrates after a download (injected store, no worker).
        let registry = root.appendingPathComponent("support/models-installed.json")
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [MockHubProtocol.self]
        let calibration = CalibrationStore(directory: root.appendingPathComponent("calibrations"), resources: resources, worker: { nil })
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry, calibration: calibration)
        dictation.downloadConfiguration = http
        let controller = ModelsController(dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: root.appendingPathComponent("no-benchmarks.json"))
        let delegate = AppDelegate(model: model)
        delegate.modelsMenu = delegate.makeModelsMenu(controller: controller) // the real calibration hook
        RuntimeBridge(runtime: runtime).attach(delegate)

        dictation.selectedID = variant.id; dictation.download(approval: confirmed(variant.id))
        try await waitUntil(10) { dictation.installed[variant.id] != nil && !dictation.busy }
        XCTAssertEqual(stream.processID, pid, "the hot model stayed loaded after the download")
        XCTAssertTrue(alive(pid))
        XCTAssertNotNil(runtime.status.models["nemo"])
        XCTAssertNil(dictation.calibratingID)
        XCTAssertTrue(dictation.message.contains("Calibration deferred"), dictation.message)
    }
}

final class MockHubProtocol: URLProtocol {
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
