import XCTest
import AppKit
@testable import Vella
import VellaCore

final class FinishFocusTests: XCTestCase {
    @MainActor private final class Focus {
        var current: String? = "A"
        var snapshots: [String?] = []
        func capture() -> Model.DestinationCheck {
            let selected = current
            snapshots.append(selected)
            return { [self] in
                guard let selected else { return "Missing field at Finish" }
                return selected == current ? nil : "Finish target changed"
            }
        }
    }
    @MainActor private func fixture(mode: RecognitionMode = .dictation, focus: Focus,
                                    stop: @escaping (Recorder) async throws -> Void) throws -> (Model, NSPasteboard, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finish-focus-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.json")
        var settings = Configuration(executable: "/unused", model: "/synthetic")
        settings.mode = mode
        try JSONEncoder().encode(settings).write(to: config)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = Model(pasteboard: board, stopCapture: stop, configurationURL: config,
                          captureDestination: { focus.capture() })
        // Synthetic recording state only: no microphone, native focus, or key events.
        model.phase = .recording
        return (model, board, root)
    }

    @MainActor func testStartAFinishBSnapshotsBeforeUICallbackAndAsyncDrain() async throws {
        let focus = Focus()
        let drained = expectation(description: "Drain")
        let (model, board, _) = try fixture(focus: focus) { _ in
            XCTAssertEqual(focus.snapshots.compactMap { $0 }, ["B"])
            XCTAssertEqual(focus.current, "C", "UI callback has already run, without retargeting")
            drained.fulfill()
            throw VellaError.message("Synthetic drain failure")
        }
        defer { model.onChange = nil; model.cancel(); board.releaseGlobally() }
        XCTAssertTrue(focus.snapshots.isEmpty, "Recording at A owns no destination")
        focus.current = "B"
        model.onChange = { if model.phase == .transcribing { focus.current = "C" } }
        model.finish()
        XCTAssertEqual(focus.snapshots.compactMap { $0 }, ["B"], "Capture must happen before finish returns")
        XCTAssertEqual(model.currentTargetBlockReason, "Finish target changed")
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testChangedFocusDuringProcessingCannotRedirectAndCancelClearsSnapshot() async throws {
        let focus = Focus()
        var drain: CheckedContinuation<Void, Error>?
        let started = expectation(description: "Drain suspended")
        let restarted = expectation(description: "Second drain suspended")
        var drains = 0
        let (model, board, _) = try fixture(focus: focus) { _ in
            try await withCheckedThrowingContinuation {
                drain = $0; drains += 1
                if drains == 1 { started.fulfill() } else { restarted.fulfill() }
            }
        }
        defer { model.cancel(); board.releaseGlobally() }
        focus.current = "B"; model.finish()
        XCTAssertNil(model.currentTargetBlockReason)
        await fulfillment(of: [started], timeout: 2)
        focus.current = "C"
        XCTAssertEqual(model.currentTargetBlockReason, "Finish target changed")
        XCTAssertEqual(focus.snapshots.compactMap { $0 }, ["B"])
        model.cancel()
        XCTAssertNotNil(model.currentTargetBlockReason, "Cancellation must release the snapshot")
        XCTAssertEqual(model.automaticInsertionBlockReason, "Recovered or cancelled recordings are clipboard-only.")
        let settled = expectation(description: "Cancelled drain settled")
        model.onChange = { if model.phase == .idle { settled.fulfill() } }
        drain?.resume()
        await fulfillment(of: [settled], timeout: 2)
        model.onChange = nil
        // A new recording must capture a fresh target, not B.
        model.phase = .recording; focus.current = "D"; model.finish()
        XCTAssertEqual(focus.snapshots.compactMap { $0 }, ["B", "D"])
        model.cancel()
        await fulfillment(of: [restarted], timeout: 2)
        let settledAgain = expectation(description: "Second cancellation settled")
        model.onChange = { if model.phase == .idle { settledAgain.fulfill() } }
        drain?.resume(throwing: CancellationError())
        await fulfillment(of: [settledAgain], timeout: 2)
        model.onChange = nil
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testMissingFinishFocusNeverRecapturesLaterField() async throws {
        let focus = Focus(); focus.current = nil
        let failed = expectation(description: "Failed safely")
        let (model, board, _) = try fixture(focus: focus) { _ in throw VellaError.message("Synthetic failure") }
        defer { model.onChange = nil; model.cancel(); board.releaseGlobally() }
        model.onChange = { if model.phase == .failed { failed.fulfill() } }
        model.finish(); focus.current = "B"
        XCTAssertEqual(model.currentTargetBlockReason, "Missing field at Finish")
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testStreamingFinishDoesNotCaptureDestination() async throws {
        let focus = Focus()
        let failed = expectation(description: "Fixture drain failed")
        let (model, board, _) = try fixture(mode: .streaming, focus: focus) { _ in throw VellaError.message("Synthetic failure") }
        defer { model.onChange = nil; model.cancel(); board.releaseGlobally() }
        model.onChange = { if model.phase == .failed { failed.fulfill() } }
        model.finish()
        XCTAssertTrue(focus.snapshots.isEmpty)
        XCTAssertNotNil(model.currentTargetBlockReason)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testRecoveryAndRetryClearFinishTargetAndCopyOnly() async throws {
        let focus = Focus()
        let failed = expectation(description: "Drain failed")
        let (model, board, root) = try fixture(focus: focus) { _ in throw VellaError.message("Synthetic failure") }
        defer { model.onChange = nil; model.cancel(); board.releaseGlobally() }
        model.onChange = { if model.phase == .failed { failed.fulfill() } }
        model.finish()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNil(model.currentTargetBlockReason, "Fixture still has a valid Finish snapshot before recovery")
        let session = try RecordingSession(root: root, config: .init(executable: "/unused", model: "/synthetic"))
        let samples = [Float](repeating: 0.1, count: 16000)
        let data = samples.withUnsafeBytes { Data($0) }
        let segment = RecordingSession.Segment(index: 0, frames: samples.count, peakRMS: 0.1,
            finalized: true, text: "Saved synthetic transcript.", sha256: RecordingSession.digest(data))
        try session.durableWrite(data, to: session.directory.appendingPathComponent(segment.filename))
        session.manifest.segments = [segment]; session.manifest.state = "captured"; try session.save()
        for retry in [false, true] {
            let copied = expectation(description: "Recovery copied")
            model.onChange = { if model.phase == .success { copied.fulfill() } }
            if retry { model.phase = .failed; model.retry() } else { model.recover(session.directory) }
            XCTAssertNotNil(model.currentTargetBlockReason)
            XCTAssertEqual(model.automaticInsertionBlockReason, "Recovered or cancelled recordings are clipboard-only.")
            await fulfillment(of: [copied], timeout: 3)
            XCTAssertEqual(board.string(forType: .string), "Saved synthetic transcript.")
            XCTAssertFalse(model.insertionWasAutomatic)
        }
        XCTAssertEqual(focus.snapshots.count, 1, "Recovery and Retry never capture current focus")
    }
}
