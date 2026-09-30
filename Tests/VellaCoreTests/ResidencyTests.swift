import XCTest
import Foundation
@testable import VellaCore

/// CHECKLIST 9 with a fake memory probe: admission, eviction order, refusals; CHECKLIST 8 settings and launch set.
final class ResidencyTests: XCTestCase {
    private func ref(_ id: String, _ precision: String = "8b", memory: Double = 1000) -> ModelRef {
        ModelRef(id: id, precision: precision, path: "/m/\(id)", name: id, memoryMB: memory, precisionOptions: ["4b", "8b", "BF16"])
    }
    private func info(_ id: String, _ residency: ResidencyClass, used: Double, mb: Double = 1000) -> LoadedModelInfo {
        LoadedModelInfo(id: id, residency: residency, lastUsed: used, reclaimMB: mb)
    }

    func testFits() {
        XCTAssertEqual(planAdmission(ref("a"), loaded: [], rawAvailableMB: 1512, allowSwap: false), .admit(evict: [], needMB: 1512, freeMB: 1512))
    }
    func testFitsAfterEvictingLRUOnDemandFirst() {
        let loaded = [info("manual-old", .manual, used: 1), info("od-new", .onDemand, used: 9), info("od-old", .onDemand, used: 5)]
        XCTAssertEqual(evictionOrder(loaded).map(\.id), ["od-old", "od-new", "manual-old"])
        guard case .admit(let evict, _, _) = planAdmission(ref("x"), loaded: loaded, rawAvailableMB: 600, allowSwap: false) else { return XCTFail() }
        XCTAssertEqual(evict, ["od-old"])
        guard case .admit(let two, _, _) = planAdmission(ref("x"), loaded: loaded, rawAvailableMB: -400, allowSwap: false) else { return XCTFail() }
        XCTAssertEqual(two, ["od-old", "od-new"], "a deficit is paid off before evictions help")
    }
    func testCannotFitUnloadsNothingAndNamesNeedFreeAndWaysOut() {
        let loaded = [info("qwen", .onDemand, used: 1), info("whisper", .manual, used: 2)]
        let decision = planAdmission(ref("parakeet", "BF16"), loaded: loaded, rawAvailableMB: -700, allowSwap: false)
        XCTAssertEqual(
            decision,
            .refuse(
                message: "parakeet at BF16 needs ~1.5 GB; ~0.0 GB free without swapping. Unload qwen or whisper, pick 8-bit, or allow swap in Vella → Memory.", needMB: 1512,
                freeMB: 0))
        XCTAssertEqual(
            planAdmission(ref("parakeet", "4b"), loaded: [], rawAvailableMB: 900, allowSwap: false),
            .refuse(message: "parakeet at 4-bit needs ~1.5 GB; ~0.9 GB free without swapping. Allow swap in Vella → Memory.", needMB: 1512, freeMB: 900))
    }
    func testMultiModelRefusalSuggestsOneAtATimeAndNeverUnloadingANeededModel() {
        let loaded = [info("streaming", .manual, used: 1), info("other", .onDemand, used: 2)]
        guard case .refuse(let message, _, _) = planAdmission(ref("dictation"), loaded: loaded, rawAvailableMB: 0, together: ["streaming"], allowSwap: false) else {
            return XCTFail()
        }
        XCTAssertEqual(
            message,
            "dictation at 8-bit needs ~1.5 GB; ~0.0 GB free without swapping. This needs streaming and dictation loaded together. Load one model at a time, unload other, pick 4-bit, or allow swap in Vella → Memory."
        )
        XCTAssertFalse(message.contains("unload streaming"))
    }
    func testLowerPrecisionReloadUnderDeficitIsRefusedBeforeUnloading() {
        // Working model "p" at 8b (1,000 MB) is excluded from candidates and credited instead; still short → refuse.
        let other = [info("q", .manual, used: 1, mb: 300)]
        let decision = planAdmission(ref("p", "4b", memory: 700), loaded: other, rawAvailableMB: -900, credit: 1000, allowSwap: false)
        guard case .refuse(let message, let need, let free) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(need, 1212); XCTAssertEqual(free, 100)
        XCTAssertTrue(message.hasPrefix("p at 4-bit needs ~1.2 GB; ~0.1 GB free"))
        // With enough credit the same reload is admitted without touching q.
        XCTAssertEqual(
            planAdmission(ref("p", "4b", memory: 700), loaded: other, rawAvailableMB: 300, credit: 1000, allowSwap: false),
            .admit(evict: [], needMB: 1212, freeMB: 1300))
    }
    func testAllowSwapAdmitsEverything() {
        XCTAssertEqual(planAdmission(ref("a"), loaded: [], rawAvailableMB: -5000, allowSwap: true), .admit(evict: [], needMB: 1512, freeMB: 0))
    }
    func testEstimateUsesMeasuredElseDiskPlusOverhead() {
        XCTAssertEqual(memoryEstimateMB(ref("a", memory: 1340)), 1340)
        XCTAssertEqual(memoryEstimateMB(ModelRef(id: "b", path: "/b", diskBytes: 2_000_000_000)), 2768)
    }
    func testSmallerPrecisionAndBits() {
        XCTAssertEqual(smallerPrecision(ref("a", "BF16")), "8b")
        XCTAssertEqual(smallerPrecision(ref("a", "8b")), "4b")
        XCTAssertNil(smallerPrecision(ref("a", "4b")))
        XCTAssertEqual(precisionBits("FP32"), 32)
    }
    func testShedKeepsFirstManualAndBusy() {
        let loaded = [info("od", .onDemand, used: 1), info("m1", .manual, used: 2), info("m2", .manual, used: 3), info("busy", .onDemand, used: 0)]
        XCTAssertEqual(shedVictims(loaded, order: ["od", "m1", "m2", "busy"], pinned: ["busy"]), ["od", "m2"])
    }

    func testProbeTestFileAndVMStats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m.json")
        try JSONSerialization.data(withJSONObject: ["available_mb": 5000]).write(to: file)
        let probe = MemoryProbe(environment: ["VELLA_TEST_MEMORY_FILE": file.path], totalMB: 32000)
        XCTAssertEqual(probe.rawAvailableMB(loadedMB: 2000), 3000)
        XCTAssertEqual(probe.availableMB(loadedMB: 9000), 0)
        let stats = dir.appendingPathComponent("vm.json")
        // (1000 − 200 + 300 + 100) pages × 16,384 B = 19.66 MB; level 50 % of 32 GB = 16 GB; margin 3.2 GB.
        try JSONSerialization.data(withJSONObject: [
            "free_count": 1000, "speculative_count": 200, "external_page_count": 300, "purgeable_count": 100,
            "page_size": 16384, "memorystatus_level": 50
        ]).write(to: stats)
        let vm = MemoryProbe(environment: ["VELLA_TEST_VM_STATS": stats.path], totalMB: 32000)
        XCTAssertEqual(vm.rawAvailableMB(loadedMB: 0), 1200 * 16384 / 1e6 - 3200, accuracy: 0.001)
        XCTAssertEqual(MemoryProbe(environment: [:], totalMB: 8000).marginMB, 1000)
        XCTAssertGreaterThan(MemoryProbe(environment: [:]).rawAvailableMB(loadedMB: 0), -100_000) // live kernel counters read
    }

    func testKeepHotDefaultsDeadlinesAndSettingsDecoding() throws {
        let settings = ResidencySettings()
        XCTAssertEqual(settings.manualIdleMinutes, 0); XCTAssertEqual(settings.onDemandIdleMinutes, 15)
        XCTAssertEqual(KeepHot.choices, [5, 15, 30, 60, 0]); XCTAssertEqual(KeepHot.title(0), "Always")
        XCTAssertNil(unloadDeadline(lastUsed: 100, residency: .manual, settings: settings))
        XCTAssertEqual(unloadDeadline(lastUsed: 100, residency: .onDemand, settings: settings), 1000)
        XCTAssertEqual(try XCTUnwrap(unloadDeadline(lastUsed: 100, residency: .onDemand, settings: settings, minuteSeconds: 0.01)), 100.15, accuracy: 1e-9)
        // Missing, invalid and Always (0) values round-trip; old configs without residency decode to defaults.
        let decoded = try JSONDecoder().decode(ResidencySettings.self, from: Data(#"{"manualIdleMinutes": 7, "onDemandIdleMinutes": 0}"#.utf8))
        XCTAssertEqual(decoded.manualIdleMinutes, 0); XCTAssertEqual(decoded.onDemandIdleMinutes, 0)
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"model": "/m"}"#.utf8))
        XCTAssertEqual(old.residency, ResidencySettings())
        var config = Configuration(model: "/m"); config.residency.onDemandIdleMinutes = 0
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)).residency.onDemandIdleMinutes, 0)
    }
    func testLaunchSetJoinReplacesPrecisionAndLeaveIsExplicit() {
        var settings = ResidencySettings()
        settings.join(ref("p", "8b")); settings.join(ref("q")); settings.join(ref("p", "4b"))
        XCTAssertEqual(settings.launchSet.map { "\($0.id)@\($0.precision)" }, ["p@4b", "q@8b"])
        settings.leave("p")
        XCTAssertEqual(settings.launchSet.map(\.id), ["q"])
    }
    func testStatusRoundTripAtomicWriteAndTolerantDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var status = WorkerStatus(); status.updated = 1
        var model = WorkerModelStatus(); model.engine = "optimized"; model.residency = "manual"; model.optimizations = ["decoder": true]
        status.models["parakeet-v3"] = model; status.gpu = GPUStatus(chip: "Apple M5 Max", family: "apple9")
        let url = dir.appendingPathComponent("worker-status.json")
        try status.write(to: url)
        XCTAssertEqual(WorkerStatus.read(url), status)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["worker-status.json"], "no temporary files left")
        let partial = try JSONDecoder().decode(WorkerStatus.self, from: Data(#"{"models": {"x": {"engine": "mlx"}}, "refused": 3}"#.utf8))
        XCTAssertEqual(partial.models["x"]?.engine, "mlx"); XCTAssertNil(partial.refused)
        XCTAssertEqual(activeTestHooks(["VELLA_TEST_MINUTE_SECONDS": "1", "HOME": "/x", "VELLA_STUB_MODELS": ""]), ["VELLA_TEST_MINUTE_SECONDS": "1"])
    }
}
