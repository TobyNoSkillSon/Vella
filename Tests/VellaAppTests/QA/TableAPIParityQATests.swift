import XCTest
@testable import Vella
@testable import VellaCLI
import VellaCore

/// Parity QA: for every dictation family of the shipped catalog and every tier × Standard/Optimized × Exact/Fast
/// recorded in config.json (what a table Load/Reload writes), the table's row, the API's /v1/models object and the
/// `vella models` line must name the same selection. Writes a matrix to VELLA_QA_OUT when set.
@MainActor final class TableAPIParityQATests: XCTestCase {
    func testTableAPIAndCLIReportTheSameSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-qa-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Runtime.isolated(root)
        let resources = ModelLibrary.resourceDirectory()
        let registry = runtime.support.appendingPathComponent("models-installed.json")
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry, calibration: CalibrationStore(directory: root.appendingPathComponent("Cal"), resources: resources))
        let controller = ModelsController(dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry), configURL: runtime.configURL)
        // Every family's downloaded weights (its 16-bit source), so every tier is available (8 and 4 are made here).
        // Every family's downloaded weights (published and stored-conversion variants; 8 and 4 are made here).
        for family in controller.families(.dictation) {
            for variant in family.variants.values where !variant.isDerived || variant.isStored {
                dictation.installed[variant.id] = InstalledModel(path: root.appendingPathComponent(variant.id).path)
            }
        }
        let source = ControllerModelSource(controller: controller, runtime: runtime)
        let service = APIService(
            transcriber: APITranscriber(backend: Backend(runtime: runtime), root: root.appendingPathComponent("jobs")), models: source,
            scratch: root.appendingPathComponent("files"))
        var rows: [String] = ["family\tstored\ttable(selectable)\ttable row\tAPI selection\tvella models"]
        var mismatches: [String] = []
        for family in controller.families(.dictation) {
            for tier in ModelTier.allCases {
                guard let precision = precisionLabel(family, tier: tier) else { continue }
                for path in EnginePath.allCases {
                    for mode in OptimizedMode.allCases {
                        let stored = ModelSelection(tier: tier, path: path, mode: mode)
                        var config = Configuration(model: "")
                        config.lastLoaded[family.id] = precision; config.selections[family.id] = stored
                        try JSONEncoder().encode(config).write(to: runtime.configURL)
                        controller.reloadConfig()
                        let selectable = controller.isPresent(family, stored) && controller.measured(family, stored)
                        let table = controller.committedSelection(family)
                        guard let api = source.models().first(where: { $0.id == family.id }) else {
                            mismatches.append("\(family.id) \(stored): not listed by /v1/models"); continue
                        }
                        let object = service.modelObject(api)
                        let line = VellaCLI.modelLine(object)
                        let apiSelection = VellaCLI.selectionFrom(object["selection"])
                        func text(_ s: ModelSelection?) -> String { s.map { "\($0.tier.rawValue) \(recipeLabel($0))" } ?? "nil" }
                        rows.append("\(family.id)\t\(text(stored))\t\(selectable)\t\(text(table))\t\(text(apiSelection))\t\(line)")
                        if apiSelection != table || !line.contains(recipeLabel(table)) {
                            mismatches.append("\(family.id) stored \(text(stored)) (table-selectable \(selectable)): table \(text(table)), API \(text(apiSelection)), CLI \"\(line)\"")
                        }
                    }
                }
            }
        }
        if let out = ProcessInfo.processInfo.environment["VELLA_QA_OUT"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
            try (rows + ["", "mismatches:"] + mismatches).joined(separator: "\n").write(
                to: URL(fileURLWithPath: out).appendingPathComponent("table-api-parity.tsv"), atomically: true, encoding: .utf8)
        }
        print("QA parity mismatches (\(mismatches.count)):\n" + mismatches.joined(separator: "\n"))
        // Selections the table can make itself must be reported identically; the others are listed for the notes.
        let reachable = mismatches.filter { $0.contains("(table-selectable true)") }
        XCTAssertEqual(reachable, [], "a selection the table makes is reported differently by the API/CLI")
    }
}
