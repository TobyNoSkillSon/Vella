import XCTest
@testable import VellaCore

final class DownloadPromptTests: XCTestCase {
    private let parakeet = ModelFamily(id: "parakeet-v3", name: "Parakeet v3", mode: .dictation, languages: ["en"], params: "0.6B", license: "cc-by-4.0",
        native: "FP32", variants: [
            "FP32": CatalogVariant(id: "p-fp32", repository: "animaslabs/parakeet-tdt-0.6b-v3-mlx", revision: "b3f0e8a" + String(repeating: "0", count: 33),
                                   downloadBytes: 2_509_016_021, architecture: "parakeet"),
            "BF16": CatalogVariant(id: "p-bf16-local", architecture: "parakeet", derivedFrom: "FP32", dtype: "bfloat16"),
            "4b": CatalogVariant(id: "p-4bit", repository: "animaslabs/parakeet-tdt-0.6b-v3-mlx-4bit", revision: String(repeating: "c", count: 40),
                                 downloadBytes: 637_004_647, architecture: "parakeet")])

    /// Title and body name the model, precision and format, the published source or the source it is made from, the
    /// exact size and disk needed, and what happens afterwards.
    func testPromptSaysWhatWhereHowBigAndWhatNext() throws {
        let fp32 = try XCTUnwrap(downloadPrompt(family: parakeet, precision: "FP32", followUp: .reload(from: "4b"), freeBytes: 812_000_000_000))
        XCTAssertEqual(fp32.title, "Download Parakeet v3 · 32 (FP32)?")
        XCTAssertEqual(fp32.variantID, "p-fp32")
        XCTAssertEqual(fp32.body, """
            Parakeet v3 at FP32 (float32), the model's native precision, published on Hugging Face as animaslabs/parakeet-tdt-0.6b-v3-mlx at revision b3f0e8a.

            Download: 2.51 GB (2,509,016,021 bytes). Disk needed: 2.51 GB; 812 GB free.

            When the download finishes, it loads for dictation in place of the loaded 4-bit.
            """)
        let bf16 = try XCTUnwrap(downloadPrompt(family: parakeet, precision: "BF16", followUp: .load, freeBytes: nil))
        XCTAssertEqual(bf16.title, "Download Parakeet v3 · 32 (FP32) to make 16 (BF16)?")
        XCTAssertEqual(bf16.variantID, "p-fp32", "a precision made here downloads its published source")
        XCTAssertTrue(bf16.body.hasPrefix("Parakeet v3 at BF16 (bfloat16) is made on this Mac from its FP32 (float32) weights. This downloads those weights"), bf16.body)
        XCTAssertTrue(bf16.body.contains("The BF16 weights are made at load and add nothing on disk."), bf16.body)
        XCTAssertTrue(bf16.body.hasSuffix("When the download finishes, it loads for dictation."))
        let first = try XCTUnwrap(downloadPrompt(family: parakeet, precision: "4b", followUp: .transcribe, freeBytes: 100))
        XCTAssertEqual(first.title, "Download Parakeet v3 · 4 (4-bit)?")
        XCTAssertTrue(first.body.contains("Not enough free disk space."), first.body)
        XCTAssertTrue(first.body.hasSuffix("it loads and transcribes the saved recording."))
        XCTAssertEqual(formatExactBytes(637_004_647), "637,004,647 bytes")
    }

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
