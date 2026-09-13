import XCTest
import Foundation
import AppKit
@testable import Vella
@testable import VellaCore
final class BackendTests: XCTestCase {
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
