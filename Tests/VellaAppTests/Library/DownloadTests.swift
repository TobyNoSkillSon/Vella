import XCTest
import AppKit
import CryptoKit
import VellaCore
@testable import Vella

private final class HubStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DownloadTests: XCTestCase {
    private func fixture() throws -> (URL, ModelRecommendation, URLSessionConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-native-download-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ModelRecommendation(
            id: "fixture", name: "Fixture", quantization: "4-bit", repository: "org/repo",
            revision: String(repeating: "a", count: 40), downloadBytes: 100, architecture: "parakeet", license: "test", recommendation: "test")
        let family = ModelFamily(
            id: "fixture", name: model.name, mode: .dictation, languages: ["en"], params: "0.6B", license: model.license,
            native: "4b",
            variants: [
                "4b": CatalogVariant(
                    id: model.id, repository: model.repository, revision: model.revision,
                    downloadBytes: model.downloadBytes, architecture: model.architecture)
            ],
            notes: model.recommendation)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [family])).write(to: root.appendingPathComponent("models.json"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HubStub.self]
        return (root, model, configuration)
    }
    private func configure(_ model: ModelRecommendation, files: [String: Data], wrongHash: Bool = false, codeFile: Bool = false) {
        let siblings: [[String: Any]] =
            files.map { name, data in
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return ["rfilename": name, "size": data.count, "lfs": ["sha256": wrongHash && name == "model.safetensors" ? String(repeating: "f", count: 64) : hash]]
            } + (codeFile ? [["rfilename": "evil.py", "size": 4, "blob_id": String(repeating: "a", count: 40)]] : [])
        HubStub.handler = { request in
            if request.url!.path.contains("/api/models/") {
                return (200, [:], try JSONSerialization.data(withJSONObject: ["sha": model.revision, "siblings": siblings]))
            }
            let name = request.url!.lastPathComponent
            guard let data = files[name] else { throw NSError(domain: "Unexpected file", code: 1) }
            if let range = request.value(forHTTPHeaderField: "Range") {
                let offset = Int(range.dropFirst(6).dropLast())!
                return (206, ["Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], data.subdata(in: offset..<data.count))
            }
            return (200, [:], data)
        }
    }
    private var contents: [String: Data] {
        [
            "config.json": Data(#"{"target":"nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel","quantization":{"bits":4}}"#.utf8),
            "model.safetensors": Data(repeating: 42, count: 4096)
        ]
    }
    @MainActor func testNativeDownloadRegistersOnlyVerifiedFilesAndResumes() async throws {
        let (root, model, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        configure(model, files: contents)
        let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
        library.downloadConfiguration = config; library.downloadBaseURL = URL(string: "https://huggingface.co")!
        library.selectedID = model.id
        let folder = library.modelsDirectory.appendingPathComponent(model.id)
        let metadata = folder.appendingPathComponent(".cache/huggingface/download/model.safetensors.metadata")
        let hash = Data(Insecure.SHA1.hash(data: Data(metadata.lastPathComponent.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_")
        let etag = SHA256.hash(data: contents["model.safetensors"]!).map { String(format: "%02x", $0) }.joined()
        let partial = metadata.deletingLastPathComponent().appendingPathComponent("\(hash).\(etag).incomplete")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents["model.safetensors"]!.prefix(1024).write(to: partial)
        var resumed = false
        let prior = HubStub.handler!
        HubStub.handler = { request in
            if request.url!.lastPathComponent == "model.safetensors" { resumed = request.value(forHTTPHeaderField: "Range") == "bytes=1024-" }
            return try prior(request)
        }
        library.download(approval: confirmed(model.id))
        for _ in 0..<300 where library.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(resumed)
        XCTAssertEqual(library.progress, 1)
        XCTAssertEqual(library.installed[model.id]?.revision, model.revision)
        XCTAssertEqual(library.installed[model.id]?.path, folder.path)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("model.safetensors")), contents["model.safetensors"])
    }
    @MainActor func testBadHashAndRemoteCodeNeverRegister() async throws {
        for (badHash, code) in [(true, false), (false, true)] {
            let (root, model, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            configure(model, files: contents, wrongHash: badHash, codeFile: code)
            let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
            if code {
                let folder = library.modelsDirectory.appendingPathComponent(model.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "print('no')".write(to: folder.appendingPathComponent("evil.py"), atomically: true, encoding: .utf8)
            }
            library.downloadConfiguration = config; library.selectedID = model.id; library.download(approval: confirmed(model.id))
            for _ in 0..<300 where library.busy { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertNotNil(library.downloadError)
            XCTAssertTrue(library.downloadError?.contains("download failed:") == true, library.downloadError ?? "")
            XCTAssertTrue(library.installed.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.modelsDirectory.appendingPathComponent(model.id).path), "a failed download leaves no files")
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.registryURL.path))
        }
    }
    @MainActor func testDownloadCannotInterruptDictation() throws {
        let (root, model, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
        library.selectedID = model.id; library.mayChangeModel = { false }
        XCTAssertFalse(library.download(approval: confirmed(model.id)))
        XCTAssertFalse(library.busy)
        XCTAssertNotNil(library.downloadError, "a refused download says why")
    }
    @MainActor func testEveryRefusalReportsCompletionOnce() throws {
        let (root, model, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
        library.selectedID = model.id
        for reason in ["unconfirmed", "busy", "recording"] {
            library.busy = reason == "busy"
            library.mayChangeModel = { reason != "recording" }
            var completions: [Bool] = []
            let started = library.download(approval: confirmed(reason == "unconfirmed" ? "other" : model.id)) { completions.append($0) }
            XCTAssertFalse(started)
            XCTAssertEqual(completions, [false], reason)
        }
    }

    @MainActor func testMismatchedDownloadIDAndShutdownReportFailureOnce() async throws {
        for shutdown in [false, true] {
            let (root, model, config) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            configure(model, files: contents)
            let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
            library.downloadConfiguration = config; library.selectedID = model.id
            var completions: [Bool] = []
            XCTAssertTrue(library.download(approval: confirmed(model.id), calibrate: false) { completions.append($0) })
            if shutdown { library.shutdown() } else { library.downloadingID = "changed" }
            for _ in 0..<300 where completions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(completions, [false])
            XCTAssertFalse(library.busy)
            XCTAssertNil(library.downloadingID)
            XCTAssertNil(library.installed[model.id])
            library.cancel()
            XCTAssertEqual(completions, [false], "Cancellation must not complete twice")
        }
    }

    /// The downloader itself keeps a pinned partial (resume within one download); the app's library removes it when
    /// the download is cancelled (testLibraryCancelAndFailureRemovePartialFiles).
    func testCancellationLeavesPinnedPartialForResume() async throws {
        let (root, model, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        configure(model, files: contents)
        var downloader: NativeModelDownload!
        downloader = NativeModelDownload(configuration: config, catalogURL: root.appendingPathComponent("models.json")) { _, done, _ in
            if let done, done > 0 { downloader.cancel() }
        }
        do {
            _ = try await downloader.download(model, modelsDirectory: root.appendingPathComponent("Models"))
            XCTFail("A cancelled transfer must never complete")
        } catch is CancellationError {}
        let folder = root.appendingPathComponent("Models/fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path))
        let cache = folder.appendingPathComponent(".cache/huggingface/download")
        let partials = (try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.filter { $0.hasSuffix(".incomplete") } ?? []
        XCTAssertFalse(partials.isEmpty)
    }
    func testMetadataPinMismatchCannotCreateWeights() async throws {
        let (root, model, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        configure(model, files: contents)
        let existing = HubStub.handler!
        HubStub.handler = { request in
            if request.url!.path.contains("/api/models/") {
                return (200, [:], try JSONSerialization.data(withJSONObject: ["sha": String(repeating: "b", count: 40), "siblings": []]))
            }
            return try existing(request)
        }
        let client = NativeModelDownload(configuration: config, catalogURL: root.appendingPathComponent("models.json")) { _, _, _ in }
        do {
            _ = try await client.download(model, modelsDirectory: root.appendingPathComponent("Models"))
            XCTFail("Mismatched revision must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("pinned revision")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/fixture/model.safetensors").path))
    }
    @MainActor func testRealPinnedParakeetInIsolatedDirectory() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["VELLA_REAL_MODEL_DOWNLOAD"] else { throw XCTSkip("Opt-in real pinned download") }
        let root = URL(fileURLWithPath: rootPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resource = ModelLibrary.resourceDirectory()
        let catalog = try catalogVariants(contentsOf: resource.appendingPathComponent("models.json"))
        let model = try XCTUnwrap(catalog.first { $0.id == "parakeet-tdt-0.6b-v3-mlx-4bit" })
        let client = NativeModelDownload(catalogURL: resource.appendingPathComponent("models.json")) { text, done, total in
            if let done, let total { print("\(text) \(done)/\(total)") }
        }
        let folder = try await client.download(model, modelsDirectory: root.appendingPathComponent("Models"))
        let installed = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Vella/Models").appendingPathComponent(model.id)
        for file in ["config.json", "model.safetensors", "README.md", "tokenizer.model", "vocab.txt"] {
            let a = try Data(contentsOf: folder.appendingPathComponent(file), options: [.mappedIfSafe])
            let b = try Data(contentsOf: installed.appendingPathComponent(file), options: [.mappedIfSafe])
            XCTAssertEqual(SHA256.hash(data: a), SHA256.hash(data: b), file)
        }
        let existing = try JSONDecoder().decode(
            [String: InstalledModel].self,
            from: Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Vella/models-installed.json")))
        let record = try XCTUnwrap(existing[model.id])
        XCTAssertEqual(record.revision, model.revision); XCTAssertEqual(record.name, model.name); XCTAssertEqual(record.quantization, model.quantization)
        XCTAssertEqual(record.path, installed.path)
        print("Pinned model byte hashes and registry fields match; isolated path: \(folder.path)")
    }
}
