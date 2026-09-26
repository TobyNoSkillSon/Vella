import XCTest
import AppKit
import Foundation
import Darwin
@testable import Vella
import VellaCore

/// CHECKLIST 6 (status), 8 (fresh install, residency classes) and 9 (memory admission) through the real Backend and
/// Runtime with a fake stdio worker, an isolated support dir, a fake memory probe and shortened minutes.
final class RuntimeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func model(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("models/\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func wav() throws -> URL {
        let session = try RecordingSession(root: root.appendingPathComponent("rec"), config: Configuration(model: "/unused"))
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        return try session.wav(for: session.manifest.segments[0])
    }
    @MainActor private func pair(_ runtime: Runtime) throws -> Backend {
        let backend = Backend(helper: try FakeWorker.install(in: root), requestTimeout: 5, runtime: runtime)
        runtime.dictation = backend
        // Catalog identity: family id = folder name, 1,000 MB measured, 4b/8b options.
        runtime.resolver = { path, mode in
            let name = URL(fileURLWithPath: path).lastPathComponent
            let family = name.components(separatedBy: "@").first!
            let precision = name.contains("@") ? name.components(separatedBy: "@")[1] : "8b"
            return ModelRef(id: family, precision: precision, path: path, mode: mode, name: family, memoryMB: 1000, precisionOptions: ["4b", "8b"])
        }
        return backend
    }
    @MainActor private func fileStatus(_ runtime: Runtime) throws -> WorkerStatus {
        try XCTUnwrap(WorkerStatus.read(runtime.statusURL))
    }
    @MainActor private func config(_ runtime: Runtime) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: runtime.configURL))
    }
    @MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "condition not reached within \(timeout) s")
    }

    // CHECKLIST 8
    @MainActor func testFreshInstallLoadsNothingOnDemandExpiresManualPersists() async throws {
        let runtime = try Runtime.isolated(root, minuteSeconds: 0.02) // 15 min on demand = 0.3 s
        let backend = try pair(runtime); defer { backend.shutdown() }
        runtime.start()
        XCTAssertEqual(try fileStatus(runtime).models, [:])
        XCTAssertEqual(try config(runtime).residency.launchSet, [])
        XCTAssertEqual(try fileStatus(runtime).launch_set, [])

        // One request loads the model on demand; the status file shows it before the request returns.
        let dictation = try model("parakeet")
        _ = try await backend.transcribe(try wav(), config: Configuration(model: dictation.path))
        let loaded = try fileStatus(runtime).models["parakeet"]
        XCTAssertEqual(loaded?.residency, "on_demand")
        XCTAssertEqual(loaded?.keep_hot_min, 15)
        XCTAssertNotNil(loaded?.pid)
        XCTAssertEqual(try config(runtime).residency.launchSet, [], "on-demand loads never join the launch set")
        let pid = try XCTUnwrap(backend.processID)
        try await waitUntil { (try? self.fileStatus(runtime))?.models.isEmpty == true }
        XCTAssertEqual(try fileStatus(runtime).evictions?.last?.reason, "idle: unused for 15 min (loaded on demand)")
        try await waitUntil { kill(pid, 0) != 0 }

        // Relaunch: not loaded.
        let relaunch = try Runtime.isolated(root, minuteSeconds: 0.02)
        let second = try pair(relaunch); defer { second.shutdown() }
        relaunch.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try fileStatus(relaunch).models, [:])

        // Menu Load: manual, Always, launch set; loaded after relaunch.
        let ref = relaunch.resolve(dictation.path, mode: .dictation)
        try await relaunch.load(ref)
        XCTAssertEqual(try fileStatus(relaunch).models["parakeet"]?.residency, "manual")
        XCTAssertEqual(try fileStatus(relaunch).models["parakeet"]?.keep_hot_min, 0)
        XCTAssertEqual(try config(relaunch).residency.launchSet.map(\.id), ["parakeet"])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(try fileStatus(relaunch).models["parakeet"], "manual Always never idles out")
        second.shutdown()

        let third = try Runtime.isolated(root, minuteSeconds: 0.02)
        let backend3 = try pair(third); defer { backend3.shutdown() }
        third.start()
        try await waitUntil { (try? self.fileStatus(third))?.models["parakeet"]?.residency == "manual" }

        // Unload leaves the launch set only after the worker has exited.
        let manualPID = try XCTUnwrap(backend3.processID)
        await third.unload("parakeet")
        XCTAssertNotEqual(kill(manualPID, 0), 0)
        XCTAssertEqual(try config(third).residency.launchSet, [])
        XCTAssertEqual(try fileStatus(third).models, [:])
    }

    // CHECKLIST 6: every change is in the file before the call returns.
    @MainActor func testLoadUnloadAndSettingsReachStatusFileBeforeReturning() async throws {
        let runtime = try Runtime.isolated(root)
        let backend = try pair(runtime); defer { backend.shutdown() }
        runtime.start()
        let ref = runtime.resolve(try model("qwen").path, mode: .dictation)
        try await runtime.load(ref)
        XCTAssertEqual(try fileStatus(runtime).models["qwen"]?.engine, "mlx")
        XCTAssertEqual(try fileStatus(runtime).gpu?.family, "apple9")
        XCTAssertEqual(try fileStatus(runtime).models["qwen"]?.memory_mb, 1000)
        XCTAssertEqual(try fileStatus(runtime).test_hooks?["VELLA_TEST_MEMORY_FILE"], runtime.probe.testFile?.path)
        runtime.setKeepHot(manual: 30)
        XCTAssertEqual(try fileStatus(runtime).settings?.manual_idle_minutes, 30)
        XCTAssertEqual(try fileStatus(runtime).models["qwen"]?.keep_hot_min, 30)
        XCTAssertEqual(try config(runtime).residency.manualIdleMinutes, 30)
        runtime.setAllowSwap(true)
        XCTAssertEqual(try fileStatus(runtime).settings?.allow_swap, true)
        await runtime.unload("qwen")
        XCTAssertEqual(try fileStatus(runtime).models, [:])
    }

    // CHECKLIST 9, end to end: LRU on-demand eviction, refusal that unloads nothing, reload under a deficit.
    @MainActor func testAdmissionEvictsOnDemandFirstRefusesWithoutUnloadingAndReloadKeepsWorkingModel() async throws {
        // need = 1,000 + 512 = 1,512 MB; each loaded model reports a 1,000 MB footprint.
        let runtime = try Runtime.isolated(root, availableMB: 3_100)
        let backend = try pair(runtime); defer { backend.shutdown() }
        runtime.start()
        let a = runtime.resolve(try model("alpha").path, mode: .dictation)
        try await runtime.load(a) // manual
        _ = try await backend.transcribe(try wav(), config: Configuration(model: try model("beta").path)) // on demand
        XCTAssertEqual(Set(try fileStatus(runtime).models.keys), ["alpha", "beta"])
        // raw = 3,100 − 2,000 = 1,100 < 1,512: evict beta (on demand) before alpha (manual).
        _ = try await backend.transcribe(try wav(), config: Configuration(model: try model("gamma").path))
        XCTAssertEqual(Set(try fileStatus(runtime).models.keys), ["alpha", "gamma"])
        XCTAssertTrue(try fileStatus(runtime).evictions?.last?.reason.hasPrefix("memory: made room for gamma at 8b") == true)

        // Cannot fit even after unloading everything: nothing is unloaded, the refusal names need, free, ways out.
        try runtime.setAvailableMB(2_500) // raw = 500; + 2,000 reclaimable = 2,500 ≥ 1,512 would fit…
        try runtime.setAvailableMB(1_400) // raw = −600; + 2,000 = 1,400 < 1,512: refuse
        do { _ = try await backend.transcribe(try wav(), config: Configuration(model: try model("delta").path)); XCTFail("admitted") }
        catch {
            XCTAssertEqual(error.localizedDescription, "delta at 8b needs ~1.5 GB; ~0.0 GB free without swapping. Unload alpha or gamma, pick 4b, or allow swap in Vella → Memory.")
        }
        XCTAssertEqual(Set(try fileStatus(runtime).models.keys), ["alpha", "gamma"])
        XCTAssertEqual(try fileStatus(runtime).refused?.model, "delta")

        // Reload alpha at 4b under a deficit: refused before unloading; the working 8b stays loaded.
        try runtime.setAvailableMB(1_000) // raw = −1,000; credit 1,000 → 0; gamma 1,000 would make 1,000 < 1,512
        let alpha4 = runtime.resolve(try model("alpha@4b").path, mode: .dictation)
        do { try await runtime.load(alpha4); XCTFail("reload admitted") } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("alpha at 4b needs")) }
        XCTAssertEqual(try fileStatus(runtime).models["alpha"]?.precision, "8b")
        XCTAssertEqual(try fileStatus(runtime).models["alpha"]?.residency, "manual")

        // With room, the reload replaces the precision in place and keeps it manual.
        try runtime.setAvailableMB(10_000)
        try await runtime.load(alpha4)
        XCTAssertEqual(try fileStatus(runtime).models["alpha"]?.precision, "4b")
        XCTAssertEqual(try config(runtime).residency.launchSet.map(\.precision), ["4b"])
    }

    @MainActor func testFailedReloadRestoresThePreviousPrecision() async throws {
        let runtime = try Runtime.isolated(root)
        let backend = try pair(runtime); defer { backend.shutdown() }
        runtime.start()
        try await runtime.load(runtime.resolve(try model("alpha").path, mode: .dictation))
        do { try await runtime.load(runtime.resolve(try model("alpha@loadfail").path, mode: .dictation)); XCTFail() } catch { }
        XCTAssertEqual(try fileStatus(runtime).models["alpha"]?.precision, "8b")
        XCTAssertEqual(try fileStatus(runtime).models["alpha"]?.residency, "manual")
        XCTAssertEqual(try config(runtime).residency.launchSet.map(\.precision), ["8b"])
    }

    @MainActor func testCrashedManualWorkerRestartsAndOnDemandDoesNot() async throws {
        let runtime = try Runtime.isolated(root)
        let backend = try pair(runtime); defer { backend.shutdown() }
        runtime.start()
        try await runtime.load(runtime.resolve(try model("alpha").path, mode: .dictation))
        let pid = try XCTUnwrap(backend.processID)
        kill(pid, SIGKILL)
        try await waitUntil { (try? self.fileStatus(runtime))?.error?.hasPrefix("Worker exited (signal 9).") == true }
        try await waitUntil(8) { ((try? self.fileStatus(runtime))?.models["alpha"]?.pid).map { $0 != pid } == true }
        // A worker that loads and dies again never resets the budget: after 3 restarts it stays down, error kept.
        for _ in 0..<3 {
            let next = try XCTUnwrap((try? fileStatus(runtime))?.models["alpha"]?.pid)
            kill(next, SIGKILL)
            try await waitUntil(10) { let s = try? self.fileStatus(runtime); return s?.models["alpha"] != nil && s?.models["alpha"]?.pid != next || s?.error?.contains("Stopped restarting") == true }
        }
        try await waitUntil(10) { (try? self.fileStatus(runtime))?.error?.contains("Stopped restarting alpha after 3 attempts") == true }
        XCTAssertNil(try fileStatus(runtime).models["alpha"])
        XCTAssertTrue(try String(contentsOf: runtime.logURL, encoding: .utf8).contains("stopped restarting after 3 attempts"))
    }

    @MainActor func testFirstDictationWithoutModelKeepsRecordingAndOffersGet() async throws {
        let runtime = try Runtime.isolated(root)
        let configURL = runtime.configURL
        try JSONEncoder().encode(Configuration(model: "")).write(to: configURL)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        var requested: [String] = []
        let model = Model(pasteboard: pasteboard, transcriptionRequest: { url, config in requested.append(config.model); return "hello from the new model" },
                          configurationURL: configURL)
        defer { model.shutdown() }
        let session = try RecordingSession(root: root.appendingPathComponent("rec2"), config: Configuration(model: ""))
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 16000).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        let modelDir = try self.model("parakeet")
        model.offerModel = { mode in Model.ModelOffer(id: "parakeet-v3-4b", name: "Parakeet v3", downloadBytes: 1_300_000_000, mode: mode) }
        var fetched: [String] = []
        model.fetchModel = { offer in fetched.append(offer.id); return modelDir.path }
        model.recover(session.directory)
        try await waitUntil { model.pendingModelRequest != nil }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.pendingModelRequest?.title, "Get Parakeet v3 (1.3 GB)")
        XCTAssertTrue(model.message.hasPrefix("Recording saved."))
        XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.segments.first?.frames, 16000, "audio kept durably")
        XCTAssertTrue(requested.isEmpty && fetched.isEmpty, "nothing downloads until the user chooses Get")
        model.getRecommendedModel()
        try await waitUntil { model.phase == .success || model.phase == .idle }
        XCTAssertEqual(fetched, ["parakeet-v3-4b"])
        XCTAssertEqual(requested, [modelDir.path])
        XCTAssertEqual(model.lastText, "hello from the new model")
        XCTAssertFalse(model.insertionWasAutomatic, "a recording transcribed after Get is clipboard-only")
        XCTAssertEqual(pasteboard.string(forType: .string), "hello from the new model")
        XCTAssertNil(model.pendingModelRequest)
    }
}
