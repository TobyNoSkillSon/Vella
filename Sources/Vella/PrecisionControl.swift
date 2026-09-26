import AppKit
import SwiftUI

// Options are Vella's exact precision keys (4b, 8b,
// BF16, FP32); segments show bare widths (32 16 8 4) and each segment's tooltip names the exact format.

/// The Q picker: a mini segmented control whose recommended segment is labelled in the "better" green and
/// carries its own tooltip. AppKit, because SwiftUI's segmented Picker offers neither per-segment colour nor
/// per-segment tooltips. NSMenu-hosted views cannot open pop-ups, so the choice is inline.
struct PrecisionControl: NSViewRepresentable {
    let options: [String]
    /// Segment labels, parallel to `options` (bare widths).
    let labels: [String]
    let selected: String
    let recommended: String?
    let hot: Bool
    let enabled: Bool
    /// Tooltip per option.
    let help: (String) -> String
    let onSelect: (String) -> Void

    final class Coordinator: NSObject {
        var parent: PrecisionControl
        init(_ parent: PrecisionControl) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.options.indices.contains(index) else { return }
            parent.onSelect(parent.options[index])
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static var font: NSFont { .systemFont(ofSize: NSFont.systemFontSize(for: .mini)) }
    /// Content width of one segment: 21 pt for a bare width; wider only for a longer fallback label.
    static func segmentWidth(_ label: String) -> CGFloat {
        max(21, ceil((label as NSString).size(withAttributes: [.font: font]).width) + 9)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.cell = PrecisionCell()
        control.segmentCount = options.count
        control.trackingMode = .selectOne
        control.controlSize = .mini
        control.font = Self.font
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(control)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        update(control)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? { nsView.intrinsicContentSize }

    private func update(_ control: NSSegmentedControl) {
        if control.segmentCount != options.count { control.segmentCount = options.count }
        control.controlSize = .mini   // SwiftUI may push its environment size onto hosted controls
        control.font = Self.font
        let cell = control.cell as? PrecisionCell
        cell?.recommendedSegment = recommended.flatMap { options.firstIndex(of: $0) }
        cell?.hot = hot
        for (i, option) in options.enumerated() {
            let label = labels.indices.contains(i) ? labels[i] : option
            control.setLabel(label, forSegment: i)
            control.setWidth(Self.segmentWidth(label), forSegment: i)
            control.setToolTip(help(option), forSegment: i)
        }
        control.selectedSegment = options.firstIndex(of: selected) ?? -1
        control.isEnabled = enabled
        // The loaded row keeps an accent-coloured selected segment.
        control.selectedSegmentBezelColor = hot ? .controlAccentColor : nil
        control.needsDisplay = true
    }
}

/// Draws the recommended segment's label in green; every other segment is stock.
final class PrecisionCell: NSSegmentedCell {
    var recommendedSegment: Int?
    var hot = false
    /// Delta greens from the table: lighter on the loaded row and on a selected (filled) segment.
    static let green = NSColor(srgbRed: 0.42, green: 0.82, blue: 0.52, alpha: 1)
    static let lightGreen = NSColor(srgbRed: 0.62, green: 0.96, blue: 0.68, alpha: 1)

    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        guard segment == recommendedSegment, let text = label(forSegment: segment) else {
            super.drawSegment(segment, inFrame: frame, with: controlView); return
        }
        let selected = isSelected(forSegment: segment)
        var color = hot || selected ? Self.lightGreen : Self.green
        if !isEnabled { color = color.withAlphaComponent(0.45) }
        let font = self.font ?? PrecisionControl.font
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded()))
    }
}
