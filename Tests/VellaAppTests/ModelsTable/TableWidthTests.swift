import XCTest
import AppKit
import SwiftUI
@testable import Vella
@testable import VellaCore

/// The Models menu is exactly as wide as the table, in every content state, from the first layout pass: the installed v3
/// clipped the action buttons at the window's right edge (Toby, 30 Sep). The renders drew the table in a view of
/// `ModelTable.width` and so could not show a menu narrower than its content; these checks lay out the real menu item
/// (ModelsMenu.modelItem) for every render state.
@MainActor final class TableWidthTests: XCTestCase {
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ v: NSView) { if let t = v as? T { found.append(t) }; v.subviews.forEach(walk) }
        walk(view); return found
    }

    /// The table at 90 % of the 1006 pt × 60 pt-row v4 table (Toby, 30 Sep: about 10 % smaller in both directions).
    func testTheTableIsTheScaledSize() {
        XCTAssertEqual(TableMetrics.scale, 0.9)
        XCTAssertEqual(ModelTable.width, 907)
        XCTAssertEqual(ModelTable.rowHeight, 54)
        XCTAssertEqual(ModelTable.referenceRowHeight, 34)
        XCTAssertEqual(TierControl.height, 48.5)
    }

    /// The declared width is the sum of the layout constants, and the table's own content is exactly that wide.
    func testDeclaredWidthIsTheColumnsAndEqualsTheFittingWidth() {
        let columns = ModelTable.W.columns.reduce(0, +) + CGFloat(ModelTable.W.columns.count - 1) * ModelTable.W.spacing
        XCTAssertEqual(ModelTable.width, ModelTable.leadingPadding + ModelTable.W.rowPadding + columns + ModelTable.W.rowPadding + ModelTable.trailingPadding)
        XCTAssertEqual(ModelTable.trailingMargin, ModelTable.W.rowPadding + ModelTable.trailingPadding)
        for state in TableRenderDelegate.states() {
            let c = TableRenderDelegate.controller(state)
            // Unconstrained: no frame imposed, so a column wider than its constant would show here.
            let free = NSHostingView(rootView: ModelTable(controller: c))
            XCTAssertEqual(free.fittingSize.width, ModelTable.width, "\(state.name): the table's fitting width")
            XCTAssertEqual(free.fittingSize.height, ModelTable.height(c), "\(state.name): the table's fitting height")
        }
    }

    /// In the real menu item, on the first layout pass: the item view and the menu take the table's width, and every
    /// row's action button and trash glyph lie inside the item view with the trailing margin; no control leaves it.
    func testTheRightmostControlsAreInsideTheMenuOnTheFirstLayoutPass() throws {
        for state in TableRenderDelegate.states() {
            let c = TableRenderDelegate.controller(state)
            let root = ModelsMenu(controller: c).modelItem()
            let menu = try XCTUnwrap(root.submenu)
            let view = try XCTUnwrap(menu.items.first?.view)
            XCTAssertEqual(view.frame.width, ModelTable.width, state.name)
            XCTAssertEqual(view.fittingSize.width, ModelTable.width, "\(state.name): the item view's fitting width")
            XCTAssertEqual(menu.size.width, ModelTable.width, "\(state.name): the menu's width")
            XCTAssertGreaterThanOrEqual(menu.minimumWidth, ModelTable.width, state.name)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded() // the first pass only: no run-loop turn, no click
            let actions = all(RowActionView.self, in: view)
            XCTAssertEqual(actions.count, c.families(.dictation).count + c.families(.streaming).count, "\(state.name): one action per model")
            let limit = view.bounds.maxX - ModelTable.trailingMargin
            for action in actions {
                for (part, rect) in [("button", action.buttonRect), ("trash", action.trashRect), ("cell", action.bounds)] {
                    let r = action.convert(rect, to: view)
                    XCTAssertLessThanOrEqual(r.maxX, limit + 0.5, "\(state.name): the \(part) ends \(r.maxX), past \(limit)")
                    XCTAssertGreaterThan(r.width, 0, "\(state.name): \(part) laid out")
                }
            }
            for control in all(NSSegmentedControl.self, in: view) + all(SwitchView.self, in: view) {
                let r = control.convert(control.bounds, to: view)
                XCTAssertTrue(view.bounds.contains(r), "\(state.name): \(type(of: control)) at \(r) outside \(view.bounds)")
            }
            window.contentView = nil
        }
    }
}
