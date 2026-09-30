import XCTest
import AppKit
import SwiftUI
@testable import Vella

/// The shared table controls (the Precision control's two segment rows, the Exact/Fast switch, the action button) must have their explicit geometry on the
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
                // Greyed cells never change the grid: every row keeps its three equal cells.
                for greyed in [[], ["8", "4"], ["16"], ["16", "8", "4"]] {
                    var unavailable: [TierControl.Cell: String] = [:]
                    for tier in greyed { unavailable[TierControl.Cell(.optimized, tier)] = "Not offered"; unavailable[TierControl.Cell(.standard, tier)] = "Not offered" }
                    let host = firstPass(
                        HStack(spacing: 6) {
                            TierControl(
                                labels: ["bf16", "int8", "int4"], selected: TierControl.Cell(.standard, "16"), enabled: true, unavailable: unavailable,
                                help: { _ in "" }, onSelect: { _ in })
                            ExactFastSwitch(position: .fast, available: true, enabled: true, onChange: { _ in })
                            RowAction(title: "Load", enabled: true, deletable: true, help: "", onPerform: {}, onDelete: {})
                        }.controlSize(size), in: menuItem)
                    let label = "\(size) greyed \(greyed)"
                    // Top to bottom: the host is flipped, so the smaller minY is the Optimized row.
                    let segments = all(NSSegmentedControl.self, in: host).map { drawn($0, in: host) }.sorted { $0.minY < $1.minY }
                    XCTAssertEqual(segments.count, 2, "two rows of segments: \(label)")
                    guard segments.count == 2 else { continue }
                    let (top, bottom) = (host.isFlipped ? segments[0] : segments[1], host.isFlipped ? segments[1] : segments[0])
                    for r in [top, bottom] {
                        XCTAssertEqual(r.height, TierControl.segmentHeight, accuracy: 0.5, "\(label): \(r)")
                        XCTAssertEqual(r.width, TierControl.segmentsWidth(3), accuracy: 0.5, "\(label): all three cells: \(r)")
                    }
                    XCTAssertEqual(top.minX, bottom.minX, accuracy: 0.5, "\(label): the rows' cells line up")
                    for control in all(NSSegmentedControl.self, in: host) {
                        XCTAssertEqual(control.segmentCount, 3, label)
                        XCTAssertEqual((0..<3).map { control.label(forSegment: $0) }, ["bf16", "int8", "int4"], label)
                        XCTAssertEqual(Set((0..<3).map { control.width(forSegment: $0) }).count, 1, "\(label): equal cells")
                        for (i, tier) in TierControl.columns.enumerated() {
                            XCTAssertEqual(control.isEnabled(forSegment: i), !greyed.contains(tier), "\(label): \(tier) greyed in place")
                        }
                    }
                    let gap = host.isFlipped ? bottom.minY - top.maxY : top.minY - bottom.maxY
                    XCTAssertEqual(gap, TierControl.rowSpacing, accuracy: 0.5, "\(label): real air between Optimized and Standard")
                    for control in all(NSSegmentedControl.self, in: host) {
                        XCTAssertEqual(control.controlSize, .regular, "the environment's size does not reach the control")
                    }
                    let switchView = try XCTUnwrap(all(SwitchView.self, in: host).first)
                    XCTAssertEqual(switchView.frame.size, NSSize(width: ExactFastSwitch.width, height: ExactFastSwitch.height))
                    XCTAssertEqual(ExactFastSwitch.height, TierControl.height, "the switch spans both rows")
                    let s = switchView.convert(switchView.bounds, to: host)
                    XCTAssertEqual(s.midY, (top.midY + bottom.midY) / 2, accuracy: 0.5, "\(label): centred on the pair")
                    let action = try XCTUnwrap(all(RowActionView.self, in: host).first)
                    XCTAssertEqual(action.frame.size, NSSize(width: RowAction.width, height: RowAction.height))
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
        // The constant still matches AppKit: a real regular segmented control is one segment high.
        let probe = NSSegmentedControl(labels: ["16"], trackingMode: .selectOne, target: nil, action: nil)
        probe.controlSize = .regular; probe.font = TierControl.font
        XCTAssertLessThanOrEqual(probe.intrinsicContentSize.height, TierControl.segmentHeight)
        // No "Tier" anywhere a user reads.
        XCTAssertEqual(TierControl.title, "Precision")
        XCTAssertEqual(
            TierControl.headerHelp,
            "The number format the weights run in: bf16 or fp16 as released; int8 and int4 compressed on your Mac \u{2014} smaller, faster, slightly less accurate.")
        XCTAssertEqual(TierControl.Row.allCases.map(\.title), ["Optimized", "Standard"], "Optimized above Standard")
        // The rows are named by icons, each with one line naming its path (Toby, 30 Sep).
        XCTAssertEqual(TierControl.Row.optimized.help, "Optimized: the same weights with custom kernels for this Mac's chip")
        XCTAssertEqual(TierControl.Row.standard.help, "Standard: the plain MLX runtime, same weights, no custom kernels")
        XCTAssertNotNil(TierControl.mlxLogo, "Resources/mlx-logo.pdf, the Standard row's icon")
        XCTAssertEqual(TierControl.mlxLogo?.isTemplate, true, "a template image: drawn in the text colour")
        XCTAssertEqual(ExactFastSwitch.title, ExactFastSwitch.showsWords ? "" : "Fast/Exact")
        for text in [
            TierControl.title, TierControl.headerHelp, TierControl.inUseHelp, ExactFastSwitch.title, ExactFastSwitch.help, ExactFastSwitch.rowHelp,
            TierControl.Row.optimized.help, TierControl.Row.standard.help,
            ExactFastSwitch.sameHelp, ExactFastSwitch.inUseHelp, RowAction.deleteHelp
        ] {
            XCTAssertFalse(text.lowercased().contains("tier"), text)
        }
    }
}
