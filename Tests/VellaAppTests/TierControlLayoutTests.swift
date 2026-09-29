import XCTest
import AppKit
import SwiftUI
@testable import Vella

/// The shared tier picker must lay out its two segment rows apart on the FIRST layout pass, as when the Models menu
/// first opens: no click, no second pass. (Toby's screenshots, 29 Sep: Standard drawn over the bottom of Optimized
/// until a click relaid the row.)
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
    private func segments(_ view: NSView) -> [NSSegmentedControl] {
        var found: [NSSegmentedControl] = []
        func walk(_ v: NSView) { if let s = v as? NSSegmentedControl { found.append(s) }; v.subviews.forEach(walk) }
        walk(view); return found
    }

    func testRowsAreApartOnTheFirstLayoutPass() throws {
        // The hosting environment's control size (a menu, a table, a sheet) must not change the rows' geometry.
        for menuItem in [false, true] { for size in [ControlSize.regular, .small, .mini, .large] {
            for (optimized, standard) in [(["16", "8", "4"], ["16", "8", "4"]), (["16"], ["16", "8"]), (["8"], ["16", "8"])] {
                let host = firstPass(TierControl(optimized: optimized, standard: standard, selected: .init(.optimized, optimized[0]),
                                                 enabled: true, help: { _ in "" }, onSelect: { _ in }).controlSize(size), in: menuItem)
                let rows = segments(host).map { $0.convert($0.bounds, to: host) }.sorted { $0.midY < $1.midY }
                XCTAssertEqual(rows.count, 2, "two rows")
                guard rows.count == 2 else { continue }
                XCTAssertFalse(rows[0].intersects(rows[1]), "rows overlap on the first pass: \(rows)")
                for r in rows {
                    XCTAssertEqual(r.height, TierControl.rowHeight, accuracy: 0.5, "a segment row is exactly one row high: \(r)")
                }
                XCTAssertGreaterThanOrEqual(rows[1].minY - rows[0].maxY, TierControl.rowSpacing - 0.5, "\(size)")
            }
        } }
    }

    func testTheControlReportsItsTwoRowHeight() {
        let host = NSHostingView(rootView: TierControl(optimized: ["16"], standard: ["16"], selected: nil, enabled: true,
                                                       help: { _ in "" }, onSelect: { _ in }))
        XCTAssertEqual(host.fittingSize.height, TierControl.height, accuracy: 0.5)
        XCTAssertEqual(TierControl.height, 2 * TierControl.rowHeight + TierControl.rowSpacing)
        // The constant still matches AppKit: a real mini segmented control fits in a row.
        let probe = NSSegmentedControl(labels: ["16"], trackingMode: .selectOne, target: nil, action: nil)
        probe.controlSize = .mini; probe.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        XCTAssertLessThanOrEqual(probe.intrinsicContentSize.height, TierControl.segmentHeight)
    }
}
