import XCTest

/// SwiftPM's generated `Bundle.module` accessor looks beside the app bundle and in the build machine's `.build`
/// directory and traps when neither exists. In a release built elsewhere (CI) every dictation self-test crashed, so
/// every model went inconclusive and then stock. The workers must find their bundled resources explicitly.
/// The worker package needs MLX to build, so this is checked from source.
final class WorkerResourceTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testWorkersNeverUseTheGeneratedBundleAccessor() throws {
        let sources = Self.root.appendingPathComponent("Worker/Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let users = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("Bundle.module") }.map(\.lastPathComponent)
        XCTAssertEqual(users, [], "Bundle.module traps in an app built on another machine")
    }

    func testDictationSelfTestLooksInTheAppResources() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Worker/Sources/VellaWorker/FastPathSelfTest.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("Bundle.main.resourceURL"))
        XCTAssertTrue(text.contains("VellaWorker_VellaWorker.bundle"))
    }
}
