import XCTest
@testable import Vella
@testable import VellaCore

/// Foster, 23 Oct: "The model is gone ... I need to get it again." Fixed in e98011e (2.1.1); this keeps it fixed for every
/// published version that downloaded models.
///
/// Each published version left its own on-disk layout: one folder per download under Models/, the `.cache/huggingface`
/// marker of a finished download, a models-installed.json entry under the catalog id that version used, and a config.json
/// that selected it. For each case the test writes that layout, runs the 2.1.2 launch sequence and asserts that every
/// download is still listed, still on disk, usable and selectable without a download. Weights are placeholders, nothing
/// loads or runs, and any network request fails the test. With VELLA_UPGRADE_STORE set to a Models folder of real
/// downloads, config.json and small files are copied from them and weights are hardlinked (never copied or written).
final class PublishedVersionUpgradeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-published-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NoNetwork.requests = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Published layouts

    /// One download as a version wrote it.
    private struct Download {
        let id: String           // folder name and registry key that version used
        let quantization: String // registry `quantization`
        var registered = true    // false: a folder holding only vella-derived.json
        var manifestOnly = false // a precision made on this Mac from its source, which must also be installed
    }

    /// The config.json shape a version wrote.
    private enum ConfigShape { case v06, python08, swift20 }

    private struct Published {
        let tag: String
        let config: ConfigShape
        let defaultSelection: String // the id that version selected by default
        let downloads: [Download]
    }

    /// 0.6.0 and every 0.8.x shipped the same catalog (Resources/models.json is byte-identical across these tags) and the
    /// same Models/ layout; the Python installer and download wrote each folder with a `.cache/huggingface` marker.
    private static let zeroEightDownloads: [Download] = [
        Download(id: "Qwen3-ASR-1.7B-bf16", quantization: "BF16"),
        Download(id: "Qwen3-ASR-1.7B-8bit", quantization: "8-bit"),
        Download(id: "Qwen3-ASR-1.7B-4bit", quantization: "4-bit"),
        Download(id: "whisper-large-v3-asr-fp16", quantization: "FP16"),
        Download(id: "whisper-large-v3-8bit", quantization: "8-bit"),
        Download(id: "whisper-large-v3-asr-4bit", quantization: "4-bit"),
        Download(id: "parakeet-tdt-0.6b-v3-mlx-8bit", quantization: "8-bit"),
        Download(id: "parakeet-tdt-0.6b-v3-mlx-4bit", quantization: "4-bit"),
        Download(id: "SenseVoiceSmall", quantization: "FP32"),
        Download(id: "SenseVoiceSmall-4bit", quantization: "4-bit"),
        Download(id: "granite-4.0-1b-speech-4bit", quantization: "4-bit"),
        Download(id: "granite-4.0-1b-speech-8bit", quantization: "8-bit"),
    ]

    /// 2.0.0 to 2.1.1 shipped one catalog (22 ids, unchanged across these tags). Published roots are downloads; a
    /// precision made on this Mac from its root is a manifest-only folder or a registered folder with its weights.
    private static let twoDownloads: [Download] = [
        Download(id: "parakeet-ultra-mlx-bf16", quantization: "BF16"),
        Download(id: "parakeet-tdt-0.6b-v3-mlx-fp32", quantization: "FP32"),
        Download(id: "Qwen3-ASR-1.7B-bf16", quantization: "BF16"),
        Download(id: "Qwen3-ASR-0.6B-bf16", quantization: "BF16"),
        Download(id: "whisper-large-v3-asr-fp16", quantization: "FP16"),
        Download(id: "whisper-large-v3-turbo-asr-fp16", quantization: "FP16"),
        Download(id: "nemotron-3.5-asr-streaming-0.6b-bf16", quantization: "BF16"),
        Download(id: "nemotron-3.5-asr-streaming-0.6b-8bit", quantization: "8-bit"),
        Download(id: "Qwen3-ASR-1.7B-8bit", quantization: "8-bit", registered: false, manifestOnly: true),
    ]

    /// Catalog ids that 2.0 removed. Their files are kept on disk and never deleted by an upgrade.
    private static let removedFromCatalog: Set<String> = [
        "SenseVoiceSmall", "SenseVoiceSmall-4bit", "granite-4.0-1b-speech-4bit", "granite-4.0-1b-speech-8bit",
    ]

    private static let published: [Published] = [
        Published(tag: "0.6.0", config: .v06, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "0.8.2", config: .python08, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "0.8.4", config: .python08, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "0.8.5", config: .python08, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "0.8.6", config: .python08, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "0.8.7", config: .python08, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "0.8.8", config: .python08, defaultSelection: "parakeet-tdt-0.6b-v3-mlx-4bit", downloads: zeroEightDownloads),
        Published(tag: "2.0.0", config: .swift20, defaultSelection: "Qwen3-ASR-1.7B-bf16", downloads: twoDownloads),
        Published(tag: "2.0.1", config: .swift20, defaultSelection: "Qwen3-ASR-1.7B-bf16", downloads: twoDownloads),
        Published(tag: "2.1.0", config: .swift20, defaultSelection: "Qwen3-ASR-1.7B-bf16", downloads: twoDownloads),
        Published(tag: "2.1.1", config: .swift20, defaultSelection: "Qwen3-ASR-1.7B-bf16", downloads: twoDownloads),
    ]

    // MARK: Tests

    /// The fixtures name exactly the catalog ids that exist, plus the removed ones, so a catalog change cannot silently
    /// stop covering a published download.
    @MainActor func testFixturesMatchTheCatalog() throws {
        let c = controller(root.appendingPathComponent("catalog-check"))
        for version in Self.published {
            for download in version.downloads {
                XCTAssertEqual(c.catalog.locate(variant: download.id) == nil, Self.removedFromCatalog.contains(download.id),
                    "\(version.tag) \(download.id)")
            }
        }
    }

    /// Each download on its own, selected as that version's only model.
    @MainActor func testEveryPublishedDownloadStaysListedAndUsable() throws {
        for version in Self.published {
            for download in version.downloads where !download.manifestOnly {
                try assertUpgrade(version, downloads: [download], selected: Self.removedFromCatalog.contains(download.id) ? nil : download.id)
            }
        }
    }

    /// Everything one version had on disk at once, with that version's default selected.
    @MainActor func testEachPublishedVersionsWholeLibrarySurvivesTogether() throws {
        for version in Self.published {
            try assertUpgrade(version, downloads: version.downloads, selected: version.defaultSelection)
        }
    }

    // MARK: Upgrade

    @MainActor private func assertUpgrade(_ version: Published, downloads: [Download], selected: String?) throws {
        let label = "\(version.tag) \(selected ?? "no selection") (\(downloads.count) download\(downloads.count == 1 ? "" : "s"))"
        let support = root.appendingPathComponent("\(version.tag)-\(UUID().uuidString)", isDirectory: true)
        let catalog = controller(support).catalog
        var folders: [String: URL] = [:]
        for download in downloads {
            folders[download.id] = try seed(download, version: version, support: support, catalog: catalog)
        }
        try writeRegistry(downloads.filter(\.registered), folders: folders, catalog: catalog, support: support)
        let configURL = support.appendingPathComponent("config.json")
        try writeSelection(version, selected: selected.flatMap { folders[$0] }, support: support, catalog: catalog)
        let before = try snapshot(Array(folders.values))

        let c = controller(support)
        _ = launch(c)
        let config = try Data(contentsOf: configURL)
        XCTAssertEqual(NoNetwork.requests, [], "\(label): an upgrade downloads nothing")
        XCTAssertEqual(try snapshot(Array(folders.values)), before, "\(label): every file is still there, unchanged")

        for download in downloads where !Self.removedFromCatalog.contains(download.id) {
            try assertListed(download, folder: try XCTUnwrap(folders[download.id]), controller: c, selected: download.id == selected,
                support: support, label: label)
        }
        if let selected, let folder = folders[selected] {
            let saved = try JSONDecoder().decode(Configuration.self, from: config)
            let kept = catalog.locate(variant: selected)?.family.mode == .streaming ? saved.streamingModel : saved.model
            XCTAssertTrue(sameFiles(kept, folder.path), "\(label): selection kept")
        }

        // The launch sequence is idempotent: a second launch changes nothing.
        _ = launch(c)
        XCTAssertEqual(try Data(contentsOf: configURL), config, "\(label): second launch changes nothing")
        XCTAssertEqual(NoNetwork.requests, [], "\(label): still no network")
    }

    /// Visible: the registry keeps the entry for its folder and the Models table finds that folder. Usable: the precision
    /// loads as it is, or it is an earlier download that loads as it is. Selected: the saved selection is accepted by the
    /// runtime's refusal check, which is what a dictation reads.
    @MainActor private func assertListed(_ download: Download, folder: URL, controller c: ModelsController, selected: Bool, support: URL, label: String) throws {
        let (family, precision) = try XCTUnwrap(c.catalog.locate(variant: download.id), "\(label): \(download.id) is in the catalog")
        let library = c.library(family.mode)
        if download.registered {
            XCTAssertTrue(sameFiles(library.installed[download.id]?.path ?? "", folder.path), "\(label): \(download.id) stays in the registry")
        }
        if download.manifestOnly {
            // A precision made on this Mac is not a download, so the Models list does not name its folder; the runtime
            // resolves it from its source's files, with no download.
            let path = try precisionLoadPath(family, precision, installedPath: { library.installed[$0]?.path }, modelsDirectory: library.modelsDirectory)
            XCTAssertNotNil(path, "\(label): \(download.id) loads from its source without a download")
        } else {
            XCTAssertTrue(sameFiles(c.localPath(family, precision) ?? "", folder.path), "\(label): \(download.id) is listed in Models")
            let usable = c.available(family, precision) || c.keptLegacyCheckpoint(path: folder.path, mode: family.mode) != nil
            XCTAssertTrue(usable, "\(label): \(download.id) is usable without a download")
        }
        guard selected else { return }
        let runtime = try Runtime.isolated(root.appendingPathComponent("runtime-\(UUID().uuidString)"))
        try Data(contentsOf: support.appendingPathComponent("config.json")).write(to: runtime.configURL)
        let model = DictationController(configurationURL: runtime.configURL, monitorDefaultInput: false)
        defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: c, model: model)
        XCTAssertNil(bridge.recipeRefusal(path: folder.path, mode: family.mode), "\(label): the selected download loads without a download")
    }

    // MARK: Seeding

    /// Writes one download the way its version left it and returns its folder.
    @MainActor private func seed(_ download: Download, version: Published, support: URL, catalog: ModelCatalog) throws -> URL {
        let folder = support.appendingPathComponent("Models/\(download.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let located = catalog.locate(variant: download.id)
        if download.manifestOnly, let located, let source = located.family.downloadSource(of: located.precision) {
            let sourceFolder = support.appendingPathComponent("Models/\(source.variant.id)").path
            let bits = located.family.variants[located.precision]?.bits ?? 8
            let manifest = """
            {"bits": \(bits), "family": "\(located.family.id)", "groupSize": 64, "precision": "\(located.precision)", \
            "schema": 1, "source": "\(sourceFolder)", "sourcePrecision": "\(source.label)", "sourceVariant": "\(source.variant.id)"}
            """
            try Data(manifest.utf8).write(to: folder.appendingPathComponent(DerivedModelManifest.fileName))
            return folder
        }
        let variant = located.flatMap { $0.family.variants[$0.precision] }
        if let realStore = Self.realStore, FileManager.default.fileExists(atPath: realStore.appendingPathComponent(download.id).appendingPathComponent("config.json").path) {
            try copyRealFiles(from: realStore.appendingPathComponent(download.id), to: folder)
        } else {
            try checkpoint(variant, fallbackArchitecture: download.id.hasPrefix("granite") ? "granite" : "sensevoice", folder: folder)
        }
        // A finished download keeps Hugging Face's marker folder (both the 0.8 Python download and the 2.x Swift one).
        let marker = folder.appendingPathComponent(".cache/huggingface/download/model.safetensors.metadata")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("etag".utf8).write(to: marker)
        return folder
    }

    /// config.json and placeholder weights with the architecture and quantization the catalog gives this precision.
    private func checkpoint(_ variant: CatalogVariant?, fallbackArchitecture: String, folder: URL) throws {
        let architecture = variant?.architecture ?? fallbackArchitecture
        var config: [String: Any] = architecture == "parakeet" ? ["target": Self.nemo] : ["model_type": architecture]
        if let bits = variant?.bits {
            config["quantization"] = ["bits": bits, "group_size": variant?.groupSize ?? 64, "mode": "affine"]
        }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: folder.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        try Data("vocabulary".utf8).write(to: folder.appendingPathComponent("vocab.txt"))
    }

    private func copyRealFiles(from source: URL, to folder: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let target = folder.appendingPathComponent(file.lastPathComponent)
            if file.pathExtension == "safetensors" {
                try FileManager.default.linkItem(at: file, to: target)
            } else if (values.fileSize ?? .max) <= 5_000_000 {
                try FileManager.default.copyItem(at: file, to: target)
            }
        }
    }

    private func writeRegistry(_ downloads: [Download], folders: [String: URL], catalog: ModelCatalog, support: URL) throws {
        var registry: [String: [String: String]] = [:]
        for download in downloads {
            let name = catalog.locate(variant: download.id)?.family.name ?? download.id
            registry[download.id] = ["name": name, "path": try XCTUnwrap(folders[download.id]).path, "quantization": download.quantization, "revision": "fixture"]
        }
        try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys]).write(to: support.appendingPathComponent("models-installed.json"))
    }

    /// config.json in the shape the version wrote, selecting the folder in the mode its catalog family runs in.
    private func writeSelection(_ version: Published, selected: URL?, support: URL, catalog: ModelCatalog) throws {
        let path = selected?.path ?? ""
        let streaming = selected.flatMap { url in catalog.locate(variant: url.lastPathComponent) }?.family.mode == .streaming
        let url = support.appendingPathComponent("config.json")
        switch version.config {
        case .v06, .python08:
            var config: [String: Any] = ["executable": "/py", "model": streaming ? "" : path, "streamingModel": streaming ? path : "",
                "preferredMicrophone": "", "fallbackMicrophone": ""]
            if version.config == .python08 { config["mode"] = streaming ? "streaming" : "dictation" }
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: url)
        case .swift20:
            var configuration = Configuration(model: streaming ? "" : path)
            if streaming { configuration.streamingModel = path }
            try JSONEncoder().encode(configuration).write(to: url)
        }
    }

    /// File sizes of every file in these folders, except the derived manifests a launch may rewrite.
    private func snapshot(_ folders: [URL]) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
            while let url = files?.nextObject() as? URL {
                guard url.lastPathComponent != DerivedModelManifest.fileName, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                sizes[url.path] = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            }
        }
        return sizes
    }

    // MARK: Helpers

    private static let nemo = "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"

    /// Real downloads to seed from (a Models folder); unset, every checkpoint is seeded with placeholder files.
    private static let realStore: URL? = ProcessInfo.processInfo.environment["VELLA_UPGRADE_STORE"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    @MainActor private func controller(_ support: URL) -> ModelsController {
        let resources = ModelLibrary.resourceDirectory()
        let registry = support.appendingPathComponent("models-installed.json")
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry)
        let streaming = ModelLibrary(mode: .streaming, resources: resources, registryURL: registry)
        dictation.downloadConfiguration = NoNetwork.configuration
        streaming.downloadConfiguration = NoNetwork.configuration
        let c = ModelsController(
            dictation: dictation, streaming: streaming,
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: support.appendingPathComponent("config.json"))
        c.reloadConfig()
        return c
    }

    /// RuntimeBridge.migrateRegistry and sweepPartialDownloads, without a runtime (as UpgradeKeepsInstalledModelTests).
    @MainActor private func launch(_ c: ModelsController) -> (cleared: [String], swept: [String]) {
        _ = c.dictation.migrateRegistry(catalog: c.catalog)
        c.streaming.reload()
        _ = migrateDerivedManifests(catalog: c.catalog, modelsDirectory: c.dictation.modelsDirectory)
        let cleared = c.clearSelectionsOutsideTheCatalog()
        let keep = c.dictation.keptModelPaths.union(c.streaming.keptModelPaths).union([c.config?.model, c.config?.streamingModel].compactMap { $0 })
        return (cleared, sweepStalePartialDownloads(modelsDirectory: c.dictation.modelsDirectory, keep: keep, removeFolders: true, olderThan: 0))
    }
}

/// Fails every request: an upgrade downloads nothing.
private final class NoNetwork: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [URL] = []

    static var requests: [URL] {
        get { lock.withLock { seen } }
        set { lock.withLock { seen = newValue } }
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetwork.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { seen.append(request.url ?? URL(fileURLWithPath: "/")) }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
