import XCTest
@testable import VellaCore

final class DownloadPromptTests: XCTestCase {
    // The Get pop-up's text for the shipped catalog: TierCatalogTests.testGetPopUpStatesDownloadConversionAndStoredSize.

    func testExactBytes() { XCTAssertEqual(formatExactBytes(637_004_647), "637,004,647 bytes") }

    // MARK: Partial downloads

    private func tree() throws -> (root: URL, models: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-partials-\(UUID())")
        let models = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, models)
    }
    @discardableResult private func partial(in folder: URL, age: TimeInterval, name: String = "abc.def.incomplete") throws -> URL {
        let file = folder.appendingPathComponent(".cache/huggingface/download").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Launch sweep: stale partials inside the models directory only. An unfinished download (not kept) goes whole; a
    /// kept model loses only its stale partials; a fresh partial, a symlinked folder and anything outside stay.
    func testLaunchSweepRemovesOnlyStalePartialsInsideTheModelsDirectory() throws {
        let (root, models) = try tree()
        let unfinished = models.appendingPathComponent("parakeet-fp32")
        try partial(in: unfinished, age: 7200)
        try Data("{}".utf8).write(to: unfinished.appendingPathComponent("config.json"))
        let kept = models.appendingPathComponent("installed-model")
        let keptPartial = try partial(in: kept, age: 7200)
        try Data(repeating: 2, count: 8).write(to: kept.appendingPathComponent("model.safetensors"))
        let active = models.appendingPathComponent("downloading-now")
        let fresh = try partial(in: active, age: 5)
        let outside = root.appendingPathComponent("elsewhere")
        let outsidePartial = try partial(in: outside, age: 7200)
        try FileManager.default.createSymbolicLink(at: models.appendingPathComponent("linked"), withDestinationURL: outside)
        let plain = models.appendingPathComponent("no-cache")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let removed = sweepStalePartialDownloads(modelsDirectory: models, keep: [kept.path])
        XCTAssertFalse(exists(unfinished), "an unfinished download goes whole")
        XCTAssertTrue(exists(kept.appendingPathComponent("model.safetensors")))
        XCTAssertFalse(exists(keptPartial), "a kept model loses only its stale partial")
        XCTAssertTrue(exists(fresh), "a partial written in the last 10 minutes may belong to a running download")
        XCTAssertTrue(exists(outsidePartial), "never follows a symlink out of the models directory")
        XCTAssertTrue(exists(plain))
        func inside(_ path: String) -> String { path.components(separatedBy: "/Models/").last ?? path }
        XCTAssertEqual(Set(removed.map(inside)), ["parakeet-fp32", "installed-model/.cache/huggingface/download/abc.def.incomplete"])
        XCTAssertEqual(sweepStalePartialDownloads(modelsDirectory: root.appendingPathComponent("missing"), keep: []), [])
    }

    func testRemoveUnfinishedDownloadNeverTouchesKeptLinkedOrOutsideFolders() throws {
        let (root, models) = try tree()
        let folder = models.appendingPathComponent("m")
        try partial(in: folder, age: 0)
        XCTAssertFalse(removeUnfinishedDownload(id: "m", modelsDirectory: models, keep: [folder.path]))
        XCTAssertTrue(exists(folder))
        XCTAssertFalse(removeUnfinishedDownload(id: "../elsewhere", modelsDirectory: models, keep: []))
        let outside = root.appendingPathComponent("elsewhere")
        try partial(in: outside, age: 0)
        try FileManager.default.createSymbolicLink(at: models.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertFalse(removeUnfinishedDownload(id: "link", modelsDirectory: models, keep: []))
        XCTAssertTrue(exists(outside))
        XCTAssertTrue(removeUnfinishedDownload(id: "m", modelsDirectory: models, keep: []))
        XCTAssertFalse(exists(folder))
    }
}
