import XCTest
import AppKit
@testable import Vella
@testable import VellaCore

/// A saved recording made at another precision of the selected family is transcribed at its own precision, and the
/// family is put back afterwards. Stop shows idle at once, and a transcription leaves the lane free between segments,
/// so the user can load, reload or unload the family before that happens. Whatever they chose stays: the put-back of
/// an older state never overrides it, however the transcription ended (done, failed or stopped).
final class RecoveryRestoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-recovery-restore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    enum End { case done, failed, stopped }
    enum UserAction { case none, load4b, unload }
    struct Failure: Error {}

    /// Alpha BF16 is selected and loaded. A saved Alpha 4-bit recording is recovered; its one segment is transcribed
    /// by the 4-bit worker and then held. Meanwhile the transcription ends as `end` says (Stop happens while held) and
    /// the user does `action` through the real bridge; then the segment is released and the recovery finishes.
    @MainActor private func recover(end: End, action: UserAction) async throws -> TwoFamilyFixture {
        let f = try TwoFamilyFixture(root)
        try await f.load(f.alpha, "BF16")
        let older = try f.path(f.alpha, "4b")
        let saved = try RecordingSession(root: root.appendingPathComponent("saved"), config: Configuration(model: older))
        let writer = try SegmentedPCMWriter(session: saved)
        try [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        var release: CheckedContinuation<Void, Never>?
        let backend = f.backend
        let model = Model(pasteboard: pasteboard, transcriptionRequest: { url, config in
            let text = try await backend.transcribe(url, config: config)
            await withCheckedContinuation { release = $0 } // the segment has its text; the recovery has not resumed
            if end == .failed { throw Failure() }
            return text
        }, configurationURL: f.runtime.configURL, streamingBackend: f.stream, backend: f.backend)
        model.recover(saved.directory)
        let until = Date().addingTimeInterval(5)
        while release == nil, Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        let held = try XCTUnwrap(release, "the recovery did not reach its segment")
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.precision, "4b", "the recording is transcribed at its own precision")
        if end == .stopped {
            model.cancel()
            XCTAssertFalse(model.busy, "Stop shows idle at once")
        }
        switch action {
        case .none: break
        case .load4b: try await f.load(f.alpha, "4b")
        case .unload: await f.runtime.unload("alpha")
        }
        held.resume()
        switch end {
        case .done: try await waitUntil { model.phase == .success }
        case .failed: try await waitUntil { model.phase == .failed }
        case .stopped: break
        }
        // Long enough for a put-back reload of the fake worker to finish (it loads in well under this).
        try await Task.sleep(nanoseconds: 700_000_000)
        return f
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(5)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
    @MainActor private func assertAlpha(_ f: TwoFamilyFixture, selected precision: String, loaded: String?, launch: [String],
                                        _ context: String) throws {
        XCTAssertEqual(try f.config().model, try f.path(f.alpha, precision), "selected, " + context)
        XCTAssertEqual(f.runtime.loadedRef("alpha")?.precision, loaded, "loaded, " + context)
        XCTAssertEqual(f.runtime.settings.launchSet.map(\.precision), launch, "launch set, " + context)
    }

    @MainActor func testALaterLoadOfTheRecordingsPrecisionStaysAfterStop() async throws {
        let f = try await recover(end: .stopped, action: .load4b); defer { f.close() }
        try assertAlpha(f, selected: "4b", loaded: "4b", launch: ["4b"], "Load 4-bit after Stop")
    }
    @MainActor func testALaterLoadOfTheRecordingsPrecisionStaysWhenTheRecoveryFinishes() async throws {
        let f = try await recover(end: .done, action: .load4b); defer { f.close() }
        try assertAlpha(f, selected: "4b", loaded: "4b", launch: ["4b"], "Load 4-bit before the recovery finished")
    }
    @MainActor func testALaterLoadOfTheRecordingsPrecisionStaysWhenTheRecoveryFails() async throws {
        let f = try await recover(end: .failed, action: .load4b); defer { f.close() }
        try assertAlpha(f, selected: "4b", loaded: "4b", launch: ["4b"], "Load 4-bit before the recovery failed")
    }
    /// Unload keeps the selection, so only the count of the user's changes tells the put-back to stay away.
    @MainActor func testALaterUnloadStaysAfterStop() async throws {
        let f = try await recover(end: .stopped, action: .unload); defer { f.close() }
        try assertAlpha(f, selected: "BF16", loaded: nil, launch: [], "Unload after Stop")
    }
    /// Without a later choice, Stop still puts the selected precision back.
    @MainActor func testStopWithoutALaterChoicePutsTheSelectedPrecisionBack() async throws {
        let f = try await recover(end: .stopped, action: .none); defer { f.close() }
        try assertAlpha(f, selected: "BF16", loaded: "BF16", launch: ["BF16"], "Stop alone")
    }
}
