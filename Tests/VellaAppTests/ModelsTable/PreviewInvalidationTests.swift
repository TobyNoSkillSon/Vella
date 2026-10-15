import XCTest
import Combine
import VellaCore
@testable import Vella

@MainActor final class PreviewInvalidationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-invalidation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Configuration(model: "")).write(to: root.appendingPathComponent("config.json"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func controller() -> ModelsController {
        ModelsController(dictation: ModelLibrary(mode: .dictation, registryURL: root.appendingPathComponent("models-installed.json")), configURL: root.appendingPathComponent("config.json"))
    }

    func testAdviceInvalidatesForHardwareBenchmarksAndVerdicts() throws {
        let c = controller(), family = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        var calculations = 0
        c.observeWork = { if $0 == "adviceCalculation" { calculations += 1 } }
        c.gpu = GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)
        XCTAssertEqual(c.advice(family, mode: .fast).hardware[.t8], true)
        _ = c.advice(family, mode: .fast)
        XCTAssertEqual(calculations, 1)
        c.gpu = GPUCapability(appleFamily: 9, architecture: "applegpu_g16s", osMajor: 26, osMinor: 6)
        XCTAssertEqual(c.advice(family, mode: .fast).hardware[.t8], false)
        XCTAssertEqual(calculations, 2)
        c.gpu = GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)
        c.previewVerdicts([QualificationVerdict(status: "stock", model: family.variants["8b"]?.id)])
        XCTAssertEqual(c.advice(family, mode: .fast).hardware[.t8], false)
        c.benchmarks.figuresPending = true
        XCTAssertEqual(c.advice(family, mode: .fast), PrecisionAdvice())
    }

    func testVerdictsRefreshAfterWorkerChangeButNotConfigOrPreviewChanges() async throws {
        let c = controller(), family = try XCTUnwrap(c.catalog.family("parakeet-v3"))
        let directory = try XCTUnwrap(c.verdictDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("verdict.json")
        try JSONSerialization.data(withJSONObject: ["status": "stock", "model": family.variants["8b"]!.id]).write(to: file)
        var scans = 0, scheduled = 0
        c.observeWork = {
            if $0 == "verdictScan" { scans += 1 }
            if $0 == "verdictScanScheduled" { scheduled += 1 }
        }
        c.reloadConfig(); c.reloadConfig()
        XCTAssertTrue(c.verdicts.isEmpty, "config reload uses the snapshot until the worker changes")
        c.runtime = TableRuntime(loaded: [family.id: LoadedFamily(precision: "BF16", engine: "optimized")])
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while c.verdicts.isEmpty && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(c.verdicts.first?.status, "stock")
        XCTAssertEqual(scheduled, 1)
        c.runtime = c.runtime
        c.select(family, tier: .t8)
        c.reloadConfig()
        XCTAssertEqual(scans, 0)
        XCTAssertEqual(scheduled, 1, "unchanged worker reports and preview clicks do not scan")
        c.gpu = GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)
        XCTAssertEqual(c.advice(family, mode: .fast).hardware[.t8], false)
    }
}
