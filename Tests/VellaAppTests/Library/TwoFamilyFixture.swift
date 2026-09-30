import XCTest
import Foundation
@testable import Vella
@testable import VellaCore
import VellaTestSupport

/// Real app wiring (controller, bridge, runtime, fake stdio workers) over an isolated support directory with two
/// dictation families: Alpha (BF16 and 4b, both downloaded) and Zeta (BF16 downloaded, 4b made on this Mac from it).
@MainActor final class TwoFamilyFixture {
    let root: URL
    let runtime: Runtime
    let backend: Backend
    let stream: StreamingBackend
    let model: DictationController
    let controller: ModelsController
    let bridge: RuntimeBridge
    let source: ControllerModelSource
    let alpha: ModelFamily
    let zeta: ModelFamily
    init(_ root: URL) throws {
        self.root = root
        runtime = try Runtime.isolated(root)
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        alpha = ModelFamily(id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "1B", license: "test", native: "BF16", variants: [
            "BF16": CatalogVariant(id: "alpha-bf16", repository: "org/a", revision: String(repeating: "a", count: 40), downloadBytes: 1000, architecture: "parakeet"),
            "4b": CatalogVariant(id: "alpha-4bit", repository: "org/a4", revision: String(repeating: "b", count: 40), downloadBytes: 1000, architecture: "parakeet")])
        zeta = ModelFamily(id: "zeta", name: "Zeta", mode: .dictation, languages: ["en"], params: "1B", license: "test", native: "BF16", variants: [
            "BF16": CatalogVariant(id: "zeta-bf16", repository: "org/z", revision: String(repeating: "c", count: 40), downloadBytes: 1000, architecture: "parakeet"),
            "4b": CatalogVariant(id: "zeta-derived", architecture: "parakeet", derivedFrom: "BF16", bits: 4, groupSize: 64)])
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [alpha, zeta])).write(to: resources.appendingPathComponent("models.json"))
        let registry = runtime.support.appendingPathComponent("models-installed.json")
        var installed: [String: InstalledModel] = [:]
        for id in ["alpha-bf16", "alpha-4bit", "zeta-bf16"] {
            let path = runtime.support.appendingPathComponent("Models/" + id)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(#"{"model_type":"parakeet"}"#.utf8).write(to: path.appendingPathComponent("config.json"))
            try Data([1,2,3]).write(to: path.appendingPathComponent("model.safetensors"))
            installed[id] = InstalledModel(path: path.path)
        }
        try JSONEncoder().encode(installed).write(to: registry)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        controller = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry), configURL: runtime.configURL)
        backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        stream = StreamingBackend(helper: try FakeStreamingWorker.install(in: root), timeout: 5, runtime: runtime)
        model = DictationController(configurationURL: runtime.configURL, streamingBackend: stream, backend: backend)
        bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: model)
        source = ControllerModelSource(controller: controller, runtime: runtime)
        let configURL = runtime.configURL
        controller.dictation.currentModelPath = { try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)).model }
        controller.dictation.protectedModelPaths = { let c = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)); return [c.model, c.streamingModel] }
    }
    func config() throws -> Configuration { try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)) }
    func path(_ f: ModelFamily, _ precision: String) throws -> String {
        let source = try XCTUnwrap(f.downloadSource(of: precision))
        let local = try XCTUnwrap(controller.dictation.installed[source.variant.id])
        return f.isDerived(precision) ? try prepareDerivedModel(family: f, precision: precision, sourcePath: local.path, modelsDirectory: controller.dictation.modelsDirectory) : local.path
    }
    func load(_ f: ModelFamily, _ precision: String) async throws {
        await bridge.loadAndSelect(bridge.ref(f, precision, path: try path(f, precision)))
        XCTAssertEqual(runtime.loadedRef(f.id)?.precision, precision)
    }
    func close() { model.shutdown(); backend.shutdown(); stream.shutdown() }
}
