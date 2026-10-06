import AppKit
import XCTest
import VellaCore
import VellaUpdate
@testable import Vella

final class MenuImagesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-menu-images-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func delegate() throws -> AppDelegate {
        _ = NSApplication.shared
        let config = root.appendingPathComponent("config.json")
        let resources = ModelLibrary.resourceDirectory()
        let registry = root.appendingPathComponent("models-installed.json")
        let controller = ModelsController(
            dictation: ModelLibrary(mode: .dictation, resources: resources, registryURL: registry),
            streaming: ModelLibrary(mode: .streaming, resources: resources, registryURL: registry),
            benchmarksURL: resources.appendingPathComponent("benchmarks.json"), configURL: config)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defaults.removePersistentDomain(forName: root.lastPathComponent)
        let delegate = AppDelegate(
            model: DictationController(configurationURL: config),
            updates: UpdateController(current: "2.0.0", defaults: defaults, enabled: false))
        delegate.modelsMenu = delegate.makeModelsMenu(controller: controller)
        delegate.microphoneInputs = { [] }
        delegate.loginStatus = { .notRegistered }
        return delegate
    }

    @MainActor private func assertVisible(_ item: NSMenuItem, file: StaticString = #filePath, line: UInt = #line) {
        if item.image != nil {
            XCTAssertTrue(item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")), item.title, file: file, line: line)
            guard item.responds(to: NSSelectorFromString("preferredImageVisibility")) else {
                XCTFail("Missing image visibility getter: \(item.title)", file: file, line: line)
                return
            }
            XCTAssertEqual((item.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue, 1, item.title, file: file, line: line)
        }
        for child in item.submenu?.items ?? [] { assertVisible(child, file: file, line: line) }
    }

    @MainActor func testRealMenuIconsSurviveRebuildsAndLiveModeChanges() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Menu image visibility was added in macOS 27") }
        let delegate = try delegate()
        defer { delegate.model.shutdown() }
        let release = ReleaseInfo(tag: "v2.0.1", version: SemanticVersion("2.0.1")!, name: "", body: "")
        delegate.pendingModelRow = { ("Get test model", "Synthetic pending download") }
        delegate.model.lastText = "Synthetic transcript"

        for phase: DictationController.Phase in [.idle, .preparing, .recording, .transcribing, .success, .failed] {
            delegate.model.phase = phase
            delegate.updates.preview(.available(release))
            delegate.rebuildMenu()
            for title in ["Models…", "Shortcuts", "Microphone", "Mode", "Keep Hot", "Memory", "Update to 2.0.1…"] {
                XCTAssertNotNil(try XCTUnwrap(delegate.menu.item(withTitle: title)).image, title)
            }
            for item in delegate.menu.items { assertVisible(item) }
        }

        delegate.model.phase = .idle
        delegate.updates.preview(.downloading(release))
        delegate.rebuildMenu()
        let modes = try XCTUnwrap(delegate.menu.item(withTitle: "Mode")?.submenu)
        let streaming = try XCTUnwrap(modes.item(withTitle: "Streaming") as? SettingsMenuItem)
        delegate.menuWillOpen(delegate.menu)
        streaming.control.performClick(nil)
        XCTAssertEqual(delegate.model.mode, .streaming)
        XCTAssertTrue(delegate.menu.item(withTitle: "Mode")?.submenu === modes)
        for item in delegate.menu.items { assertVisible(item) }
        delegate.menuDidClose(delegate.menu)
        delegate.menuNeedsUpdate(delegate.menu)
        for item in delegate.menu.items { assertVisible(item) }
    }

    @MainActor func testStandaloneFactoriesExposeTheirIcons() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Menu image visibility was added in macOS 27") }
        let delegate = try delegate()
        defer { delegate.model.shutdown() }
        let unused = NSSelectorFromString("unused")
        let shortcuts = ShortcutMenuFactory.shortcutsItem(
            manager: delegate.shortcutManager, model: delegate.model, target: delegate,
            selectBehavior: unused, recordKeys: unused, cancelCapture: unused, selectModifier: unused,
            selectMouse: unused, resetDefault: unused, openSettings: unused)
        let models = delegate.modelsMenu.modelItem()
        delegate.updates.preview(.available(ReleaseInfo(tag: "v2.0.1", version: SemanticVersion("2.0.1")!, name: "", body: "")))
        let update = try XCTUnwrap(delegate.updates.menuItem())
        for item in [models, shortcuts, update] {
            XCTAssertNotNil(item.image)
            assertVisible(item)
        }
    }

    @MainActor func testRecursionThroughImageLessParentsAndUnsupportedSetter() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Menu image visibility was added in macOS 27") }
        _ = NSApplication.shared
        let menu = NSMenu()
        let parent = MenuItemWithoutImageVisibility(title: "Unsupported parent", action: nil, keyEquivalent: "")
        parent.image = try XCTUnwrap(NSImage(systemSymbolName: "cpu", accessibilityDescription: nil))
        let middle = NSMenuItem(title: "Image-less parent", action: nil, keyEquivalent: "")
        middle.submenu = NSMenu()
        parent.submenu = NSMenu()
        parent.submenu?.addItem(middle)
        menu.addItem(parent)
        MenuImages.show(in: menu)
        let child = NSMenuItem(title: "Late child", action: nil, keyEquivalent: "")
        child.image = parent.image
        middle.submenu?.addItem(child)
        MenuImages.show(in: menu)
        assertVisible(child)
        XCTAssertNil(middle.image)
        XCTAssertEqual((middle.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue, 0)
    }
}

@MainActor private final class MenuItemWithoutImageVisibility: NSMenuItem {
    override func responds(to selector: Selector!) -> Bool {
        if selector == NSSelectorFromString("setPreferredImageVisibility:") { return false }
        return super.responds(to: selector)
    }

    override func setValue(_ value: Any?, forKey key: String) {
        if key == "preferredImageVisibility" { XCTFail("Unsupported KVC setter must not be called") } else { super.setValue(value, forKey: key) }
    }
}
