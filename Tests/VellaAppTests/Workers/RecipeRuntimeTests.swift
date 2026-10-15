import XCTest
import AppKit
@testable import Vella
import VellaCore
import VellaTestSupport

/// The selection reaches the worker at load (lab/notes/models-table-ROUND.md): every worker is launched with
/// `VELLA_RECIPE` = the selection's recipe; another recipe on the same files is a reload (a new worker); a successful
/// Load records the selection in config.json; the status reports it. Fake stdio worker, isolated support dir, no GPU.
final class RecipeRuntimeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-recipe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { unsetenv("FAKE_RECIPE_LOG"); try? FileManager.default.removeItem(at: root) }

    private let alpha = ModelFamily(
        id: "alpha", name: "Alpha", mode: .dictation, languages: ["en"], params: "0.6B", license: "test", native: "BF16",
        variants: [
            "BF16": CatalogVariant(
                id: "alpha-bf16", repository: "org/alpha-bf16", revision: String(repeating: "b", count: 40),
                downloadBytes: 1_200_000_000, architecture: "parakeet")
        ], tiersOffered: ["16"])

    @MainActor func testSelectionTravelsToTheWorkerAndChangesReloadIt() async throws {
        _ = NSApplication.shared
        let log = root.appendingPathComponent("recipes.log")
        setenv("FAKE_RECIPE_LOG", log.path, 1)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [alpha])).write(to: resources.appendingPathComponent("models.json"))
        let registry = root.appendingPathComponent("support/models-installed.json")
        let controller = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: root.appendingPathComponent("no-benchmarks.json"))
        let source = controller.dictation.modelsDirectory.appendingPathComponent("alpha-bf16")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        controller.dictation.installed["alpha-bf16"] = InstalledModel(path: source.path)

        let runtime = try Runtime.isolated(root)
        try JSONEncoder().encode(Configuration(model: "")).write(to: runtime.configURL)
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        runtime.dictation = backend
        defer { backend.shutdown() }
        let model = DictationController(configurationURL: runtime.configURL); defer { model.shutdown() }
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: model)
        func recipes() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func config() throws -> Configuration { try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)) }

        // A Load carrying 2.0's Standard 16 · Exact: the worker is asked for the optimized request (never `standard`; its
        // gate falls back to stock by itself); config.json records the request.
        let standard = ModelSelection(tier: .t16, path: .standard, mode: .exact)
        let exact = ModelSelection(tier: .t16, mode: .exact)
        bridge.load(family: alpha, precision: "BF16", variant: alpha.variants["BF16"]!, path: source.path, selection: standard)
        try await waitUntil { runtime.status.models["alpha"]?.selection == exact && (try? self.selections(runtime)) == ["alpha": exact] }
        XCTAssertEqual(recipes(), ["optimized_exact"])
        let firstPID = runtime.status.models["alpha"]?.pid
        XCTAssertEqual(controller.runtime?.loaded["alpha"]?.selection, exact, "the table sees what the worker was launched with")

        // Same files, 16 · Fast: a new worker with the new recipe.
        let fast = ModelSelection(tier: .t16, mode: .fast)
        bridge.reload(family: alpha, precision: "BF16", variant: alpha.variants["BF16"]!, path: source.path, selection: fast)
        try await waitUntil { runtime.status.models["alpha"]?.selection == fast }
        XCTAssertEqual(recipes(), ["optimized_exact", "optimized_fast"])
        XCTAssertNotEqual(runtime.status.models["alpha"]?.pid, firstPID)
        XCTAssertEqual(try config().selections["alpha"], fast)

        // The same selection again, also as 2.0's Standard spelling of it: nothing reloads.
        bridge.load(family: alpha, precision: "BF16", variant: alpha.variants["BF16"]!, path: source.path, selection: fast)
        bridge.load(family: alpha, precision: "BF16", variant: alpha.variants["BF16"]!, path: source.path, selection: ModelSelection(tier: .t16, path: .standard, mode: .fast))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recipes(), ["optimized_exact", "optimized_fast"])

        // An on-demand load (a dictation of the mode's model) runs the recorded selection.
        await runtime.unload("alpha")
        try await waitUntil { runtime.status.models["alpha"] == nil }
        let ref = runtime.resolve(source.path, mode: .dictation)
        XCTAssertEqual(ref.selection, fast)
        XCTAssertEqual(ref.recipe, .optimized_fast)
    }

    @MainActor private func selections(_ runtime: Runtime) throws -> [String: ModelSelection] {
        try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL)).selections
    }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "condition not reached within \(timeout) s")
    }

    func testDefaultSelectionRule() {
        let fast = ModelSelection(tier: .t8, mode: .fast)
        XCTAssertEqual(defaultSelection(recorded: nil, precision: "BF16"), .fallback, "never loaded: 16 · Fast")
        XCTAssertEqual(ModelSelection.fallback, ModelSelection(tier: .t16, path: .optimized, mode: .fast), "fresh installs never land on Standard")
        // A recorded 2.0 Standard choice is the optimized request at its tier and switch position.
        XCTAssertEqual(
            defaultSelection(recorded: ModelSelection(tier: .t16, path: .standard, mode: .exact), precision: "4b"), ModelSelection(tier: .t4, mode: .exact))
        XCTAssertEqual(workerRecipe(ModelSelection(tier: .t16, path: .standard, mode: .exact)), .optimized_exact, "VELLA_RECIPE is never standard")
        XCTAssertEqual(workerRecipe(ModelSelection(tier: .t16, path: .standard, mode: .fast)), .optimized_fast)
        XCTAssertEqual(defaultSelection(recorded: nil, precision: "8b"), fast, "used before selections: what it ran")
        XCTAssertEqual(
            defaultSelection(recorded: ModelSelection(tier: .t16, path: .optimized, mode: .exact), precision: "8b"),
            ModelSelection(tier: .t8, mode: .exact), "the recorded switch at the loaded tier")
        XCTAssertEqual(workerRecipe(nil), .optimized_fast)
        XCTAssertEqual(effectiveSelection(ModelSelection(tier: .t16, path: .optimized, mode: .fast), engine: "mlx").segmentKey, .standard)
        XCTAssertEqual(effectiveSelection(ModelSelection(tier: .t16, path: .optimized, mode: .fast), engine: "optimized").segmentKey, .optimized_fast)
        XCTAssertEqual(recipeLabel(ModelSelection(tier: .t4, path: .optimized, mode: .exact)), "Optimized Exact")
    }
}
