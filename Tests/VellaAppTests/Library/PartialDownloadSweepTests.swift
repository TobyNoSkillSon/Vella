import XCTest
@testable import Vella
@testable import VellaCore

/// The launch sweep removes an unfinished download's folder whole only when it could read which folders are Vella's
/// models. With a damaged registry or config.json it removes stale partial files and keeps every folder.
final class PartialDownloadSweepTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-sweep-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A stale partial plus a sentinel in `Models/<id>`; returns (folder, partial, sentinel).
    @MainActor private func stalePartial(_ f: TwoFamilyFixture, in id: String) throws -> (URL, URL, URL) {
        let folder = f.controller.dictation.modelsDirectory.appendingPathComponent(id)
        let partial = folder.appendingPathComponent(".cache/huggingface/download/old.incomplete")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: partial)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: partial.path)
        let sentinel = folder.appendingPathComponent("complete-user-sentinel")
        try Data("keep".utf8).write(to: sentinel)
        return (folder, partial, sentinel)
    }
    /// A fresh controller and bridge over the fixture's files, as at launch.
    @MainActor private func sweepAtLaunch(_ f: TwoFamilyFixture) {
        let library = f.controller.dictation
        let fresh = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: library.resources, registryURL: library.registryURL),
            streaming: ModelLibrary(mode: .streaming, resources: library.resources, registryURL: library.registryURL),
            configURL: f.runtime.configURL)
        let bridge = RuntimeBridge(runtime: f.runtime)
        bridge.attach(controller: fresh, model: f.model)
        bridge.sweepPartialDownloads()
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @MainActor func testUnreadableRegistryKeepsCompleteModelFolders() throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        // alpha-bf16 is installed and complete, but not selected and not in the launch set.
        let (folder, partial, sentinel) = try stalePartial(f, in: "alpha-bf16")
        try Data("not-json".utf8).write(to: f.controller.dictation.registryURL)
        sweepAtLaunch(f)
        XCTAssertTrue(exists(sentinel), "uncertain ownership must not authorize whole-folder removal")
        XCTAssertTrue(exists(folder.appendingPathComponent("model.safetensors")))
        XCTAssertFalse(exists(partial), "a stale partial file still goes")
    }

    @MainActor func testUnreadableConfigKeepsCompleteModelFolders() throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        // An unregistered folder, which a readable config and registry would mark as an unfinished download.
        let (folder, _, sentinel) = try stalePartial(f, in: "gamma-bf16")
        try Data("{ damaged".utf8).write(to: f.runtime.configURL)
        sweepAtLaunch(f)
        XCTAssertTrue(exists(sentinel))
        XCTAssertTrue(exists(folder))
    }

    @MainActor func testReadableOwnershipStillRemovesAnUnfinishedDownload() throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        let (unfinished, _, _) = try stalePartial(f, in: "gamma-bf16")
        let (installed, installedPartial, installedSentinel) = try stalePartial(f, in: "alpha-bf16")
        sweepAtLaunch(f)
        XCTAssertFalse(exists(unfinished), "an unregistered folder with a stale partial is an unfinished download")
        XCTAssertTrue(exists(installedSentinel))
        XCTAssertTrue(exists(installed.appendingPathComponent("model.safetensors")))
        XCTAssertFalse(exists(installedPartial))
    }
}
