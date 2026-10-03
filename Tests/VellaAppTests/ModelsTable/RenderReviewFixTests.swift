import XCTest
import AppKit
import SwiftUI
import ServiceManagement
@testable import Vella
@testable import VellaCore

@MainActor final class RenderReviewFixTests: XCTestCase {
    func testOnlyTheActualRunningPathGetsTheWarmTint() throws {
        for row in TierControl.Row.allCases {
            let control = TierControl(selected: .init(.optimized, "8"), enabled: true, hot: true, loaded: .init(row, "16"), help: { _ in "" }, onSelect: { _ in })
            XCTAssertEqual(control.isHot(.optimized), row == .optimized)
            XCTAssertEqual(control.isHot(.standard), row == .standard)
            XCTAssertEqual(TierControl.tint(row, hot: true), TierControl.hotBoltTint)
        }
        XCTAssertEqual(TierControl.tint(.optimized, hot: false), TierControl.boltTint)
        XCTAssertNil(TierControl.tint(.standard, hot: false))
        let state = try XCTUnwrap(TableRenderDelegate.states().first { $0.name == "mlx-fallback" })
        let controller = TableRenderDelegate.controller(state)
        let family = try XCTUnwrap(controller.catalog.family("parakeet-v3"))
        XCTAssertTrue(controller.fellBack(family))
        XCTAssertTrue(controller.loadedEngineHelp(family).contains("non-finite"))
        XCTAssertTrue(controller.loadedEngineHelp(family).contains("Fast or Exact will retry on the next load"))
        controller.runtime?.loaded[family.id]?.selection?.path = .standard
        XCTAssertFalse(controller.fellBack(family), "Explicit Standard is not a fallback")
    }

    func testAllMeasuredDeltasFitTheirColumnsAtTheNarrowestTableSize() {
        let controller = RenderFixture.controller()
        let font = NSFont.monospacedDigitSystemFont(ofSize: ModelTable.deltaSize, weight: .regular)
        for family in controller.catalog.families {
            let base = controller.baseResult(family)
            for tier in ModelTier.allCases {
                for cell in controller.benchmark(family)?.tiers[tier]?.cells.values ?? [:].values {
                    let result = cell.result
                    for (delta, width) in [
                        (speedDelta(result.speed_x, base: base?.speed_x), ModelTable.W.speed), (energyDelta(result.j_per_min, base: base?.j_per_min), ModelTable.W.energy)
                    ] {
                        guard let delta else { continue }
                        let size = (delta.text as NSString).size(withAttributes: [.font: font])
                        XCTAssertLessThanOrEqual(size.width, width, "\(family.id) \(tier): \(delta.text)")
                    }
                }
            }
        }
    }

    func testMicrophoneCaptionFollowsTheSelectionWithoutRebuildingTheTrackedMenu() {
        let menu = NSMenu(); menu.addItem(withTitle: "System Default Input", action: nil, keyEquivalent: "")
        AppDelegate.updateMicrophoneCaption(menu, selected: "USB Microphone")
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertFalse(menu.item(withTitle: AppDelegate.microphoneFallbackCaption)?.isEnabled ?? true)
        AppDelegate.updateMicrophoneCaption(menu, selected: "Another Microphone")
        XCTAssertEqual(menu.items.count, 3, "No duplicated captions")
        AppDelegate.updateMicrophoneCaption(menu, selected: "")
        XCTAssertEqual(menu.items.count, 1, "System Default has no caption or trailing separator")
    }

    func testRecoveryDurationExcludesTheSegmentOverlap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-duration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: Configuration(model: "/fixture"))
        session.manifest.segments = [.init(index: 0, frames: 320_000), .init(index: 1, frames: 360_000, overlapFrames: 8_000)]
        session.manifest.state = "interrupted"; try session.save()
        let choice = try XCTUnwrap(SavedRecordingChoice.list(root: root).first)
        XCTAssertTrue(choice.title.contains("Dictation · 0:42 · interrupted"))
    }

    func testAccessibilityWarningHasTheSettingsActionInEveryPhase() throws {
        let permission = InsertionPermission(isTrusted: { false }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(insertionPermission: permission, monitorDefaultInput: false)
        defer { model.shutdown() }
        let app = AppDelegate(model: model)
        for phase in [DictationController.Phase.idle, .failed, .recording, .success] {
            model.phase = phase; app.rebuildMenu()
            let header = try XCTUnwrap(app.menu.items.first)
            XCTAssertEqual(header.action, NSSelectorFromString("accessibility"))
            XCTAssertTrue(header.target === app); XCTAssertTrue(header.isEnabled)
            XCTAssertFalse(app.menu.autoenablesItems)
        }
    }

    func testOtherWarningHeadersNameAndOpenTheirRemedy() throws {
        let permission = InsertionPermission(isTrusted: { true }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(insertionPermission: permission, monitorDefaultInput: false)
        defer { model.shutdown() }
        let app = AppDelegate(model: model); model.phase = .failed
        for (message, action) in [("Microphone unavailable", "openMicrophoneChoices"), ("Model unavailable", "openModelChoices"), ("Accessibility revoked", "accessibility")] {
            model.message = message; app.rebuildMenu()
            XCTAssertEqual(app.menu.items.first?.action, NSSelectorFromString(action))
            XCTAssertTrue(app.menu.items.first?.isEnabled == true)
        }
        app.pendingModelRow = { ("Get model", "Get then transcribe") }; app.rebuildMenu()
        XCTAssertEqual(app.menu.items.first?.action, NSSelectorFromString("getPending"))
    }

    func testDMGIconLocationsMatchTheSealedContentLayout() throws {
        let root = ModelLibrary.resourceDirectory().appendingPathComponent("DMG")
        let layout = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Layout.plist")), format: nil) as? [String: Any])
        let store = try Data(contentsOf: root.appendingPathComponent("FinderLayout"))
        let positions = store.indices.filter { store[$0...].starts(with: Data("Ilocblob".utf8)) }
        XCTAssertEqual(positions.count, 2)
        for position in positions {
            let y = store[(position + 16)..<(position + 20)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            XCTAssertEqual(Int(y), layout["appY"] as? Int)
            XCTAssertEqual(Int(y), layout["applicationsY"] as? Int)
            // 28 pt title bar; icon 96 pt, 8 pt gap and 16 pt label: group centre is y + 12.
            XCTAssertEqual(Double(y) + 12, (360.0 - 28) / 2, accuracy: 0.5)
        }
    }

    func testLaunchAtLoginApprovalRegistrationAndFailureBranchesWithoutChangingRegistration() throws {
        let model = DictationController(monitorDefaultInput: false); defer { model.shutdown() }
        let app = AppDelegate(model: model)
        var status: SMAppService.Status = .requiresApproval, calls: [String] = []
        app.loginStatus = { status }; app.openLoginSettings = { calls.append("settings") }
        app.registerLogin = { calls.append("register") }; app.unregisterLogin = { calls.append("unregister") }
        try app.changeLogin(); status = .enabled; try app.changeLogin(); status = .notRegistered; try app.changeLogin()
        XCTAssertEqual(calls, ["settings", "unregister", "register"])
        app.registerLogin = { throw VellaError.message("fixture registration failed") }
        XCTAssertThrowsError(try app.changeLogin()) { error in
            let alert = AppDelegate.loginFailureAlert(error)
            XCTAssertEqual(alert.messageText, "Could not change Launch at Login")
            XCTAssertTrue(alert.informativeText.contains("Login Items & Extensions"))
        }
    }

    /// Opt-in offscreen renders of just R1–R7. Native controls are drawn, never clicked or driven.
    func testRenderAffectedStates() throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_RENDER_REVIEW_DIR"] else { throw XCTSkip("Offscreen review renders are opt-in") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        func render(_ name: String, _ draw: (URL, @escaping () -> Void) -> Void) {
            let done = expectation(description: name)
            draw(directory.appendingPathComponent(name + ".png")) { done.fulfill() }
            wait(for: [done], timeout: 8)
        }
        for name in ["mlx-fallback", "loaded", "downloaded-nothing-loaded", "reference-label-M5-Pro-20", "reference-label-M5-Max-32"] {
            let state = try XCTUnwrap(TableRenderDelegate.states().first { $0.name == name })
            render("models-" + name) { TableRenderDelegate.renderTable(TableRenderDelegate.controller(state), to: $0, done: $1) }
        }
        var selfTest = TableRenderDelegate.State(name: "self-test-fallback")
        selfTest.runtime.loaded = [
            "nemotron-3.5-streaming-0.6b": LoadedFamily(
                precision: "BF16", engine: "mlx", engineReason: "fused conformer self-test failed: streamed text did not match Standard",
                selection: ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        ]
        let fallback = TableRenderDelegate.controller(selfTest)
        render("models-self-test-fallback") { TableRenderDelegate.renderTable(fallback, to: $0, done: $1) }
        let family = try XCTUnwrap(fallback.catalog.family("nemotron-3.5-streaming-0.6b"))
        render("fallback-tooltip") { MenuMock.capture(TooltipSheet(pairs: [("Fell back to Standard", fallback.loadedEngineHelp(family))], width: 620), to: $0, done: $1) }
        for name in ["installer-signing-terminal-declined", "installer-signing-noninteractive", "installer-launch-failure"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name + ".txt"), encoding: .utf8)
            render(name) { MenuMock.capture(CLIOutputView(text), to: $0, done: $1) }
        }
        let permission = InsertionPermission(isTrusted: { false }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(insertionPermission: permission, configurationURL: RenderFixture.root.appendingPathComponent("r-fixes.json"), monitorDefaultInput: false)
        defer { model.shutdown() }
        let app = AppDelegate(model: model); app.modelsMenu = ModelsMenu(controller: RenderFixture.controller())
        for selected in ["", "USB Microphone"] {
            let items = NSMenu(); items.addItem(withTitle: "System Default Input", action: nil, keyEquivalent: "")
            items.addItem(withTitle: "USB Microphone", action: nil, keyEquivalent: "")
            items.items[selected.isEmpty ? 0 : 1].state = .on
            AppDelegate.updateMicrophoneCaption(items, selected: selected)
            render(selected.isEmpty ? "default-microphone" : "custom-microphone") { MenuMock.render(items.items, width: 300, to: $0, done: $1) }
        }
        let upgradeRoot = RenderFixture.root.appendingPathComponent("upgrader")
        try FileManager.default.createDirectory(at: upgradeRoot, withIntermediateDirectories: true)
        let upgradeRuntime = Runtime(support: upgradeRoot, environment: [:])
        let upgradeConfig = Configuration(model: "", preferredMicrophone: "", fallbackMicrophone: "MacBook Pro Microphone")
        try JSONEncoder().encode(upgradeConfig).write(to: upgradeRuntime.configURL)
        let upgraded = DictationController(
            insertionPermission: permission, configurationURL: upgradeRuntime.configURL, backend: Backend(runtime: upgradeRuntime), monitorDefaultInput: false)
        defer { upgraded.shutdown() }
        upgraded.chooseMicrophone("")
        let upgradeApp = AppDelegate(model: upgraded)
        upgradeApp.microphoneInputs = { [Microphone(id: 1, name: "MacBook Pro Microphone"), Microphone(id: 2, name: "USB Microphone")] }
        upgradeApp.rebuildMenu()
        let choicesMenu = try XCTUnwrap(upgradeApp.menu.item(withTitle: "Microphone")?.submenu)
        render("upgrader-system-default-microphone") { MenuMock.render(choicesMenu.items, width: 300, to: $0, done: $1) }
        upgraded.phase = .preparing; upgraded.hardwareEvent(.willSleep); upgraded.hardwareEvent(.didWake)
        upgradeApp.rebuildMenu()
        // The preparation message is rendered directly; AX guidance can override the main-menu header independently.
        render("menu-preparation-sleep-wake") { MenuMock.render([NSMenuItem(title: upgraded.message, action: nil, keyEquivalent: "")], width: 340, to: $0, done: $1) }
        try model.selectMode(.streaming); model.phase = .recording
        model.message = "Accessibility access was revoked. Audio and the transcript are still saved. Microphone capture continues."
        app.rebuildMenu()
        render("menu-streaming-accessibility-revoked") { MenuMock.render(app.menu.items, width: 340, to: $0, done: $1) }
        let choices = [SavedRecordingChoice(directory: URL(fileURLWithPath: "/fixture"), title: "3 Oct 2026 at 12:00 · Dictation · 0:42 · interrupted")]
        render("alert-recovery") { TableRenderDelegate.renderAlert(AppDelegate.savedRecordingAlert(choices), to: $0, done: $1) }
        render("dmg-window-settings") { MenuMock.capture(DMGLayoutView(), to: $0, done: $1) }
    }
}
