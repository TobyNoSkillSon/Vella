import XCTest
@testable import Vella
@testable import VellaCLI
import VellaCore

/// Parity QA: for every dictation family of the shipped catalog and every tier × Standard/Optimized × Exact/Fast
/// recorded in config.json (what a table Load/Reload writes), the table's row, the API's /v1/models object, the
/// `vella models` line and what a dictation of the recorded precision's files actually loads
/// (`RuntimeBridge.ref(path:mode:)`) must name the same selection and precision, including recorded selections the
/// table would refuse (they resolve to the table's cell everywhere). Each cell is checked twice: with another family
/// as the dictation model, and as the current dictation model (config `model` = those files). Writes a matrix to
/// VELLA_QA_OUT when set.
@MainActor final class TableAPIParityQATests: XCTestCase {
    func testTableAPIAndCLIReportTheSameSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-qa-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Runtime.isolated(root)
        let resources = ModelLibrary.resourceDirectory()
        let registry = runtime.support.appendingPathComponent("models-installed.json")
        let dictation = ModelLibrary(
            mode: .dictation, resources: resources, registryURL: registry, calibration: CalibrationStore(directory: root.appendingPathComponent("Cal"), resources: resources))
        let controller = ModelsController(
            dictation: dictation, streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry), configURL: runtime.configURL)
        // Every family's downloaded weights (published and stored-conversion variants; 8 and 4 are made here), each a
        // folder with a config.json so a precision made on this Mac can record its source.
        for family in controller.families(.dictation) {
            for variant in family.variants.values where !variant.isDerived || variant.isStored {
                let folder = root.appendingPathComponent(variant.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
                dictation.installed[variant.id] = InstalledModel(path: folder.path)
            }
        }
        /// The files a precision loads from: its registered download, else the manifest folder of a precision made here.
        func files(_ family: ModelFamily, _ precision: String) throws -> String? {
            if let installed = controller.installed(family, precision)?.path { return installed }
            guard family.variants[precision]?.isDerived == true, let origin = family.downloadSource(of: precision),
                let local = dictation.installed[origin.variant.id]
            else { return nil }
            return try prepareDerivedModel(family: family, precision: precision, sourcePath: local.path, modelsDirectory: dictation.modelsDirectory)
        }
        let bridge = RuntimeBridge(runtime: runtime)
        bridge.attach(controller: controller, model: DictationController(configurationURL: runtime.configURL, backend: Backend(runtime: runtime)))
        let source = ControllerModelSource(controller: controller, runtime: runtime)
        let service = APIService(
            transcriber: APITranscriber(backend: Backend(runtime: runtime), root: root.appendingPathComponent("jobs")), models: source,
            scratch: root.appendingPathComponent("files"))
        var rows: [String] = [
            "family\tstored\tcurrent\ttable(selectable)\ttable row\tAPI selection\tloads (bridge)\tvella models"
        ]
        var mismatches: [String] = []
        var cells = 0
        for family in controller.families(.dictation) {
            for tier in ModelTier.allCases {
                guard let precision = precisionLabel(family, tier: tier), let recordedFiles = try files(family, precision) else { continue }
                for path in EnginePath.allCases {
                    for mode in OptimizedMode.allCases {
                        for current in [false, true] {
                            let stored = ModelSelection(tier: tier, path: path, mode: mode)
                            var config = Configuration(model: current ? recordedFiles : "")
                            config.lastLoaded[family.id] = precision; config.selections[family.id] = stored
                            try JSONEncoder().encode(config).write(to: runtime.configURL)
                            controller.reloadConfig()
                            cells += 1
                            let selectable = controller.isPresent(family, stored) && controller.measured(family, stored)
                            let table = controller.committedSelection(family)
                            let tablePrecision = controller.committed(family)
                            let cell = "\(family.id) stored \(precision) \(text(stored))\(current ? " (current)" : "")"
                            guard let api = source.models().first(where: { $0.id == family.id }) else {
                                mismatches.append("\(cell): not listed by /v1/models"); continue
                            }
                            guard let loads = bridge.ref(path: recordedFiles, mode: .dictation) else {
                                mismatches.append("\(cell): the recorded files resolve to nothing"); continue
                            }
                            let object = service.modelObject(api)
                            let line = VellaCLI.modelLine(object)
                            let apiSelection = VellaCLI.selectionFrom(object["selection"])
                            rows.append(
                                "\(family.id)\t\(precision) \(text(stored))\t\(current)\t\(selectable)\t\(tablePrecision) \(text(table))"
                                    + "\t\(api.precision) \(text(apiSelection))\t\(loads.precision) \(text(loads.selection))\t\(line)")
                            if apiSelection != table || api.precision != tablePrecision || loads.selection != table
                                || loads.precision != tablePrecision || !line.contains(recipeLabel(table)) || api.current != current
                            {
                                mismatches.append(
                                    "\(cell) (table-selectable \(selectable)): table \(tablePrecision) \(text(table)), "
                                        + "API \(api.precision) \(text(apiSelection)) current \(api.current), "
                                        + "loads \(loads.precision) \(text(loads.selection)), CLI \"\(line)\"")
                            }
                        }
                    }
                }
            }
        }
        // Every family × tier × path × mode, twice.
        XCTAssertGreaterThan(cells, 0)
        if let out = ProcessInfo.processInfo.environment["VELLA_QA_OUT"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
            try (rows + ["", "mismatches:"] + mismatches).joined(separator: "\n").write(
                to: URL(fileURLWithPath: out).appendingPathComponent("table-api-parity.tsv"), atomically: true, encoding: .utf8)
        }
        print("QA parity mismatches (\(mismatches.count)):\n" + mismatches.joined(separator: "\n"))
        // One rule (SelectionRules): every recorded selection, selectable in the table or not, is reported alike.
        XCTAssertEqual(mismatches, [], "the table, the API/CLI and what loads disagree on what a recorded selection runs")
    }

    private func text(_ s: ModelSelection?) -> String { s.map { "\($0.tier.rawValue) \(recipeLabel($0))" } ?? "nil" }
}
