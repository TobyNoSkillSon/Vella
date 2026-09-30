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
        for menuItem in [false, true] { for size in [ControlSize.regular, .small, .mini, .large] {
            for (optimized, standard) in [(["16", "8", "4"], ["16", "8", "4"]), (["16"], ["16", "8"]), (["16", "8"], ["16", "8"]), (["8", "4"], ["16"])] {
                let host = firstPass(HStack(spacing: 6) {
                    TierControl(optimized: optimized, standard: standard, selected: TierControl.Cell(.standard, standard[0]), enabled: true,
                                help: { _ in "" }, onSelect: { _ in })
                    ExactFastSwitch(position: .fast, available: true, enabled: true, onChange: { _ in })
                    RowAction(title: "Load", enabled: true, deletable: true, help: "", onPerform: {}, onDelete: {})
                }.controlSize(size), in: menuItem)
                let label = "\(size) \(optimized) / \(standard)"
                // Top to bottom: the host is flipped, so the smaller minY is the Optimized row.
                let segments = all(NSSegmentedControl.self, in: host).map { drawn($0, in: host) }.sorted { $0.minY < $1.minY }
                XCTAssertEqual(segments.count, 2, "two rows of segments: \(label)")
                guard segments.count == 2 else { continue }
                let (top, bottom) = (host.isFlipped ? segments[0] : segments[1], host.isFlipped ? segments[1] : segments[0])
                for (r, tiers) in [(top, optimized), (bottom, standard)] {
                    XCTAssertEqual(r.height, TierControl.segmentHeight, accuracy: 0.5, "\(label): \(r)")
                    XCTAssertEqual(r.width, TierControl.segmentsWidth(tiers.count), accuracy: 0.5, "\(label): \(r)")
                }
                let gap = host.isFlipped ? bottom.minY - top.maxY : top.minY - bottom.maxY
                XCTAssertEqual(gap, TierControl.rowSpacing, accuracy: 0.5, "\(label): real air between Optimized and Standard")
                for control in all(NSSegmentedControl.self, in: host) {
                    XCTAssertEqual(control.controlSize, .regular, "the environment's size does not reach the control")
                }
                let switchView = try XCTUnwrap(all(SwitchView.self, in: host).first)
                XCTAssertEqual(switchView.frame.size, NSSize(width: ExactFastSwitch.width, height: ExactFastSwitch.height))
                let action = try XCTUnwrap(all(RowActionView.self, in: host).first)
                XCTAssertEqual(action.frame.size, NSSize(width: RowAction.width, height: RowAction.height))
                let frames = segments + [switchView.convert(switchView.bounds, to: host), action.convert(action.bounds, to: host)]
                for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(label): \(a) overlaps \(b)") } }
            }
        } }
    }

    func testTheControlReportsItsHeightAndTheConstantMatchesAppKit() {
        let host = NSHostingView(rootView: TierControl(optimized: ["16"], standard: ["16"], selected: nil, enabled: true, help: { _ in "" }, onSelect: { _ in }))
        XCTAssertEqual(host.fittingSize.height, TierControl.height, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.width, TierControl.width, accuracy: 0.5)
        // The constant still matches AppKit: a real regular segmented control is one segment high.
        let probe = NSSegmentedControl(labels: ["16"], trackingMode: .selectOne, target: nil, action: nil)
        probe.controlSize = .regular; probe.font = TierControl.font
        XCTAssertLessThanOrEqual(probe.intrinsicContentSize.height, TierControl.segmentHeight)
        // No "Tier" anywhere a user reads.
        XCTAssertEqual(TierControl.title, "Precision")
        XCTAssertEqual(TierControl.headerHelp, "Bits per weight. 16 = as released; 8 and 4 compressed on your Mac \u{2014} smaller, faster, slightly less accurate.")
        XCTAssertEqual(TierControl.Row.allCases.map(\.title), ["Optimized", "Standard"], "Optimized above Standard")
        XCTAssertEqual(ExactFastSwitch.title, ExactFastSwitch.showsWords ? "" : "Fast/Exact")
        for text in [TierControl.title, TierControl.headerHelp, TierControl.inUseHelp, ExactFastSwitch.title, ExactFastSwitch.help,
                     ExactFastSwitch.sameHelp, ExactFastSwitch.inUseHelp, RowAction.deleteHelp] {
            XCTAssertFalse(text.lowercased().contains("tier"), text)
        }
    }
}
