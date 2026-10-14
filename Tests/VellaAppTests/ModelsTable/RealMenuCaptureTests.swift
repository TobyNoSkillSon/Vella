import XCTest
import AppKit
import VellaTestSupport
import VellaUpdate
@testable import Vella
@testable import VellaCore

/// Opt-in README capture of the real menu: `VELLA_REAL_MENU_CAPTURE=<folder>` opens the native NSMenu on screen for
/// about a second over a plain dark backdrop and saves its window (no shadow) as `menu-current.png`. Unlike MenuMock this
/// is macOS's own menu drawing: material, icons, check marks and key equivalents. Needs Screen Recording permission
/// for the process running the test; it activates the test process while the menu is open.
final class RealMenuCaptureTests: XCTestCase {
    @MainActor func testCaptureRealMenuWhileDictating() throws {
        guard let folder = ProcessInfo.processInfo.environment["VELLA_REAL_MENU_CAPTURE"] else { throw XCTSkip("Opt-in README capture") }
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: RenderFixture.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: RenderFixture.root) }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VellaRealMenuCapture.\(UUID())"))
        let model = DictationController(
            insertionPermission: InsertionPermission(isTrusted: { true }, prompt: {}), configurationURL: out.appendingPathComponent("unused-config.json"))
        defer { model.shutdown() }
        let app = AppDelegate(model: model, updates: UpdateController(current: nil, defaults: defaults, enabled: false))
        let controller = RenderFixture.controller(installed: RenderFixture.downloaded)
        controller.runtime = TableRuntime(
            loaded: ["parakeet-v3-ultra": LoadedFamily(precision: "bf16", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual")],
            chip: RenderFixture.chip)
        app.modelsMenu = ModelsMenu(controller: controller)
        app.menuSettings = DefaultMenuSettings(availableMB: 86_900)
        app.pendingModelRow = { nil }; app.workersRunning = { true }
        app.factLine = { "1 model loaded · 1.6 GB in memory" }
        model.lastText = "Rendered transcript"
        model.update(.recording, "")
        app.rebuildMenu()
        let header = try XCTUnwrap(app.menu.items.first?.title)
        XCTAssertTrue(header.hasPrefix("Dictation: listening · Parakeet v3 Ultra"), header)

        // A plain backdrop under the menu, so its material blurs a known colour instead of whatever is on screen.
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let anchor = NSPoint(x: screen.maxX - 460, y: screen.maxY - 24)
        let backdrop = NSWindow(
            contentRect: NSRect(x: anchor.x - 60, y: anchor.y - 900, width: 520, height: 920), styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        backdrop.level = .floating; backdrop.isReleasedWhenClosed = false
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)

        let file = out.appendingPathComponent("menu-current.png")
        try? FileManager.default.removeItem(at: file)
        var captured = false
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                defer { app.menu.cancelTracking() }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let menuWindow = windows.first {
                    ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                        && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
                }
                guard let id = menuWindow?[kCGWindowNumber as String] as? Int else { return }
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l\(id)", file.path]
                try? shot.run(); shot.waitUntilExit()
                captured = shot.terminationStatus == 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        app.menu.popUp(positioning: nil, at: anchor, in: nil)
        XCTAssertTrue(captured, "menu window not found or not captured")
        let image = try XCTUnwrap(NSImage(contentsOf: file))
        XCTAssertGreaterThan(image.size.height, 300)
    }
}
