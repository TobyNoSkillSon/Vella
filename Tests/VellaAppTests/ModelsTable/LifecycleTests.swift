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
        // Corrected Whisper Standard uses its own faithful measurement, never Fast figures.
        state.runtime.loaded = ["whisper-large-v3": LoadedFamily(precision: "FP16", engine: "mlx", selection: requested)]
        let whisperController = TableRenderDelegate.controller(state)
        let whisper = try XCTUnwrap(whisperController.catalog.family("whisper-large-v3"))
        let standard = ModelSelection(tier: .t16, path: .standard, mode: .fast)
        XCTAssertNotNil(whisperController.shownResult(whisper)?.speed_x)
        XCTAssertEqual(whisperController.shownResult(whisper)?.speed_x, benchmarkCell(whisperController.benchmark(whisper), standard)?.result.speed_x)
    }
    func testFreshControllerHasReachableRecoveryAndDatedSessionChoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-recovery-choice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: Configuration(model: "/fixture", mode: .streaming, streamingModel: "/fixture/stream"))
        session.manifest.state = "interrupted"; try session.save()
        let choices = SavedRecordingChoice.list(root: root)
        XCTAssertEqual(choices.count, 1); XCTAssertTrue(sameDirectory(choices[0].directory.resolvingSymlinksInPath(), session.directory.resolvingSymlinksInPath()))
        XCTAssertTrue(choices[0].title.contains("Streaming · 0:00 · interrupted")); XCTAssertFalse(choices[0].title.contains(session.directory.lastPathComponent))
        let model = DictationController(monitorDefaultInput: false); defer { model.shutdown() }
        XCTAssertNil(model.savedSession)
        let app = AppDelegate(model: model); app.rebuildMenu()
        XCTAssertTrue(app.menu.item(withTitle: "Recover Saved Recording…")?.isEnabled == true)
        let alert = AppDelegate.savedRecordingAlert(choices)
        XCTAssertEqual(alert.informativeText, "The transcript is copied to the clipboard.")
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
