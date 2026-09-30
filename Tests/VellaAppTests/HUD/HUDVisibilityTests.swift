import XCTest
import AppKit
import SwiftUI
@testable import Vella

final class HUDVisibilityTests: XCTestCase {
    @MainActor func testUsesOriginalDirectHostWithoutSpaceOpacityLayer() {
        _ = NSApplication.shared
        let delegate = AppDelegate(); delegate.configureHUDPanel()
        defer { delegate.panel.close() }
        XCTAssertTrue(delegate.panel.contentView is NSHostingView<HUDView>)
        XCTAssertEqual(delegate.panel.alphaValue, 1)
        XCTAssertEqual(delegate.panel.contentView?.alphaValue, 1)
        XCTAssertFalse(delegate.panel.canBecomeKey)
        XCTAssertFalse(delegate.panel.canBecomeMain)
        XCTAssertFalse(delegate.panel.hidesOnDeactivate)
        XCTAssertEqual(delegate.panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
    }
    @MainActor func testSpaceChangeCannotResurrectIdleOrDismissedFeedback() {
        _ = NSApplication.shared
        let delegate = AppDelegate(); delegate.configureHUDPanel()
        defer { delegate.panel.close() }
        for phase in [Model.Phase.idle, .success, .failed] {
            delegate.model.phase = phase
            delegate.activeSpaceChanged()
            XCTAssertFalse(delegate.panel.isVisible)
            XCTAssertEqual(delegate.model.phase, phase)
        }
    }
    @MainActor func testOpacityRepairKeepsCaptureStateAndDoesNotOpenAWindow() {
        _ = NSApplication.shared
        let delegate = AppDelegate(); delegate.configureHUDPanel()
        defer { delegate.panel.close() }
        let panel = delegate.panel!
        for phase in [Model.Phase.preparing, .recording, .transcribing] {
            delegate.model.phase = phase; delegate.model.audioLevel = 0.65
            panel.alphaValue = 0; panel.contentView?.alphaValue = 0
            delegate.restoreHUDOpacity()
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(panel.contentView?.alphaValue, 1)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(delegate.model.phase, phase)
            XCTAssertEqual(delegate.model.audioLevel, 0.65)
        }
    }
}
