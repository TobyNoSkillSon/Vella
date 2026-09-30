import AppKit

/// Settings are controls inside native menu tracking, not commands that end it.
/// NSMenu still owns click-away, Escape and keyboard navigation.
///
/// Mouse-button confirmation rows pre-reserve their width at factory creation
/// for the longest pending prompt + concise failures, so showing the inline
/// red prompt/error while the native menu is tracking never resizes the row.
@MainActor final class SettingsMenuItem: NSMenuItem {
    let control = NSButton()
    private let settingAction: Selector
    private weak var settingTarget: AnyObject?
    private let baseTitle: String

    init(title: String, target: AnyObject, action: Selector, reservedWidth: CGFloat? = nil) {
        settingAction = action; settingTarget = target
        baseTitle = title
        super.init(title: title, action: action, keyEquivalent: "")
        // Retain the conventional native keyboard action; pointer clicks go
        // directly to the embedded control without ending menu tracking.
        self.target = target
        let font = NSFont.menuFont(ofSize: 0)
        let baseWidth = max(180, (title as NSString).size(withAttributes: [.font: font]).width + 52)
        let width = max(baseWidth, reservedWidth ?? 0)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        control.frame = host.bounds.insetBy(dx: 12, dy: 2)
        control.autoresizingMask = [.width]
        control.setButtonType(.radio)
        control.title = title; control.font = font
        control.target = self; control.action = #selector(choose)
        host.addSubview(control); view = host
    }
    required init(coder: NSCoder) { fatalError("SettingsMenuItem is programmatic") }
    func synchronize() { control.state = state; control.isEnabled = isEnabled }
    /// Inline bounded mouse confirmation prompt in the same row (red).
    /// Width was pre-reserved at creation; never resizes a tracking menu.
    /// `synchronize()` only touches state/isEnabled, so red survives.
    func showConfirmationPrompt(_ prompt: String) {
        let font = NSFont.menuFont(ofSize: 0)
        control.title = prompt
        control.attributedTitle = NSAttributedString(string: prompt, attributes: [.font: font, .foregroundColor: NSColor.systemRed])
        control.toolTip = nil
        self.toolTip = nil
    }
    /// Inline bounded failure (concise/compact, pre-reserved) in the same row (red).
    /// Full diagnostic stays in the tooltip when provided. Never resizes tracking menu.
    func showConfirmationError(_ message: String, toolTip: String? = nil) {
        let font = NSFont.menuFont(ofSize: 0)
        control.title = message
        control.attributedTitle = NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: NSColor.systemRed])
        control.toolTip = toolTip
        self.toolTip = toolTip
    }
    /// Restore the base row title after commit/cancel (identity + width unchanged).
    func restoreBaseTitle() {
        control.title = baseTitle
        control.font = .menuFont(ofSize: 0)
        control.toolTip = nil
        self.toolTip = nil
    }
    @objc private func choose() {
        guard isEnabled else { synchronize(); return }
        NSApplication.shared.sendAction(settingAction, to: settingTarget, from: self)
        synchronize()
    }
}
