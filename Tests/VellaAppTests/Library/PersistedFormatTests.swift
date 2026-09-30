import XCTest
@testable import VellaCLI
@testable import VellaCore
import VellaTestSupport

/// Files that released versions wrote and later versions must still read (Tests/Fixtures/persisted): config.json of
/// 0.8.x and 1.0.0, the gate's verdict files (read by `vella diagnose`), and worker-status.json (read by the app, the
/// CLI and the installer's readiness wait).
final class PersistedFormatTests: XCTestCase {
    static let fixtures = Repository.root.appendingPathComponent("Tests/Fixtures/persisted")
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    func testConfigOf08DecodesWithDefaults() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: fixture("config-0.8.json"))
        XCTAssertEqual(config.model, "/Users/example/Library/Application Support/Vella/Models/parakeet-tdt-0.6b-v3-mlx-4bit")
        XCTAssertEqual(config.mode, .dictation)
        XCTAssertEqual(config.streamingModel, "")
        XCTAssertEqual(config.preferredMicrophone, "Shure MV7i")
        XCTAssertEqual(config.residency, ResidencySettings())
        XCTAssertEqual(config.lastLoaded, [:])
        XCTAssertEqual(config.selections, [:])
    }

    func testConfigOf10DecodesEveryField() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: fixture("config-1.0.json"))
        XCTAssertEqual(config.mode, .streaming)
        XCTAssertEqual(config.selectedModel, "/Users/example/Library/Application Support/Vella/Models/nemotron-3.5-asr-streaming-0.6b-8bit")
        XCTAssertEqual(config.lastLoaded, ["parakeet-v3-ultra": "BF16", "nemotron-3.5-streaming-0.6b": "8b"])
        XCTAssertEqual(config.selections["parakeet-v3-ultra"], ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        XCTAssertEqual(config.residency.launchSet.map(\.id), ["parakeet-v3-ultra"])
        XCTAssertEqual(config.residency.launchSet.first?.precisionOptions, ["BF16", "8b", "4b"])
        XCTAssertEqual(config.residency.onDemandIdleMinutes, 15)
        // Re-encoding keeps what later launches read.
        let again = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.lastLoaded, config.lastLoaded)
        XCTAssertEqual(again.selections, config.selections)
        XCTAssertEqual(again.residency, config.residency)
        XCTAssertEqual(again.selectedModel, config.selectedModel)
    }

    func testGateVerdictFilesAsDiagnoseReadsThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vella-verdicts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try fixture("verdict-fast-partial.json").write(to: dir.appendingPathComponent("a.json"))
        try fixture("verdict-inconclusive.json").write(to: dir.appendingPathComponent("b.json"))
        try Data("not a verdict".utf8).write(to: dir.appendingPathComponent("c.selftest-42"))
        let verdicts = DiagnoseCollector.gateVerdicts(in: dir)
        XCTAssertEqual(
            verdicts,
            [
                Diagnosis.GateVerdict(
                    status: "fast", model: "parakeet-ultra-bf16", reason: "optimized without nax_gemm (word edits 3 > 1)",
                    workerVersion: "native-kernels-10", gpuFamily: "apple9", osBuild: "25G72"),
                Diagnosis.GateVerdict(
                    status: "inconclusive", model: "qwen3-asr-1.7b-4b", reason: "self-test could not complete",
                    workerVersion: "native-kernels-10", gpuFamily: "apple9", osBuild: "25G72")
            ])
    }

    func testWorkerStatusOf10() throws {
        let data = try fixture("worker-status-1.0.json")
        let status = try JSONDecoder().decode(WorkerStatus.self, from: data)
        XCTAssertEqual(status.app_pid, 4242)
        XCTAssertEqual(status.api, 1); XCTAssertEqual(status.api_port, 50438)
        XCTAssertEqual(Set(status.models.keys), ["parakeet-v3-ultra", "whisper-large-v3"])
        let ultra = try XCTUnwrap(status.models["parakeet-v3-ultra"])
        XCTAssertEqual(ultra.engine, "optimized"); XCTAssertEqual(ultra.precision, "BF16"); XCTAssertEqual(ultra.mode, .dictation)
        XCTAssertEqual(ultra.optimizations, ["decoder": true, "encoder": true, "nax_gemm": true])
        XCTAssertEqual(ultra.worker_version, "native-kernels-10")
        XCTAssertEqual(ultra.selection, ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        XCTAssertEqual(status.gpu?.family, "apple9")
        XCTAssertEqual(status.test_hooks, ["VELLA_SUPPORT_DIR": "/tmp/example"])
        XCTAssertEqual(status.launch_set, ["parakeet-v3-ultra", "whisper-large-v3"])
        // The installer's readiness wait reads the same file.
        XCTAssertEqual(InstallReadiness.evaluate(status: data) { $0 == 4242 }.isReady, true)
        XCTAssertEqual(InstallReadiness.evaluate(status: data) { _ in false }.isReady, false)
        // Round trip: what the app writes back decodes to the same value.
        XCTAssertEqual(try JSONDecoder().decode(WorkerStatus.self, from: JSONEncoder().encode(status)), status)
    }
}
