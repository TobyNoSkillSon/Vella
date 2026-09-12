import XCTest
import AppKit
@testable import Vella

final class DownloadTests: XCTestCase {
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
        let event: [String: Any] = ["event": "installed", "modelID": id, "path": Backend.support.appendingPathComponent("Models/\(id)").path]
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
}
