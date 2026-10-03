import XCTest
import AppKit
import SwiftUI
import VellaCore
@testable import Vella

@MainActor final class LifecycleTests: XCTestCase {
    func testFallbackDisplaysEffectiveCellWithoutReplacingTheRequestedPreference() throws {
        var state = try XCTUnwrap(TableRenderDelegate.states().first { $0.name == "mlx-fallback" })
        let controller = TableRenderDelegate.controller(state)
        let family = try XCTUnwrap(controller.catalog.family("parakeet-v3"))
        let requested = try XCTUnwrap(controller.loaded(family)?.selection)
        XCTAssertEqual(requested.path, .optimized)
        XCTAssertEqual(controller.loadedSelection(family)?.path, .standard)
        XCTAssertEqual(controller.shownCell(family)?.path, .standard)
        XCTAssertEqual(controller.shownResult(family)?.speed_x ?? 0, 257.7, accuracy: 0.2)
        XCTAssertFalse(controller.showsDeltas(family))
        XCTAssertTrue(modelHelp(family, loaded: controller.loaded(family)).contains("Reload Optimized Fast"))
        // Unmeasured Whisper Standard never borrows Fast figures.
        state.runtime.loaded = ["whisper-large-v3": LoadedFamily(precision: "FP16", engine: "mlx", selection: requested)]
        let whisperController = TableRenderDelegate.controller(state)
        let whisper = try XCTUnwrap(whisperController.catalog.family("whisper-large-v3"))
        XCTAssertNil(whisperController.shownResult(whisper)?.speed_x)
    }
    func testFreshControllerHasReachableRecoveryAndDatedSessionChoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-recovery-choice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: Configuration(model: "/fixture", mode: .streaming, streamingModel: "/fixture/stream"))
        session.manifest.state = "interrupted"; try session.save()
        let choices = SavedRecordingChoice.list(root: root)
        XCTAssertEqual(choices.count, 1); XCTAssertEqual(choices[0].directory, session.directory)
        XCTAssertTrue(choices[0].title.contains("Streaming · interrupted")); XCTAssertFalse(choices[0].title.contains(session.directory.lastPathComponent))
        let model = DictationController(monitorDefaultInput: false); defer { model.shutdown() }
        XCTAssertNil(model.savedSession)
        let app = AppDelegate(model: model); app.rebuildMenu()
        XCTAssertTrue(app.menu.item(withTitle: "Recover Saved Recording…")?.isEnabled == true)
        let alert = AppDelegate.savedRecordingAlert(choices)
        XCTAssertTrue(alert.informativeText.contains("copied, not inserted"))
        XCTAssertTrue(alert.informativeText.contains("never replayed automatically"))
    }
    func testNonMeasuredConfigurationsFitTheNativeTableAndLabelOnlySpeed() {
        let state = TableRenderDelegate.states()[0]
        for hardware in [
            BenchmarkHardware(chip: "M5 Max", gpuCores: 32), BenchmarkHardware(chip: "M5 Pro", gpuCores: 20), BenchmarkHardware(chip: "M5", gpuCores: 10),
            BenchmarkHardware(chip: "M4", gpuCores: 10)
        ] {
            let controller = TableRenderDelegate.controller(state); controller.benchmarkHardware = hardware
            let view = NSHostingView(rootView: ModelTable(controller: controller))
            XCTAssertEqual(view.fittingSize.width, ModelTable.width)
            XCTAssertEqual(hardware.speedReferenceLabel, "M5 Max")
            XCTAssertEqual(hardware.energyText(10), "not known")
        }
    }
}
