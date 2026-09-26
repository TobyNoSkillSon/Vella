import XCTest
import Foundation
import AppKit
@testable import Vella
@testable import VellaCore
final class BackendTests: XCTestCase {
    @MainActor func testOptInNativeParakeetOnPublicClipAndRetirement() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let helper = env["VELLA_TEST_DICTATION_HELPER"], let weights = env["VELLA_TEST_DICTATION_MODEL"],
              let clip = env["VELLA_TEST_PUBLIC_CLIP"] else { throw XCTSkip("Opt-in native helper, local public clip and Q4 weights required") }
        let status = Backend.support.appendingPathComponent("dictation-status.json")
        guard let data = try? Data(contentsOf: status),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["phase"] as? String == "idle" else { throw XCTSkip("Vella is not idle") }
        let backend = Backend(helper: URL(fileURLWithPath: helper))
        defer { backend.shutdown() }
        let result = try await backend.transcribe(URL(fileURLWithPath: clip), config: Configuration(model: weights))
        XCTAssertEqual(result, "Saturday, august fifteenth. The sea unbroken all round. No land in sight,")
        let pid = try XCTUnwrap(backend.processID)
        try await backend.releaseAndWait()
        XCTAssertNil(backend.processID)
        XCTAssertNotEqual(kill(pid, 0), 0)
        print("Native Q4 public-clip transcript: \(result)")
    }
    @MainActor func testMissingNativeHelpersFailBeforeLaunchWithActionableErrors() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-vella-helper-\(UUID())")
        let dictation = Backend(helper: missing)
        XCTAssertThrowsError(try dictation.workerURL()) { error in
            XCTAssertTrue(error.localizedDescription.contains("native dictation helper"))
            XCTAssertTrue(error.localizedDescription.contains("Reinstall"))
        }
        let streaming = StreamingBackend(helper: missing)
        XCTAssertThrowsError(try streaming.workerURL()) { error in
            XCTAssertTrue(error.localizedDescription.contains("native streaming helper"))
            XCTAssertTrue(error.localizedDescription.contains("Reinstall"))
        }
        streaming.shutdown(); dictation.shutdown()
    }
    @MainActor func testNativeHelperLaunchFailureRetainsSavedAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bad-native-helper-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("VellaWorker")
        try Data("not a Mach-O or script".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let audio = dir.appendingPathComponent("audio.wav")
        try Data("fixture".utf8).write(to: audio)
        let backend = Backend(helper: helper)
        do { _ = try await backend.transcribe(audio, config: Configuration(model: "/fixture/model")); XCTFail("Executed invalid helper") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not start")) }
        XCTAssertEqual(try Data(contentsOf: audio), Data("fixture".utf8))
        XCTAssertNil(backend.processID)
        backend.shutdown()
        let stream = StreamingBackend(helper: helper)
        defer { stream.shutdown() }
        let config = try Configuration(model: "", mode: .streaming, streamingModel: "/fixture/stream").forRecording()
        do { try await stream.start(config: config); XCTFail("Executed invalid streaming helper") }
        catch { XCTAssertTrue(error.localizedDescription.contains("native streaming helper could not start")) }
        XCTAssertNil(stream.processID)
    }
    @MainActor func testNativeMicrophoneEnumeration() throws {
        let devices = Recorder.devices()
        // Enumeration is read-only; this test never starts the microphone.
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty })
    }
    @MainActor func testPrivateBackendWithSyntheticAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_TEST_AUDIO"] else {
            throw XCTSkip("Opt-in test: set VELLA_TEST_AUDIO to synthetic speech WAV.")
        }
        let backend = Backend()
        let config = try backend.configuration()
        let text = try await backend.transcribe(URL(fileURLWithPath: path), config: config)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("dictation"), "Unexpected synthetic transcript: \(text)")
        XCTAssertEqual(backend.ownership, "Vella private worker")
        backend.stop()
        XCTAssertNil(backend.processID)
    }
    @MainActor func testMenuUsesNativeItemsNotPopoverViews() {
        _ = NSApplication.shared
        let delegate = AppDelegate(model: Model(configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-vella-config-\(UUID()).json")))
        delegate.rebuildMenu()
        XCTAssertTrue(delegate.menu.items.allSatisfy { $0.view == nil })
        XCTAssertTrue(delegate.menu.items.contains { $0.title == "Start Dictation" })
        XCTAssertTrue(delegate.menu.items.contains { $0.title == "Quit Vella" })
        XCTAssertTrue(delegate.menu.items.contains { $0.title == "Microphone" && $0.submenu != nil })
    }
    @MainActor func testRecordingMenuOffersFinishAndCancel() {
        _ = NSApplication.shared
        let delegate = AppDelegate(model: Model(configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-vella-config-\(UUID()).json")))
        delegate.model.phase = .recording
        delegate.rebuildMenu()
        XCTAssertTrue(delegate.menu.items.contains { $0.title == "Finish Dictation" })
        XCTAssertTrue(delegate.menu.items.contains { $0.title == "Stop and Keep Audio" })
        XCTAssertFalse(delegate.menu.items.contains { $0.title == "Start Dictation" })
    }
}
