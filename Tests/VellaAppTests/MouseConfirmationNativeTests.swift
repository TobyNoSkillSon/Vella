import XCTest
import AppKit
import VellaCore
@testable import Vella

final class MouseConfirmationNativeTests: XCTestCase {
    @MainActor private func trackingTimer(_ delay: TimeInterval, action: @escaping @MainActor () -> Void) -> Timer {
        Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    func testAdditionalButtonNamesAreBoundedWithoutOverflow() {
        for number in Int64(5)...31 {
            XCTAssertEqual(ShortcutManager.mouseConfirmationDetectedLabel(forButtonNumber: number, eventType: .otherMouseDown), "Button \(number + 1) detected")
        }
        XCTAssertEqual(ShortcutManager.mouseConfirmationDetectedLabel(forButtonNumber: .max, eventType: .otherMouseDown), "Other button detected")
    }

    /// Actual native menu tracking, synthetic events passed directly to the real
    /// confirmation handler. No global input posting, live tap or audio capture.
    @MainActor func testConfirmationAndTimeoutUpdateBeforeNativeMenuCloses() throws {
        guard ProcessInfo.processInfo.environment["VELLA_MENU_TRACKING_QA"] == "1" else {
            throw XCTSkip("Opt-in native menu tracking")
        }
        _ = NSApplication.shared
        let appearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = appearance }
        for confirm in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = Model(configurationURL: root.appendingPathComponent("config.json"))
            defer { model.shutdown() }
            let registrar = MouseConfirmationTests.MouseConfirmRegistrar()
            let monitor = MouseConfirmationTests.MouseConfirmMonitor()
            var starts = 0
            let engine = ShortcutEngine(configuration: .default, sinks: .init(
                start: { starts += 1 }, finish: { XCTFail("Confirmation must not finish capture") },
                cancel: {}, isRecording: { false }, isBusy: { false }))
            let manager = ShortcutManager(engine: engine, store: ShortcutStore(fileURL: nil), registrar: registrar)
            manager.confirmationAccessCheck = { true }
            manager.makeConfirmationMonitor = { monitor }
            manager.confirmationTimeoutInterval = confirm ? 2 : 0.2
            let delegate = AppDelegate(model: model, shortcutManager: manager)
            delegate.rebuildMenu()
            let shortcuts = try XCTUnwrap(delegate.menu.item(withTitle: "Shortcuts")?.submenu)
            let mouse = try XCTUnwrap(shortcuts.item(withTitle: "Mouse Button")?.submenu)
            let row = try XCTUnwrap(mouse.item(withTitle: "Side Button 4") as? SettingsMenuItem)
            let originalRows = mouse.items
            var checked = false
            let select = trackingTimer(0.05) {
                let originalWidth = row.view?.frame.width
                row.control.performClick(nil)
                XCTAssertEqual(manager.configuration, .default)
                XCTAssertEqual(row.control.title, "Press side button 4 to confirm…")
                XCTAssertEqual(row.view?.frame.width, originalWidth, "Reserve prompt width before tracking")
                if let directory = ProcessInfo.processInfo.environment["VELLA_MOUSE_QA_IMAGES"],
                   let view = row.view,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("confirmation-row.png"))
                }
            }
            // performClick briefly runs AppKit's own tracking loop. Deliver the
            // synthetic confirmation after that selection action has returned.
            let wrong = trackingTimer(0.3) {
                guard confirm else { return }
                let event = CGEvent(source: nil)!
                event.type = .otherMouseDown
                event.setIntegerValueField(.mouseEventButtonNumber, value: 4)
                XCTAssertEqual(monitor.handler?(.otherMouseDown, event), false)
                XCTAssertEqual(manager.configuration, .default)
            }
            let feedback = trackingTimer(0.4) {
                guard confirm else { return }
                XCTAssertEqual(manager.pendingMouseButton, .button3)
                XCTAssertTrue(row.control.title.contains("Button 5 detected"))
                XCTAssertTrue(row.control.title.hasPrefix("Press side button 4 to confirm…"))
                if let directory = ProcessInfo.processInfo.environment["VELLA_MOUSE_QA_IMAGES"],
                   let view = row.view,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("wrong-button-row.png"))
                }
            }
            let press = trackingTimer(0.5) {
                guard confirm else { return }
                for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                    let event = CGEvent(source: nil)!
                    event.type = type
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
                    XCTAssertEqual(monitor.handler?(type, event), true)
                }
            }
            let inspect = trackingTimer(0.8) {
                checked = true
                XCTAssertTrue(row.view?.window?.isVisible == true)
                XCTAssertNil(manager.pendingMouseButton)
                XCTAssertEqual(starts, 0)
                for (before, after) in zip(originalRows, mouse.items) { XCTAssertTrue(before === after) }
                if confirm {
                    XCTAssertEqual(manager.configuration.trigger, .mouseButton(button: .button3))
                    XCTAssertEqual(row.control.title, "Side Button 4")
                    XCTAssertEqual(row.control.state, .on)
                    XCTAssertNotEqual(row.control.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
                } else {
                    XCTAssertEqual(manager.configuration, .default)
                    XCTAssertEqual(row.control.title, "Button not detected")
                }
                if let directory = ProcessInfo.processInfo.environment["VELLA_MOUSE_QA_IMAGES"],
                   let view = row.view,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent(confirm ? "confirmed-row.png" : "timeout-row.png"))
                }
                mouse.cancelTracking()
            }
            let watchdog = trackingTimer(3) {
                mouse.cancelTracking()
            }
            let timers = [select, wrong, feedback, press, inspect, watchdog]
            for timer in timers { RunLoop.main.add(timer, forMode: .eventTracking) }
            delegate.menuWillOpen(delegate.menu)
            mouse.popUp(positioning: nil, at: NSPoint(x: 300, y: 300), in: nil)
            delegate.menuDidClose(delegate.menu)
            for timer in timers { timer.invalidate() }
            XCTAssertTrue(checked, "Native menu must stay open until confirmation/timeout is rendered")
            XCTAssertNil(manager.pendingMouseButton)
        }
    }
}
