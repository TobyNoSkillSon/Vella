import XCTest
import Darwin
import VellaCore
import VellaWire
@testable import Vella

final class StockRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func helper() throws -> URL {
        let url = root.appendingPathComponent("worker.py")
        try #"""
        #!/usr/bin/env python3
        import json,sys,os,time
        for line in sys.stdin:
            q=json.loads(line)
            if q.get('op')=='load':
                stock=os.environ.get('VELLA_FORCE_STOCK')=='1' or os.environ.get('VELLA_RECIPE')=='standard'
                print(json.dumps({'status':{'model':q['model'],'engine':'mlx' if stock else 'optimized','event':'load'}}),flush=True)
            if q.get('op')=='audio' or 'audio' in q: time.sleep(5)
            print(json.dumps({'id':q['id'],'frames':0,'loaded':True,'text':'fixture'}),flush=True)
        """#.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    @MainActor private func runtime(_ mode: RecognitionMode) throws -> Runtime {
        let runtime = try Runtime.isolated(root.appendingPathComponent(mode.rawValue))
        runtime.resolver = { path, mode in ModelRef(id: "fixture", path: path, mode: mode) }
        return runtime
    }
    @MainActor private func ref(_ runtime: Runtime, mode: RecognitionMode) -> ModelRef {
        ModelRef(id: "fixture", path: root.appendingPathComponent("model").path, mode: mode)
    }
    @MainActor private func strikes(_ runtime: Runtime) throws -> [String: Int] {
        let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: runtime.support.appendingPathComponent("Worker"), includingPropertiesForKeys: nil).first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        return try XCTUnwrap(json["strikes"] as? [String: Int])
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
    @MainActor private struct Worker {
        let dictation: Backend?
        let streaming: StreamingBackend?
        init(runtime: Runtime, helper: URL, mode: RecognitionMode) {
            dictation = mode == .dictation ? Backend(helper: helper, requestTimeout: 0.5, runtime: runtime) : nil
            streaming = mode == .streaming ? StreamingBackend(helper: helper, timeout: 0.5, runtime: runtime) : nil
        }
        var pid: Int32? { dictation?.processID ?? streaming?.processID }
        func load(_ ref: ModelRef) async throws {
            if let dictation { try await dictation.preload(ref, residency: .onDemand) }
            if let streaming { try await streaming.preload(ref, residency: .onDemand) }
        }
        func shutdown() { dictation?.shutdown(); streaming?.shutdown() }
    }

    @MainActor func testOneOptimizedExitIsSessionOnlyThenSecondExitAcrossRelaunchIsSticky() async throws {
        for mode in [RecognitionMode.dictation, .streaming] {
            let first = try runtime(mode), helper = try helper()
            let model = ref(first, mode: mode)
            let worker = Worker(runtime: first, helper: helper, mode: mode); defer { worker.shutdown() }
            try await worker.load(model)
            XCTAssertEqual(first.status.models[model.id]?.engine, "optimized")
            kill(try XCTUnwrap(worker.pid), SIGKILL) // jetsam-like EOF; no kernel error reported
            try await waitUntil { first.status.models.isEmpty && worker.pid == nil }
            XCTAssertEqual(first.workerEnvironment(model)["VELLA_FORCE_STOCK"], "1")
            XCTAssertEqual(try strikes(first).values.sorted(), [1], "one EOF is exactly one strike")
            try await worker.load(model)
            XCTAssertEqual(first.status.models[model.id]?.engine, "mlx", "same-session retries use stock")
            kill(try XCTUnwrap(worker.pid), SIGKILL)
            try await waitUntil { first.status.models.isEmpty && worker.pid == nil }
            XCTAssertEqual(try strikes(first).values.sorted(), [1], "stock crashes never add an optimized strike")
            worker.shutdown()

            let second = try runtime(mode)
            XCTAssertNil(second.workerEnvironment(model)["VELLA_FORCE_STOCK"], "one strike permits optimized after app relaunch")
            let next = Worker(runtime: second, helper: helper, mode: mode); defer { next.shutdown() }
            try await next.load(model)
            XCTAssertEqual(second.status.models[model.id]?.engine, "optimized")
            kill(try XCTUnwrap(next.pid), SIGKILL)
            try await waitUntil { second.status.models.isEmpty && next.pid == nil }
            XCTAssertEqual(try strikes(second).values.sorted(), [2])
            let third = try runtime(mode)
            XCTAssertEqual(third.workerEnvironment(model)["VELLA_FORCE_STOCK"], "1", "two confirmed optimized exits persist")
            let stock = Worker(runtime: third, helper: helper, mode: mode); defer { stock.shutdown() }
            try await stock.load(model)
            XCTAssertEqual(third.status.models[model.id]?.engine, "mlx")
            stock.shutdown()
            next.shutdown()
        }
    }

    @MainActor func testBusyRequestTimeoutForcesStockThisSessionWithoutAddingAStrike() async throws {
        for mode in [RecognitionMode.dictation, .streaming] {
            let runtime = try runtime(mode), helper = try helper()
            let model = ref(runtime, mode: mode)
            let worker = Worker(runtime: runtime, helper: helper, mode: mode); defer { worker.shutdown() }
            try await worker.load(model)
            XCTAssertEqual(runtime.status.models[model.id]?.engine, "optimized")
            do {
                if let streaming = worker.streaming {
                    try await streaming.start(config: Configuration(model: model.path, mode: .streaming))
                    try await streaming.feed(Data(repeating: 0, count: 6400))
                }
                if let dictation = worker.dictation {
                    let audio = root.appendingPathComponent("audio.wav")
                    try Data(repeating: 0, count: 64).write(to: audio)
                    _ = try await dictation.transcribe(audio, config: Configuration(model: model.path))
                }
                XCTFail("Missing request timeout")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            XCTAssertEqual(runtime.workerEnvironment(model)["VELLA_FORCE_STOCK"], "1")
            XCTAssertEqual(try strikes(runtime), [:])
            worker.shutdown()
            let relaunched = try self.runtime(mode)
            XCTAssertNil(relaunched.workerEnvironment(model)["VELLA_FORCE_STOCK"])
        }
    }

    @MainActor func testUnconfirmedExitAndRuntimeFallbackDoNotPersistStrikes() throws {
        let runtime = try runtime(.dictation), model = ref(runtime, mode: .dictation)
        runtime.workerExited(model, optimized: false)
        runtime.update(model.id, worker: HelperStatus(json: ["model": model.path, "engine": "mlx", "event": "fallback"]))
        XCTAssertEqual(runtime.workerEnvironment(model)["VELLA_FORCE_STOCK"], "1")
        XCTAssertEqual(try strikes(runtime), [:])
        XCTAssertNil(try self.runtime(.dictation).workerEnvironment(model)["VELLA_FORCE_STOCK"])
    }

    @MainActor func testEpochChangeClearsStrikesAndStickyRequirement() throws {
        let support = root.appendingPathComponent("epoch-support")
        let first = Runtime(support: support, recoveryEpoch: "old")
        let model = ref(first, mode: .dictation)
        first.workerExited(model, optimized: true)
        first.workerExited(model, optimized: true)
        XCTAssertEqual(Runtime(support: support, recoveryEpoch: "old").workerEnvironment(model)["VELLA_FORCE_STOCK"], "1")
        let changed = Runtime(support: support, recoveryEpoch: "new")
        XCTAssertNil(changed.workerEnvironment(model)["VELLA_FORCE_STOCK"])
        changed.workerExited(model, optimized: true)
        XCTAssertNil(Runtime(support: support, recoveryEpoch: "new").workerEnvironment(model)["VELLA_FORCE_STOCK"], "old epoch strikes are not counted")
    }

    @MainActor func testUnwritableStoreFailsClosedAcrossRelaunch() throws {
        let runtime = try runtime(.dictation), model = ref(runtime, mode: .dictation)
        // A file where the Worker directory belongs is deterministically unwritable, even when tests run as root.
        try Data().write(to: runtime.support.appendingPathComponent("Worker"))
        XCTAssertEqual(runtime.workerEnvironment(model)["VELLA_FORCE_STOCK"], "1")
        runtime.workerExited(model, optimized: true)
        XCTAssertEqual(try self.runtime(.dictation).workerEnvironment(model)["VELLA_FORCE_STOCK"], "1")
    }

    @MainActor func testRecoveryRecordIsBoundedAndOverflowFailsClosed() throws {
        let runtime = try runtime(.dictation)
        for index in 0..<257 {
            runtime.workerExited(ModelRef(id: "m\(index)", path: "/model/\(index)", mode: .dictation), optimized: true)
        }
        XCTAssertEqual(try strikes(runtime).count, 256)
        let other = ref(runtime, mode: .dictation)
        XCTAssertEqual(try self.runtime(.dictation).workerEnvironment(other)["VELLA_FORCE_STOCK"], "1")
    }
}
