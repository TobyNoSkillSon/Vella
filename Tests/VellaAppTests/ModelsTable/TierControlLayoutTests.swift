import XCTest
import AppKit
import SwiftUI
@testable import Vella

/// The table controls (the Precision control's one segment row, the Exact/Fast switch, the action button) must have their explicit geometry on the
/// FIRST layout pass, as when the Models menu first opens: no click, no second pass, whatever control size the hosting
/// environment pushes. (Toby's screenshots, 29 Sep: controls drawn over each other until a click relaid the row.)
@MainActor final class TierControlLayoutTests: XCTestCase {
    private func firstPass(_ view: some View, in menuItem: Bool) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        if menuItem {
            // As the menu hosts it: inside a window, laid out once, then drawn.
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
        }
        host.layoutSubtreeIfNeeded()
        return host
    }
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ v: NSView) { if let t = v as? T { found.append(t) }; v.subviews.forEach(walk) }
        walk(view); return found
    }
    /// A segmented control's drawn rectangle: its frame less the bezel's alignment insets.
    private func drawn(_ control: NSView, in host: NSView) -> NSRect {
        control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: host)
    }

    func testSegmentsHaveTheirExplicitSizeOnTheFirstLayoutPass() throws {
        for menuItem in [false, true] {
            for size in [ControlSize.regular, .small, .mini, .large] {
                // Greyed cells, the gold cell and warning triangles never change the grid: three equal cells.
                for (greyed, warned) in [([], []), (["8", "4"], []), (["16"], ["8"]), (["16", "8", "4"], []), ([], ["8", "4"])] as [([String], [String])] {
                    var unavailable: [String: String] = [:]
                    for tier in greyed { unavailable[tier] = "Not offered" }
                    let host = firstPass(
                        HStack(spacing: 6) {
                            TierControl(
                                labels: ["bf16", "int8", "int4"], selected: "16", enabled: true, unavailable: unavailable, recommended: "8",
                                warnings: Dictionary(uniqueKeysWithValues: warned.map { ($0, "No hardware support") }), help: { _ in "" }, onSelect: { _ in })
                            ExactFastSwitch(position: .fast, available: true, enabled: true, onChange: { _ in })
                            RowAction(title: "Load", enabled: true, deletable: true, help: "", onPerform: {}, onDelete: {})
                        }.controlSize(size), in: menuItem)
                    let label = "\(size) greyed \(greyed) warned \(warned)"
                    let segments = all(NSSegmentedControl.self, in: host).map { drawn($0, in: host) }
                    XCTAssertEqual(segments.count, 1, "one row of segments, no Standard row: \(label)")
                    guard let row = segments.first else { continue }
                    XCTAssertEqual(row.height, TierControl.segmentHeight, accuracy: 0.5, "\(label): \(row)")
                    XCTAssertEqual(row.width, TierControl.segmentsWidth(3), accuracy: 0.5, "\(label): all three cells: \(row)")
                    for control in all(NSSegmentedControl.self, in: host) {
                        XCTAssertEqual(control.segmentCount, 3, label)
                        XCTAssertEqual((0..<3).map { control.label(forSegment: $0) }, ["bf16", "int8", "int4"], label)
                        XCTAssertEqual(Set((0..<3).map { control.width(forSegment: $0) }).count, 1, "\(label): equal cells")
                        for (i, tier) in TierControl.columns.enumerated() {
                            XCTAssertEqual(control.isEnabled(forSegment: i), !greyed.contains(tier), "\(label): \(tier) greyed in place")
                        }
                    }
                    for control in all(NSSegmentedControl.self, in: host) {
                        XCTAssertEqual(control.controlSize, .regular, "the environment's size does not reach the control")
                        // The stock regular geometry in its own bounds, scaled by its frame (TableMetrics).
                        XCTAssertEqual(control.bounds.width, TierControl.Natural.segmentsWidth(3), accuracy: 0.01, "\(label): natural bounds")
                        XCTAssertEqual(control.bounds.height, TierControl.Natural.segmentHeight, accuracy: 0.01, "\(label): natural bounds")
                    }
                    let switchView = try XCTUnwrap(all(SwitchView.self, in: host).first)
                    // Half-point sizes (TableMetrics) land on whole points where the host draws at 1x.
                    XCTAssertEqual(switchView.frame.width, ExactFastSwitch.width, accuracy: 0.5, label)
                    XCTAssertEqual(switchView.frame.height, ExactFastSwitch.height, accuracy: 0.5, label)
                    XCTAssertEqual(ExactFastSwitch.height, TableMetrics.pt(43), "the switch scaled to the one row")
                    let s = switchView.convert(switchView.bounds, to: host)
                    XCTAssertEqual(s.midY, row.midY, accuracy: 0.5, "\(label): the row is centred on the switch")
                    let action = try XCTUnwrap(all(RowActionView.self, in: host).first)
                    XCTAssertEqual(action.frame.width, RowAction.width, accuracy: 0.5, label)
                    XCTAssertEqual(action.frame.height, RowAction.height, accuracy: 0.5, label)
                    let frames = segments + [switchView.convert(switchView.bounds, to: host), action.convert(action.bounds, to: host)]
                    for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(label): \(a) overlaps \(b)") } }
                }
            }
        }
    }

    func testTheControlReportsItsHeightAndTheConstantMatchesAppKit() {
        let host = NSHostingView(rootView: TierControl(selected: nil, enabled: true, help: { _ in "" }, onSelect: { _ in }))
        XCTAssertEqual(host.fittingSize.height, TierControl.height, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.width, TierControl.width, accuracy: 0.5)
        // The natural constant still matches AppKit: a real regular segmented control is one natural segment high, and
        // on screen a segment row is that height at the table's scale.
        let probe = NSSegmentedControl(labels: ["16"], trackingMode: .selectOne, target: nil, action: nil)
        probe.controlSize = .regular; probe.font = TierControl.font
        XCTAssertLessThanOrEqual(probe.intrinsicContentSize.height, TierControl.Natural.segmentHeight)
        XCTAssertEqual(TierControl.segmentHeight, TierControl.Natural.segmentHeight * TableMetrics.scale, accuracy: 0.25)
        XCTAssertEqual(TierControl.segmentsWidth(3), TierControl.Natural.segmentsWidth(3) * TableMetrics.scale, accuracy: 1)
        // No "Tier" anywhere a user reads.
        XCTAssertEqual(TierControl.title, "Precision")
        XCTAssertEqual(
            TierControl.headerHelp,
            "The running weight format: bf16 or fp16 from the checkpoint; int8 and int4 are quantized on your Mac to reduce weight size. Gold: recommended for this Mac. Speed, peak RAM and accuracy depend on the model and precision."
        )
        // The bolt is the one path (Toby, 15 Oct); its line is true on every Mac, whichever path the worker ends up on.
        XCTAssertEqual(TierControl.boltHelp, "Vella runs each model the fastest way this Mac supports and falls back to plain MLX by itself if that fails")
        XCTAssertEqual(ExactFastSwitch.title, ExactFastSwitch.showsWords ? "" : "Fast/Exact")
        for text in [
            TierControl.title, TierControl.headerHelp, TierControl.inUseHelp, TierControl.boltHelp, ExactFastSwitch.title, ExactFastSwitch.help,
            ExactFastSwitch.sameHelp, ExactFastSwitch.inUseHelp, RowAction.deleteHelp
        ] {
            XCTAssertFalse(text.lowercased().contains("tier"), text)
            // No path names a user reads (Toby, 15 Oct): no Standard and no Optimized row.
            XCTAssertFalse(text.contains("Standard"), text); XCTAssertFalse(text.contains("Optimized"), text)
        }
        // Gold reads as recommended on both backgrounds, distinct from the bolt's colours.
        XCTAssertNotEqual(TierControl.gold, TierControl.boltColor(hot: true)); XCTAssertNotEqual(TierControl.gold, TierControl.boltColor(hot: false))
    }
}
