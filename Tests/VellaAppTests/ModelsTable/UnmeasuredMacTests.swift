import XCTest
import AppKit
import SwiftUI
@testable import Vella
@testable import VellaCore

/// A Mac Vella was not measured on (Toby's friend's M4 Pro saw no speed or J / min): Peak RAM, WER and Format show as
/// measured, since they depend on the precision, not the Mac; Speed and J / min show the M5 Max figure as a plain number
/// with a triangle and its label, the tooltip saying it was not measured here. The measured M5 Max shows neither.
@MainActor final class UnmeasuredMacTests: XCTestCase {
    private func controller(chip: String) throws -> ModelsController {
        var state = try XCTUnwrap(TableRenderDelegate.states().first { $0.name == "loaded" })
        state.runtime.chip = chip
        state.gpuCores = chip == "M5 Max" ? 40 : 20
        return TableRenderDelegate.controller(state)
    }

    /// The table as the menu hosts it, in a window, laid out once.
    private func hosted(_ c: ModelsController) -> NSView {
        let view = MenuTableHostingView(rootView: ModelTable(controller: c))
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(c))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return view
    }
    private var windows: [NSWindow] = []

    func testAnUnmeasuredMacShowsEveryFigureWithTheM5MaxReference() throws {
        let c = try controller(chip: "M4 Pro")
        XCTAssertFalse(c.benchmarkHardware.isMeasuredConfiguration)
        XCTAssertFalse(c.gpu.tensorOps, "the M4 Pro profile has no tensor units")
        let table = ModelTable(controller: c)
        for family in c.families(.dictation) + c.families(.streaming) {
            let r = try XCTUnwrap(c.shownResult(family), family.id)
            // Hardware-independent figures: present and shown exactly as measured.
            XCTAssertNotNil(formatMemory(r.memory_mb), family.id); XCTAssertNotNil(formatErrorRate(r.wer), family.id)
            XCTAssertNotNil(formatErrorRate(r.format), family.id)
            // Hardware-dependent figures: the M5 Max number, never blank, never "not known", never a relative claim.
            let speed = try XCTUnwrap(c.benchmarkHardware.speedText(r.speed_x), family.id)
            let energy = try XCTUnwrap(c.benchmarkHardware.energyText(r.j_per_min), family.id)
            XCTAssertFalse(energy.contains("not known")); XCTAssertEqual(c.benchmarkHardware.speedReferenceLabel, "M5 Max")
            let tips = Dictionary(table.tooltips(family).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            XCTAssertEqual(tips["Speed"]?.components(separatedBy: "\n").first, "Not measured on your Mac. M5 Max: \(speed) real time.", family.id)
            XCTAssertEqual(tips["J / min"]?.components(separatedBy: "\n").first, "Not measured on your Mac. M5 Max: \(energy) per audio minute.", family.id)
            for column in ["WER", "Format", "Peak RAM"] { XCTAssertFalse(tips[column]?.contains("Not measured on your Mac") ?? true, "\(family.id) \(column)") }
            for (column, text) in tips {
                XCTAssertNil(text.range(of: #"\d+% (less|more|faster|slower)"#, options: .regularExpression), "\(family.id) \(column): no relative claim here: \(text)")
            }
        }
        XCTAssertEqual(
            hardwareNote(thisChip: c.benchmarkHardware.chip, measuredOn: measurementChip(c.benchmarks), gpuCores: c.benchmarkHardware.gpuCores)?.text,
            "Speed and J / min measured on M5 Max")
        // The drawn row carries the triangles: one on every Speed and J / min figure; the table lays out at its width.
        for family in c.families(.dictation) + c.families(.streaming) {
            let r = try XCTUnwrap(c.shownResult(family))
            let slow = family.mode == .dictation && (r.speed_x ?? 0) < slowSpeedFloor
            XCTAssertEqual(ModelTable.speedWarning(family.mode, speed: r.speed_x, hardware: c.benchmarkHardware), slow ? "very slow" : ModelTable.referenceWarning)
            XCTAssertEqual(ModelTable.energyWarning(r.j_per_min, hardware: c.benchmarkHardware), ModelTable.referenceWarning)
        }
        XCTAssertEqual(hosted(c).fittingSize.width, ModelTable.width)
    }

    func testTheMeasuredMacShowsItsOwnFiguresWithoutTriangles() throws {
        let c = try controller(chip: "M5 Max")
        XCTAssertTrue(c.benchmarkHardware.isMeasuredConfiguration)
        let table = ModelTable(controller: c)
        for family in c.families(.dictation) + c.families(.streaming) {
            for (column, text) in table.tooltips(family) { XCTAssertFalse(text.contains("Not measured on your Mac"), "\(family.id) \(column)") }
        }
        XCTAssertNil(hardwareNote(thisChip: c.benchmarkHardware.chip, measuredOn: measurementChip(c.benchmarks), gpuCores: c.benchmarkHardware.gpuCores))
        for family in c.families(.dictation) + c.families(.streaming) {
            let r = try XCTUnwrap(c.shownResult(family))
            XCTAssertNotEqual(ModelTable.speedWarning(family.mode, speed: r.speed_x, hardware: c.benchmarkHardware), ModelTable.referenceWarning)
            XCTAssertNil(ModelTable.energyWarning(r.j_per_min, hardware: c.benchmarkHardware))
        }
        XCTAssertEqual(ModelTable.speedWarning(.dictation, speed: 12, hardware: c.benchmarkHardware), "very slow", "the slow triangle stays")
        XCTAssertEqual(hosted(c).fittingSize.width, ModelTable.width)
    }
}
