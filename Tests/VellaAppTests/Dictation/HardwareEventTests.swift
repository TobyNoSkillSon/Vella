import XCTest
import AVFoundation
import AppKit
import VellaCore
@testable import Vella

final class HardwareEventTests: XCTestCase {
    private func session(_ mode: RecognitionMode) throws -> RecordingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hardware-events-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: Configuration(model: "/fixture", mode: mode, streamingModel: "/fixture/stream"))
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }; try writer.finish(userStopped: false)
        return session
    }
    @MainActor func testSleepWakeEndsBothModesKeepsAudioAndNeverRestartsCapture() throws {
        for mode in RecognitionMode.allCases {
            let session = try session(mode)
            let center = NotificationCenter()
            let config = session.directory.appendingPathComponent("config.json")
            try JSONEncoder().encode(session.manifest.config).write(to: config)
            let model = DictationController(configurationURL: config, workspaceNotifications: center, monitorDefaultInput: false)
            defer { model.shutdown() }
            model.recorder.adoptForTesting(session); model.phase = .recording
            let before = try Data(contentsOf: session.directory.appendingPathComponent(session.manifest.segments[0].filename))
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            XCTAssertEqual(model.phase, .failed); XCTAssertTrue(model.message.contains("went to sleep"))
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertEqual(model.phase, .failed); XCTAssertTrue(model.message.contains("Mac woke"))
            XCTAssertTrue(model.message.contains("Retry copies only")); XCTAssertFalse(model.insertionWasAutomatic)
            XCTAssertEqual(model.savedSession?.directory, session.directory)
            XCTAssertEqual(try Data(contentsOf: session.directory.appendingPathComponent(session.manifest.segments[0].filename)), before)
            XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.state, "interrupted")
        }
    }
    @MainActor func testWakeWithoutPriorSleepNotificationFailsClosed() throws {
        let session = try session(.dictation), center = NotificationCenter()
        let model = DictationController(workspaceNotifications: center, monitorDefaultInput: false); defer { model.shutdown() }
        model.recorder.adoptForTesting(session); model.phase = .recording
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(model.phase, .failed); XCTAssertTrue(model.message.contains("Mac woke")); XCTAssertNotNil(model.savedSession)
    }
    @MainActor func testDeviceAndCaptureNotificationsAreFilteredAndEndRecording() throws {
        let session = try session(.streaming), workspace = NotificationCenter(), capture = NotificationCenter()
        let model = DictationController(workspaceNotifications: workspace, monitorDefaultInput: false); defer { model.shutdown() }
        model.recorder.adoptForTesting(session); model.phase = .recording
        let selected = NSObject(), other = NSObject()
        let events = HardwareEvents(
            workspace: workspace, capture: capture,
            matchesCapture: { ($0 as? NSObject) === selected }, matchesDevice: { ($0 as? NSObject) === selected },
            monitorDefaultInput: false, receive: model.hardwareEvent)
        defer { events.stop() }
        capture.post(name: AVCaptureDevice.wasDisconnectedNotification, object: other)
        XCTAssertEqual(model.phase, .recording)
        capture.post(name: AVCaptureDevice.wasDisconnectedNotification, object: selected)
        XCTAssertEqual(model.phase, .failed); XCTAssertTrue(model.message.contains("microphone disconnected, switched"))
        XCTAssertNotNil(model.savedSession); XCTAssertFalse(model.insertionWasAutomatic)
        model.phase = .recording
        capture.post(name: AVCaptureSession.runtimeErrorNotification, object: selected)
        XCTAssertEqual(model.phase, .failed)
    }
    @MainActor func testRevokedAccessibilityDropsQueuedInsertionButKeepsRecognitionCheckpoint() throws {
        let session = try session(.streaming), config = session.directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(session.manifest.config).write(to: config)
        let journal = try StreamingJournal(directory: session.directory)
        try journal.append(committed: "saved words", partial: "tail", frames: 1600); journal.close()
        var trusted = true, writes: [String] = []
        let permission = InsertionPermission(isTrusted: { trusted }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(insertionPermission: permission, configurationURL: config, monitorDefaultInput: false); defer { model.shutdown() }
        model.recorder.adoptForTesting(session); model.phase = .recording
        model.prepareLiveInsertion(send: { writes.append($0) })
        model.liveInsertion?.offer(committed: "", partial: "do not post")
        trusted = false; model.recordingTick(error: nil)
        model.liveInsertion?.flush()
        XCTAssertEqual(writes, []); XCTAssertEqual(model.phase, .recording)
        XCTAssertTrue(model.message.contains("Accessibility access was revoked")); XCTAssertTrue(model.message.contains("Microphone capture continues"))
        trusted = true; model.liveInsertion?.offer(committed: "", partial: "still do not post"); model.liveInsertion?.flush()
        XCTAssertEqual(writes, [], "Re-granting never resumes an uncertain insertion")
        XCTAssertTrue(try XCTUnwrap(StreamingJournal.recover(directory: session.directory)).contains("saved words tail"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent(session.manifest.segments[0].filename).path))
    }
}
