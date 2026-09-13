import XCTest
import AppKit
@testable import Vella

final class DownloadTests: XCTestCase {
    @MainActor func testDownloadCannotInterruptDictation() {
        let library = ModelLibrary()
        library.selectedID = library.models.first!.id
        library.mayChangeModel = { false }
        var interrupted = false
        library.beforeHeavyWork = { interrupted = true }
        library.workerPython = { throw NSError(domain: "Fixture: never launch a download", code: 1) }
        library.download()
        XCTAssertFalse(interrupted)
        XCTAssertNil(library.downloadingID)
        XCTAssertFalse(library.busy)
    }
    @MainActor func testProgressIsBoundedAndInstallationWaitsForSuccessfulExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appendingPathComponent("registry.json")
        let library = ModelLibrary(registryURL: registry)
        let id = "Qwen3-ASR-1.7B-4bit"
        let active = library.activeModelPath
        library.downloadingID = id; library.busy = true
        library.receive(Data("{\"event\":\"progress\",\"completed\":50,\"total\":100}\n".utf8))
        XCTAssertEqual(library.progress, 0.5)
        library.receive(Data("{\"event\":\"progress\",\"completed\":200,\"total\":100}\n".utf8))
        XCTAssertEqual(library.progress, 0.99)
        let event: [String: Any] = ["event": "installed", "modelID": id, "revision": library.models.first { $0.id == id }!.revision,
                                  "path": library.modelsDirectory.appendingPathComponent(id).path]
        var bytes = try JSONSerialization.data(withJSONObject: event); bytes.append(10)
        library.receive(bytes)
        XCTAssertNil(library.installed[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path))
        library.finished(code: 0)
        XCTAssertNotNil(library.installed[id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: registry.path))
        XCTAssertEqual(library.progress, 1)
        XCTAssertFalse(library.busy)
        XCTAssertEqual(library.activeModelPath, active)
    }
    @MainActor func testFailedAndUnexpectedWorkersNeverInstall() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ModelLibrary(registryURL: directory.appendingPathComponent("registry.json"))
        library.downloadingID = "expected"; library.busy = true
        library.receive(Data("{\"event\":\"installed\",\"modelID\":\"other\",\"path\":\"/tmp/wrong\"}\n".utf8))
        library.finished(code: 0)
        XCTAssertNotNil(library.downloadError)
        XCTAssertTrue(library.installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    @MainActor func testDownloadDoesNotResizeMenu() throws {
        _ = NSApplication.shared
        let library = ModelLibrary()
        let menu = ModelsMenu(library: library).modelItem()
        let view = try XCTUnwrap(menu.submenu?.items.first?.view)
        let initial = view.frame.size
        library.busy = true; library.downloadingID = library.models.first?.id; library.progress = 0.5
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.size, initial)
    }
    @MainActor func testShortProgressEventArrivesBeforeWorkerExits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = ModelLibrary.resourceDirectory()
        for name in ["models.json", "benchmark-policy.json"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
        try "import json,time\nprint(json.dumps(dict(event='progress',completed=50,total=100)),flush=True)\ntime.sleep(10)\n".write(to: directory.appendingPathComponent("benchmark_worker.py"), atomically: true, encoding: .utf8)
        let library = ModelLibrary(resources: directory, registryURL: directory.appendingPathComponent("registry.json"))
        library.workerPython = { URL(fileURLWithPath: "/usr/bin/python3") }
        library.download()
        defer { library.cancel() }
        for _ in 0..<40 {
            if library.progress != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(library.progress, 0.5, "A short progress line must not wait for 4096 bytes or EOF")
        XCTAssertTrue(library.busy)
    }

    @MainActor func testWrongRevisionCannotBeRegistered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-pin-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(registryURL: root.appendingPathComponent("registry.json"))
        let id = library.models.first!.id
        library.downloadingID = id; library.busy = true
        var event = try JSONSerialization.data(withJSONObject: ["event":"installed", "modelID":id,
            "revision":"wrong", "path":library.modelsDirectory.appendingPathComponent(id).path]); event.append(10)
        library.receive(event); library.finished(code: 0)
        XCTAssertTrue(library.installed.isEmpty)
        XCTAssertNotNil(library.downloadError)
        XCTAssertNil(library.downloadingID)
    }

    @MainActor func testInstalledEventFollowedByFailedExitDoesNotCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-exit-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(registryURL: root.appendingPathComponent("registry.json"))
        let model = library.models.first!
        library.downloadingID = model.id; library.busy = true
        var event = try JSONSerialization.data(withJSONObject: ["event":"installed", "modelID":model.id,
            "revision":model.revision, "path":library.modelsDirectory.appendingPathComponent(model.id).path]); event.append(10)
        library.receive(event); library.finished(code: 1)
        XCTAssertTrue(library.installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.registryURL.path))
        XCTAssertNotNil(library.downloadError)
        XCTAssertNil(library.downloadingID)
    }

    @MainActor func testCancellationBeforeQueuedCompletionCannotRegisterModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-cancel-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(registryURL: root.appendingPathComponent("registry.json"))
        let model = library.models.first!
        library.downloadingID = model.id; library.busy = true
        var event = try JSONSerialization.data(withJSONObject: ["event":"installed", "modelID":model.id,
            "revision":model.revision, "path":library.modelsDirectory.appendingPathComponent(model.id).path]); event.append(10)
        library.receive(event)
        library.cancel() // Worker is gone, but the completion is still queued.
        library.finished(code: 0)
        XCTAssertTrue(library.installed.isEmpty)
        XCTAssertTrue(library.downloadError?.contains("Cancelled") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.registryURL.path))
    }

    @MainActor func testDownloadWorkerCommitsFixtureWithoutSelectingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-install-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["models.json", "benchmark-policy.json"] {
            try FileManager.default.copyItem(at: ModelLibrary.resourceDirectory().appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        try #"""
import json,pathlib,sys
a=sys.argv
catalog=json.loads(pathlib.Path(a[a.index('--catalog')+1]).read_text())
id=a[a.index('--model-id')+1];m=next(x for x in catalog if x['id']==id)
folder=pathlib.Path(a[a.index('--models-dir')+1])/id;folder.mkdir(parents=True)
(folder/'config.json').write_text(json.dumps({'model_type':m['architecture']}))
(folder/'weights.safetensors').write_bytes(b'fixture only, never loaded')
print(json.dumps(dict(event='progress',completed=1,total=2)),flush=True)
print(json.dumps(dict(event='installed',modelID=id,path=str(folder),revision=m['revision'])),flush=True)
"""#.write(to: root.appendingPathComponent("benchmark_worker.py"), atomically: true, encoding: .utf8)
        let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
        defer { library.shutdown() }
        library.workerPython = { URL(fileURLWithPath: "/usr/bin/python3") }
        let id = library.selectedID, active = library.activeModelPath
        library.download()
        for _ in 0..<100 { if !library.busy { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(library.busy)
        XCTAssertNil(library.downloadError)
        XCTAssertEqual(library.progress, 1)
        XCTAssertEqual(library.installed[id]?.path, library.modelsDirectory.appendingPathComponent(id).path)
        XCTAssertEqual(library.activeModelPath, active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.registryURL.path))
    }
}
