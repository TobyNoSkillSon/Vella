import XCTest
import AppKit
import CryptoKit
@testable import Vella
import VellaCore
import VellaTestSupport

/// An approval as the confirmation popup gives it when the user chooses Download (tests only; the app's popup is the
/// sole other source).
@MainActor func confirmed(_ variantID: String) -> DownloadApproval {
    DownloadGate.ask(DownloadPrompt(title: "test", body: "test", variantID: variantID, downloadBytes: 0, family: "test", precision: "test")) { _ in true }!
}

@MainActor private final class ActionSpy: ModelRuntimeActions {
    var calls: [String] = []
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) { calls.append("load \(family.id) \(precision) \(path)") }
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {
        calls.append("reload \(family.id) \(precision) \(path)")
    }
    func unload(family: ModelFamily) { calls.append("unload \(family.id)") }
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool { false }
}

/// ONE state for selected and loaded (Toby's 1.0.0 bug: model-precision.json said FP32 while dictation had loaded the
/// 4-bit, so the loaded row offered only a green Reload that silently started a 2.5 GB download), download confirmation
/// for every entry point, and partial-download clean-up. Fake worker and mocked Hub only; no model runs.
final class OneStateTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-one-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "condition not reached within \(timeout) s")
    }
    private var support: URL { root.appendingPathComponent("support") }
    private var configURL: URL { support.appendingPathComponent("config.json") }

    /// The shipped catalog with an isolated registry and config.json.
    @MainActor private func shipped() throws -> ModelsController {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let registry = support.appendingPathComponent("models-installed.json")
        let resources = ModelLibrary.resourceDirectory()
        return ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: configURL)
    }

    /// Alpha: BF16 published (the source), 4b made on this Mac from it.
    private let alpha = ModelFamily(
        id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "0.6B", license: "test", native: "BF16",
        variants: [
            "BF16": CatalogVariant(
                id: "alpha-bf16", repository: "org/alpha-bf16", revision: String(repeating: "b", count: 40),
                downloadBytes: 4_200, architecture: "parakeet"),
            "4b": CatalogVariant(id: "alpha-4bit-local", architecture: "parakeet", derivedFrom: "BF16", bits: 4, groupSize: 64)
        ])
    private var alphaFiles: [String: Data] {
        [
            "config.json": Data(#"{"target":"nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"}"#.utf8),
            "model.safetensors": Data(repeating: 7, count: 4096)
        ]
    }
    /// An alpha-only catalog; `installed` puts the BF16 source on disk. The Hub is mocked; `served` records requests.
    @MainActor private func alphaController(
        installed: Bool, served: @escaping (String) -> Void = { _ in },
        fail: String? = nil
    ) throws -> ModelsController {
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [alpha])).write(to: resources.appendingPathComponent("models.json"))
        let registry = support.appendingPathComponent("models-installed.json")
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry)
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [MockHubProtocol.self]
        dictation.downloadConfiguration = http
        let files = alphaFiles, revision = alpha.variants["BF16"]!.revision
        MockHubProtocol.handler = { request in
            let name = request.url!.lastPathComponent
            served(name)
            if request.url!.path.contains("/api/models/") {
                let siblings: [[String: Any]] = files.map { name, data in
                    ["rfilename": name, "size": data.count, "lfs": ["sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]]
                }
                return (200, try JSONSerialization.data(withJSONObject: ["sha": revision, "siblings": siblings]))
            }
            if name == fail { throw URLError(.networkConnectionLost) }
            guard let data = files[name] else { throw URLError(.fileDoesNotExist) }
            return (200, data)
        }
        let controller = ModelsController(
            dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: root.appendingPathComponent("no-benchmarks.json"), configURL: configURL)
        if installed {
            let source = dictation.modelsDirectory.appendingPathComponent("alpha-bf16")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: source.appendingPathComponent(name)) }
            dictation.installed["alpha-bf16"] = InstalledModel(path: source.path)
            try JSONEncoder().encode(dictation.installed).write(to: registry)
        }
        return controller
    }

    // MARK: One state

    /// Toby's repro: dictation loaded a 4-bit checkpoint while a stored choice said the 16-bit (not on disk): what is
    /// loaded wins. (Originally Parakeet v3 4-bit vs FP32; its 4 tier is now a mixed recipe, so a uniform 4-bit stands in.)
    @MainActor func testLoadedPrecisionWins() throws {
        let c = try shipped()
        let parakeet = try XCTUnwrap(c.catalog.family("whisper-large-v3-turbo"))
        let qwen = try XCTUnwrap(c.catalog.family("qwen3-asr-1.7b"))
        c.dictation.installed["whisper-large-v3-turbo-asr-4bit"] = InstalledModel(path: "/fixture/p4")
        c.dictation.installed["Qwen3-ASR-0.6B-bf16"] = InstalledModel(path: "/fixture/q06")
        c.streaming.installed["nemotron-3.5-asr-streaming-0.6b-8bit"] = InstalledModel(path: "/fixture/n8")
        var saved = Configuration(model: "/fixture/p4", streamingModel: "/fixture/n8")
        saved.lastLoaded = ["qwen3-asr-0.6b": "8b", "whisper-large-v3-turbo": "FP16"]
        try JSONEncoder().encode(saved).write(to: configURL)
        c.reloadConfig()
        c.runtime = TableRuntime(loaded: ["whisper-large-v3-turbo": LoadedFamily(precision: "4b", residency: "on_demand")])

        // The loaded row shows what is loaded and offers Unload, not a Reload.
        XCTAssertEqual(c.selected(parakeet), "4b")
        XCTAssertEqual(c.action(parakeet), .unload)
        XCTAssertFalse(c.needsDownload(parakeet))
        // Unloaded legacy published quants are non-tier imports: the row offers the native Get.
        c.runtime = TableRuntime()
        XCTAssertEqual(c.selected(parakeet), "FP16")
        XCTAssertEqual(c.action(parakeet), .get)
        let qwen06 = try XCTUnwrap(c.catalog.family("qwen3-asr-0.6b"))
        XCTAssertEqual(c.selected(qwen06), "8b", "the last-loaded precision")
        XCTAssertEqual(c.currentSelection(qwen06), ModelSelection(tier: .t8, path: .optimized, mode: .fast), "used before selections existed: Optimized Fast")
        // The old published Nemotron int8 likewise must not acquire the measured local tier identity.
        let nemotron = try XCTUnwrap(c.catalog.family("nemotron-3.5-streaming-0.6b"))
        XCTAssertEqual(c.selected(nemotron), "BF16")
        XCTAssertEqual(c.action(nemotron), .get)
        // Loaded at another precision: loaded wins over the record.
        c.runtime = TableRuntime(loaded: ["qwen3-asr-1.7b": LoadedFamily(precision: "4b")])
        XCTAssertEqual(c.selected(qwen), "4b")
        XCTAssertEqual(c.action(qwen), .unload)
    }

    /// A segment click is a preview: its numbers and the green Reload, nothing written; picking the loaded segment or
    /// closing the menu ends it.
    @MainActor func testPreviewIsTransientAndClosingTheMenuDiscardsIt() throws {
        _ = NSApplication.shared
        let c = try shipped()
        let menus = ModelsMenu(controller: c)
        let parakeet = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        c.dictation.installed["parakeet-tdt-0.6b-v3-mlx-4bit"] = InstalledModel(path: "/fixture/p4")
        try JSONEncoder().encode(Configuration(model: "/fixture/p4")).write(to: configURL)
        c.reloadConfig()
        let before = try Data(contentsOf: configURL)
        c.runtime = TableRuntime(loaded: ["parakeet-v3": LoadedFamily(precision: "4b")])
        XCTAssertEqual(c.action(parakeet), .unload)

        c.preview(parakeet, "BF16")
        XCTAssertEqual(c.selected(parakeet), "BF16", "the preview shows its own numbers")
        XCTAssertTrue(c.isPreviewing(parakeet))
        XCTAssertEqual(c.action(parakeet), .reload)
        XCTAssertTrue(c.needsDownload(parakeet))
        c.preview(parakeet, "4b")
        XCTAssertFalse(c.isPreviewing(parakeet), "picking the loaded precision ends the preview")
        XCTAssertEqual(c.action(parakeet), .unload)

        c.preview(parakeet, "8b")
        menus.menuDidClose(NSMenu())
        XCTAssertEqual(c.selected(parakeet), "4b", "closing without Reload discards the preview")
        XCTAssertEqual(c.action(parakeet), .unload)
        XCTAssertEqual(try Data(contentsOf: configURL), before, "a preview writes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("model-precision.json").path))
    }

    /// Load and Reload write the mode's model (what an on-demand dictation load uses) and the family's precision; the
    /// table and dictation read the same record, before and after Unload. Real bridge, fake worker.
    @MainActor func testDictationUsesExactlyWhatWasLastLoaded() async throws {
        _ = NSApplication.shared
        let c = try alphaController(installed: true)
        let runtime = try Runtime.isolated(root)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        XCTAssertEqual(runtime.configURL.standardizedFileURL, configURL.standardizedFileURL)
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        runtime.dictation = backend
        defer { backend.shutdown() }
        let model = DictationController(configurationURL: runtime.configURL); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime) // the table holds its actions weakly
        bridge.attach(controller: c, model: model)
        runtime.start(loadLaunchSet: false)
        func dictationModel() throws -> String { try backend.configuration().selectedModel }

        XCTAssertEqual(c.selected(alpha), "BF16")
        XCTAssertEqual(c.action(alpha), .load)
        c.perform(alpha)
        try await waitUntil { runtime.status.models["alpha"]?.precision == "BF16" && c.config?.lastLoaded["alpha"] == "BF16" }
        let source = try XCTUnwrap(c.dictation.installed["alpha-bf16"]?.path)
        XCTAssertEqual(try dictationModel(), source)
        XCTAssertEqual(c.action(alpha), .unload)

        c.preview(alpha, "4b")
        XCTAssertEqual(c.action(alpha), .reload)
        c.perform(alpha)
        try await waitUntil { runtime.status.models["alpha"]?.precision == "4b" && c.config?.lastLoaded["alpha"] == "4b" }
        let derived = c.dictation.modelsDirectory.appendingPathComponent("alpha-4bit-local").standardizedFileURL.path
        XCTAssertEqual(try dictationModel(), derived, "Reload made the 4b the dictation model")
        c.discardPreviews()
        XCTAssertEqual(c.selected(alpha), "4b")
        XCTAssertEqual(c.action(alpha), .unload)

        c.perform(alpha) // Unload
        try await waitUntil { runtime.status.models["alpha"] == nil }
        XCTAssertEqual(c.selected(alpha), "4b", "an unloaded row shows what dictation will load")
        XCTAssertEqual(c.action(alpha), .load)
        XCTAssertEqual(try dictationModel(), derived)
        XCTAssertEqual(c.identify(path: try dictationModel(), mode: .dictation)?.precision, c.selected(alpha), "the table and dictation agree")
        withExtendedLifetime(bridge) {}
    }

    // MARK: Download confirmation

    /// Every table entry point that needs a download asks first; Cancel starts nothing; no presenter = no download.
    @MainActor func testEveryTableDownloadAsksFirstAndCancelDownloadsNothing() async throws {
        var served: [String] = []
        let c = try alphaController(installed: false, served: { served.append($0) })
        let spy = ActionSpy(); c.actions = spy
        c.runtime = TableRuntime()
        var prompts: [DownloadPrompt] = []
        c.confirmDownload = { prompt, answer in
            prompts.append(prompt); answer(DownloadGate.ask(prompt) { _ in false })
        }

        // 1. Get (nothing on disk).
        XCTAssertEqual(c.action(alpha), .get)
        c.perform(alpha)
        // 2. Load of a precision made on this Mac whose source is missing.
        c.preview(alpha, "4b")
        XCTAssertEqual(c.action(alpha), .get)
        c.perform(alpha)
        // 3. Reload of a loaded model at a precision not on disk (the source was deleted meanwhile).
        c.runtime = TableRuntime(loaded: ["alpha": LoadedFamily(precision: "4b")])
        c.preview(alpha, "BF16")
        XCTAssertEqual(c.action(alpha), .reload)
        c.perform(alpha)

        XCTAssertEqual(prompts.map(\.title), ["Download Alpha · 16 (BF16)?", "Download Alpha · 16 (BF16) to make 4 (4-bit)?", "Download Alpha · 16 (BF16)?"])
        XCTAssertTrue(prompts.allSatisfy { $0.variantID == "alpha-bf16" && $0.body.contains("4,200 bytes") })
        XCTAssertTrue(prompts[1].body.contains("is made on this Mac from the 16-bit weights each time it loads"), prompts[1].body)
        XCTAssertTrue(prompts[2].body.contains("in place of the loaded 4-bit"), prompts[2].body)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(served.isEmpty, "Cancel: no request reached the Hub")
        XCTAssertNil(c.dictation.downloadingID)
        XCTAssertTrue(c.pendingLoads.isEmpty)
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.dictation.modelsDirectory.path))

        // Without a presenter nothing downloads.
        c.confirmDownload = nil
        c.perform(alpha)
        XCTAssertNotNil(c.lastError)
        XCTAssertNil(c.dictation.downloadingID)
        // An approval for another variant opens nothing.
        c.dictation.selectedID = "alpha-bf16"
        XCTAssertFalse(c.dictation.download(approval: confirmed("something-else")))
        XCTAssertNil(c.dictation.downloadingID)
        XCTAssertTrue(served.isEmpty)
    }

    /// The real table wiring: the menu's popup presenter answers; Cancel starts nothing.
    @MainActor func testTableMenuPresentsThePopupBeforeAnyDownload() async throws {
        _ = NSApplication.shared
        var served: [String] = []
        let c = try alphaController(installed: false, served: { served.append($0) })
        let spy = ActionSpy(); c.actions = spy
        c.runtime = TableRuntime()
        let menus = ModelsMenu(controller: c)
        _ = menus.modelItem()
        var shown: [String] = []
        menus.presentDownload = {
            shown.append($0.title); return false
        }
        c.perform(alpha)
        try await waitUntil { !shown.isEmpty }
        XCTAssertEqual(shown, ["Download Alpha · 16 (BF16)?"])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(served.isEmpty); XCTAssertNil(c.dictation.downloadingID); XCTAssertTrue(spy.calls.isEmpty)
        withExtendedLifetime(menus) {}
    }

    /// Download in the popup: the row shows the downloading precision, and it loads when the download finishes.
    @MainActor func testConfirmedDownloadLoadsWhenDone() async throws {
        var served: [String] = []
        let c = try alphaController(installed: false, served: { served.append($0) })
        let spy = ActionSpy(); c.actions = spy
        c.runtime = TableRuntime()
        c.confirmDownload = { prompt, answer in answer(DownloadGate.ask(prompt) { _ in true }) }
        c.preview(alpha, "4b")
        c.perform(alpha)
        XCTAssertEqual(c.dictation.downloadingID, "alpha-bf16")
        XCTAssertEqual(c.pendingLoads["alpha"], "4b")
        c.discardPreviews() // the popup closed the menu
        XCTAssertEqual(c.selected(alpha), "4b", "the row keeps showing the precision being downloaded")
        try await waitUntil { !spy.calls.isEmpty }
        let derived = c.dictation.modelsDirectory.appendingPathComponent("alpha-4bit-local").standardizedFileURL.path
        XCTAssertEqual(spy.calls, ["load alpha 4b \(derived)"])
        XCTAssertTrue(served.contains("model.safetensors"))
        XCTAssertTrue(c.pendingLoads.isEmpty)
        XCTAssertNil(c.dictation.calibratingID, "no calibration run in front of the load")
    }

    /// The table's Get button and a Load of a cell whose source is missing, with the support directory built from a
    /// path string as `VELLA_SUPPORT_DIR` is: both install and load (they ended "download cancelled" before).
    @MainActor func testTableGetAndMissingCellLoadInstallInAPathBuiltSupportDir() async throws {
        for precision in ["BF16", "4b"] {
            try? FileManager.default.removeItem(at: root)
            root = URL(fileURLWithPath: "/tmp/vella-one-state-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let c = try alphaController(installed: false)
            let spy = ActionSpy(); c.actions = spy
            c.runtime = TableRuntime()
            c.confirmDownload = { prompt, answer in answer(DownloadGate.ask(prompt) { _ in true }) }
            if precision != "BF16" { c.preview(alpha, precision) }
            XCTAssertEqual(c.action(alpha), .get)
            c.perform(alpha)
            XCTAssertEqual(c.dictation.downloadingID, "alpha-bf16")
            try await waitUntil { !spy.calls.isEmpty || c.dictation.downloadError != nil }
            XCTAssertNil(c.dictation.downloadError, precision)
            XCTAssertNotNil(c.dictation.installed["alpha-bf16"], precision)
            XCTAssertEqual(spy.calls.count, 1, precision)
            XCTAssertTrue(spy.calls.first?.hasPrefix("load alpha \(precision) ") == true, spy.calls.description)
        }
    }

    /// Opt-in real download (`VELLA_REAL_TABLE_GET=<model id>`, e.g. whisper-large-v3): the Models table's Get, its
    /// popup answered Download, fetches the pinned weights from Hugging Face into a `/tmp` support dir built from a
    /// path as `VELLA_SUPPORT_DIR` is, and hands the table's Load to the runtime (a spy: nothing loads). The directory
    /// is removed afterwards.
    @MainActor func testRealTableGetInAPathBuiltSupportDir() async throws {
        guard let id = ProcessInfo.processInfo.environment["VELLA_REAL_TABLE_GET"] else { throw XCTSkip("Opt-in real table Get") }
        try? FileManager.default.removeItem(at: root)
        root = URL(fileURLWithPath: "/tmp/vella-real-table-get-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = try shipped()
        let f = try XCTUnwrap(c.catalog.family(id))
        let spy = ActionSpy(); c.actions = spy
        c.runtime = TableRuntime()
        c.confirmDownload = { prompt, answer in answer(DownloadGate.ask(prompt) { _ in true }) }
        XCTAssertEqual(c.action(f), .get)
        c.perform(f)
        let lib = c.library(f.mode)
        let variant = try XCTUnwrap(lib.downloadingID)
        let started = Date()
        var reported = Date.distantPast
        while lib.downloadingID != nil {
            if Date().timeIntervalSince(reported) > 15 { print(lib.message); reported = Date() }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try await waitUntil(10) { !spy.calls.isEmpty || lib.downloadError != nil }
        XCTAssertNil(lib.downloadError)
        let installed = try XCTUnwrap(lib.installed[variant])
        XCTAssertEqual(spy.calls.count, 1, spy.calls.description)
        let bytes = (FileManager.default.enumerator(at: URL(fileURLWithPath: installed.path), includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        print("table Get \(variant): \(lib.message) \(bytes) bytes in \(Int(Date().timeIntervalSince(started))) s at \(installed.path); \(spy.calls[0])")
    }

    /// A recording that starts while a confirmed download runs keeps its model: the download's load (and the new
    /// selection) waits until the dictation is idle.
    @MainActor func testConfirmedDownloadLoadsOnlyAfterARecordingThatStartedMeanwhile() async throws {
        let c = try alphaController(installed: false)
        let spy = ActionSpy(); c.actions = spy
        c.runtime = TableRuntime()
        c.confirmDownload = { prompt, answer in answer(DownloadGate.ask(prompt) { _ in true }) }
        var recording = false
        c.dictation.mayChangeModel = { !recording }
        c.preview(alpha, "4b")
        c.perform(alpha)
        XCTAssertEqual(c.dictation.downloadingID, "alpha-bf16")
        recording = true
        try await waitUntil { c.dictation.downloadingID == nil && c.dictation.installed["alpha-bf16"] != nil }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(spy.calls, [], "nothing loads or is selected during the recording")
        XCTAssertEqual(c.pendingLoads["alpha"], "4b", "the row still shows the precision that will load")
        recording = false
        try await waitUntil { !spy.calls.isEmpty }
        let derived = c.dictation.modelsDirectory.appendingPathComponent("alpha-4bit-local").standardizedFileURL.path
        XCTAssertEqual(spy.calls, ["load alpha 4b \(derived)"])
        XCTAssertTrue(c.pendingLoads.isEmpty)
    }

    // MARK: Partial downloads

    /// A failed download ends with its reason on the footer's error line and leaves no files; so does Cancel.
    @MainActor func testFailedAndCancelledDownloadsRemoveTheirPartialFiles() async throws {
        let c = try alphaController(installed: false, fail: "model.safetensors")
        let library = c.dictation
        let folder = library.modelsDirectory.appendingPathComponent("alpha-bf16")
        library.selectedID = "alpha-bf16"
        var finished: [Bool] = []
        XCTAssertTrue(library.download(approval: confirmed("alpha-bf16"), completion: { finished.append($0) }))
        try await waitUntil { !library.busy }
        XCTAssertEqual(finished, [false])
        let error = try XCTUnwrap(library.downloadError)
        XCTAssertTrue(error.hasPrefix("Alpha BF16 download failed: "), error)
        XCTAssertTrue(error.hasSuffix("Partial files removed."), error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "config.json and the partial are gone")

        // Cancel with a partial on disk (a download in progress).
        let partial = folder.appendingPathComponent(".cache/huggingface/download/x.incomplete")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: partial)
        XCTAssertTrue(library.download(approval: confirmed("alpha-bf16"), completion: { finished.append($0) }))
        library.cancel()
        XCTAssertEqual(finished, [false, false])
        XCTAssertEqual(library.downloadError, "Alpha BF16 download cancelled; partial files removed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing reappears when the task stops")
        XCTAssertEqual(library.downloadError, "Alpha BF16 download cancelled; partial files removed.")
    }

    @MainActor func testStallReasonIsNamed() {
        XCTAssertEqual(ModelLibrary.reason(URLError(.timedOut)), "it stalled (no data from Hugging Face for 2 minutes).")
        XCTAssertEqual(ModelLibrary.reason(VellaError.message("Downloaded file size mismatch: a")), "Downloaded file size mismatch: a.")
    }
}
