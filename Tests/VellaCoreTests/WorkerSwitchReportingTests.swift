import XCTest
@testable import VellaCore
import VellaTestSupport
import VellaWire

/// Every environment switch a worker reads must show up in status `test_hooks`, so a diagnostic run
/// (a forced stock path, a profiler) can never look like the shipping defaults. The lists come from the one registry
/// (VellaWire `EnvironmentSwitch`); the worker package needs MLX to build, so its reads are found in its source.
final class WorkerSwitchReportingTests: XCTestCase {
    static let root = Repository.root
    static let gate = "Worker/Sources/MLXAudioSTT/Gate/FastPathGate.swift"

    func source(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }

    func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testEveryWorkerEnvironmentSwitchIsReported() throws {
        let reported = Set(EnvironmentSwitch.names(where: \.workerReported) + [Recipe.variable])
        let prefixes = EnvironmentSwitch.prefixes(where: \.workerReported)
        XCTAssertTrue(reported.contains("VELLA_FORCE_STOCK"))

        let sources = Self.root.appendingPathComponent("Worker/Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var read = Set<String>()
        for file in files {
            read.formUnion(matches(#"environment\["(VELLA_[A-Z0-9_]+)"\]"#, in: try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertTrue(read.contains("VELLA_QWEN_PROFILE"), "parsed \(read.sorted())")
        let hidden = read.filter { name in !reported.contains(name) && !prefixes.contains { name.hasPrefix($0) } }
        XCTAssertEqual(hidden.sorted(), [], "worker switches missing from the registry's reported ones")
        let known = Set(EnvironmentSwitch.all.map(\.name))
        XCTAssertEqual(
            read.filter { name in !known.contains(name) && !prefixes.contains { name.hasPrefix($0) } }.sorted(), [],
            "worker switches missing from the registry")
    }

    /// The registry reproduces the hand-kept lists it replaced, policy for policy (VELLA_API and VELLA_UPDATE are
    /// newly reported by the app).
    func testRegistryMembership() {
        XCTAssertEqual(
            EnvironmentSwitch.names(where: \.gateKey),
            ["VELLA_PARAKEET_FAST", "VELLA_PARAKEET_NAX", "VELLA_PARAKEET_INT8", "VELLA_PARAKEET_INT4", "VELLA_TEST_TOLERANT_FAULT"])
        XCTAssertEqual(EnvironmentSwitch.prefixes(where: \.gateKey), ["VELLA_NEMO_"])
        XCTAssertEqual(
            Set(EnvironmentSwitch.names(where: \.workerReported)),
            [
                "VELLA_PARAKEET_FAST", "VELLA_PARAKEET_NAX", "VELLA_PARAKEET_INT8", "VELLA_PARAKEET_INT4", "VELLA_TEST_TOLERANT_FAULT",
                "VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK", "VELLA_WORKER_DATA_DIR", "VELLA_SUPPORT_DIR", "VELLA_KERNEL_DEBUG_LOG",
                "VELLA_KERNEL_DIAGNOSTIC_COMPONENT", "VELLA_KERNEL_DIAGNOSTIC_CLIP", "VELLA_PARAKEET_PROFILE", "VELLA_QWEN_PROFILE",
                "VELLA_WHISPER_PROFILE", "VELLA_STREAM_PROFILE", "VELLA_STUB_MODELS", "VELLA_TEST_LOAD_FAULT", "VELLA_TEST_OPTIMIZED_FAULT",
                "VELLA_TEST_STOCK_FAULT", "VELLA_TEST_STUB_FOOTPRINT_MB", "VELLA_TEST_SELFTEST_FAULT", "VELLA_TEST_DECODER_NONFINITE",
                "VELLA_TEST_ENCODER_NONFINITE", "VELLA_MLX_DEVICE", "VELLA_SELFTEST_RESULT", "VELLA_WHISPER_SEED",
                "VELLA_DICTATION_KEEP_CACHE"
            ])
        XCTAssertEqual(
            Set(EnvironmentSwitch.names(where: \.strippedFromSelfTestChild)),
            [
                "VELLA_KERNEL_DIAGNOSTIC_COMPONENT", "VELLA_KERNEL_DIAGNOSTIC_CLIP", "VELLA_TEST_DECODER_NONFINITE",
                "VELLA_TEST_ENCODER_NONFINITE", "VELLA_SELFTEST_RESULT"
            ])
        XCTAssertEqual(
            Set(runtimeTestHookNames),
            [
                "VELLA_TEST_MEMORY_FILE", "VELLA_TEST_VM_STATS", "VELLA_TEST_MINUTE_SECONDS", "VELLA_SUPPORT_DIR",
                "VELLA_STUB_MODELS", "VELLA_TEST_LOAD_FAULT", "VELLA_TEST_OPTIMIZED_FAULT", "VELLA_TEST_STOCK_FAULT",
                "VELLA_TEST_STUB_FOOTPRINT_MB", "VELLA_TEST_SELFTEST_FAULT", "VELLA_FORCE_STOCK", "VELLA_PARAKEET_FORCE_STOCK",
                "VELLA_API", "VELLA_UPDATE"
            ])
        XCTAssertEqual(
            activeTestHooks(["VELLA_API": "0", "VELLA_UPDATE": "0", "VELLA_RECIPE": "standard", "HOME": "/x"]),
            ["VELLA_API": "0", "VELLA_UPDATE": "0"])
        XCTAssertEqual(Set(EnvironmentSwitch.all.map(\.name)).count, EnvironmentSwitch.all.count, "one entry per name")
    }

    /// `vella diagnose` counts gate verdicts of the bundled reference's gate version when no model is loaded, so the
    /// reference must name the version the workers write.
    func testDiagnoseReferenceNamesTheWorkersGateVersion() throws {
        let gate = try source(Self.gate)
        let version = try XCTUnwrap(matches(#"static let version = "([a-z0-9-]+)""#, in: gate).first)
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/diagnose-reference.json"))
        XCTAssertEqual(DiagnoseReference.decode(data)?.gate_version, version)
    }
}
