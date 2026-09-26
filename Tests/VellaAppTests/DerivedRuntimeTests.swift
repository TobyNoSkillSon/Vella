import XCTest
import AppKit
import Darwin
@testable import Vella
import VellaCore

/// Runtime side of precisions made on this Mac (derived from a downloaded source): Delete of the source and memory
/// admission. Real app wiring with the fake stdio worker and an isolated support dir; no model runs, no GPU.
final class DerivedRuntimeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-derived-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "condition not reached within \(timeout) s")
    }

    /// Alpha: BF16 downloaded (the source), 4b made on this Mac from it. The derived id carries `slowexit` so the fake
    /// worker exits late, which exposes a delete that does not await the unload.
    private let alpha = ModelFamily(id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "0.6B", license: "test", native: "BF16",
        variants: ["BF16": CatalogVariant(id: "alpha-bf16", repository: "org/alpha-bf16", revision: String(repeating: "b", count: 40),
                                          downloadBytes: 1_200_000_000, architecture: "parakeet"),
                   "4b": CatalogVariant(id: "alpha-slowexit-4bit-local", architecture: "parakeet", derivedFrom: "BF16", bits: 4, groupSize: 64)])

    @MainActor private func controller() throws -> (ModelsController, source: String) {
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [alpha])).write(to: resources.appendingPathComponent("models.json"))
        let registry = root.appendingPathComponent("support/models-installed.json")
        let controller = ModelsController(dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
                                          streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
                                          benchmarksURL: root.appendingPathComponent("no-benchmarks.json"))
        let source = controller.dictation.modelsDirectory.appendingPathComponent("alpha-bf16")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        controller.dictation.installed["alpha-bf16"] = InstalledModel(path: source.path)
        try JSONEncoder().encode(controller.dictation.installed).write(to: controller.dictation.registryURL) // deleteModel re-reads it
        return (controller, source.path)
    }

    /// Fix 1: deleting the source unloads the loaded derived precision first (awaited), and on success the launch set
    /// loses the derived entry and its manifest directory is removed. A failed deletion reloads it.
    @MainActor func testDeletingASourceUnloadsItsLoadedDerivedPrecisionFirst() async throws {
        _ = NSApplication.shared
        let (controller, source) = try controller()
        let library = controller.dictation
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

        // Load the derived 4b: the worker gets its own directory, which resolves back to alpha 4b.
        controller.preview(alpha, "4b")
        XCTAssertEqual(controller.action(alpha), .load)
        controller.perform(alpha)
        let derived = library.modelsDirectory.appendingPathComponent("alpha-slowexit-4bit-local").standardizedFileURL.path
        try await waitUntil { runtime.status.models["alpha"] != nil }
        XCTAssertEqual(runtime.loadedRef("alpha")?.path, derived)
        XCTAssertEqual(runtime.loadedRef("alpha")?.precision, "4b")
        XCTAssertEqual(bridge.ref(path: derived, mode: .dictation)?.precision, "4b", "a derived directory resolves through its manifest")
        XCTAssertEqual(runtime.settings.launchSet.map(\.path), [derived])

        // Delete the BF16 source (the 4b row has no weights of its own).
        controller.preview(alpha, "BF16")
        func delete() { host.rootView.requestDelete(alpha) }

        // Failure: the derived worker was unloaded first, then comes back (manual); launch set kept.
        let firstPID = try XCTUnwrap(runtime.status.models["alpha"]?.pid)
        var aliveAtFailure: [Bool] = []
        library.trashModel = { _ in aliveAtFailure.append(kill(firstPID, 0) == 0); throw CocoaError(.fileWriteNoPermission) }
        delete()
        try await waitUntil { alerts.contains("Model was not deleted") }
        XCTAssertEqual(aliveAtFailure, [false], "the derived worker had exited before the source was touched")
        try await waitUntil { runtime.status.models["alpha"] != nil }
        XCTAssertEqual(runtime.loadedRef("alpha")?.path, derived)
        XCTAssertEqual(runtime.settings.launchSet.map(\.path), [derived])

        // Success: unloaded (awaited) before the move; source, derived manifest and launch-set entry all gone.
        let pid = try XCTUnwrap(runtime.status.models["alpha"]?.pid)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var aliveAtTrash: [Bool] = []
        library.trashModel = { item in
            aliveAtTrash.append(kill(pid, 0) == 0 || runtime.isLoaded("alpha"))
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: item, to: target); return target
        }
        delete()
        try await waitUntil { !FileManager.default.fileExists(atPath: source) && runtime.settings.launchSet.isEmpty }
        XCTAssertEqual(aliveAtTrash, [false])
        XCTAssertNil(runtime.status.models["alpha"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived), "derived manifest directory removed with its source")
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)).residency.launchSet, [])
        XCTAssertEqual(controller.action(alpha), .get)
    }

    /// Fix 2: admission for a derived precision uses its measured memory, else the estimate from a measured precision,
    /// else its source's download size + overhead; never 0.
    @MainActor func testDerivedAdmissionMemoryIsMeasuredElseEstimatedNeverZero() throws {
        let (controller, _) = try controller()
        let runtime = try Runtime.isolated(root)
        let model = Model(configurationURL: runtime.configURL); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: model)
        let path = root.appendingPathComponent("any").path

        // Nothing measured: no memory figure, but the weights are estimated at 4-bit from the source's download
        // (1.2 GB × (0.85 × 4.5/16 + 0.15)), so the admission estimate is real and never 0.
        let bare = bridge.ref(alpha, "4b", path: path)
        XCTAssertNil(bare.memoryMB)
        let weights = 1_200_000_000 * (0.85 * 4.5 / 16 + 0.15)
        XCTAssertEqual(Double(try XCTUnwrap(bare.diskBytes)), weights, accuracy: 1)
        XCTAssertEqual(memoryEstimateMB(bare), weights / 1_000_000 + 768, accuracy: 0.5)
        XCTAssertGreaterThan(memoryEstimateMB(bare), 768)

        // Source measured: the 4b estimate is scaled from it, below the source's and well above 0.
        controller.benchmarks = BenchmarkFile(models: ["alpha": FamilyBenchmark(precisions: ["BF16": PrecisionResult(wer: 5, memory_mb: 2_000)])])
        let estimated = try XCTUnwrap(bridge.ref(alpha, "4b", path: path).memoryMB)
        XCTAssertEqual(estimated, try XCTUnwrap(estimatedMemory(family: alpha, precision: "4b", benchmarks: controller.benchmarks)?.mb), accuracy: 0.001)
        XCTAssertGreaterThan(estimated, 300)
        XCTAssertLessThan(estimated, 2_000)

        // 4b measured: the measurement wins.
        controller.benchmarks.models["alpha"]?.precisions["4b"] = PrecisionResult(wer: 5.2, memory_mb: 700)
        XCTAssertEqual(bridge.ref(alpha, "4b", path: path).memoryMB, 700)
        XCTAssertEqual(bridge.ref(alpha, "BF16", path: path).memoryMB, 2_000)

        // Refusal prose: exact floats, n-bit for quantized; never "4b".
        let refusal = refusalMessage(bridge.ref(alpha, "BF16", path: path), needMB: 2_500, freeMB: 900, loaded: [])
        XCTAssertEqual(refusal, "Alpha at BF16 needs ~2.5 GB; ~0.9 GB free without swapping. Pick 4-bit or allow swap in Vella → Memory.")
    }
}
