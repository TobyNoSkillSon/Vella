import AppKit

/// Settings are controls inside native menu tracking, not commands that end it.
/// NSMenu still owns click-away, Escape and keyboard navigation.
@MainActor final class SettingsMenuItem: NSMenuItem {
    let control = NSButton()
    private let settingAction: Selector
    private weak var settingTarget: AnyObject?

    init(title: String, target: AnyObject, action: Selector) {
        settingAction = action; settingTarget = target
        super.init(title: title, action: action, keyEquivalent: "")
        // Retain the conventional native keyboard action; pointer clicks go
        // directly to the embedded control without ending menu tracking.
        self.target = target
        let width = max(180, (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width + 52)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        control.frame = host.bounds.insetBy(dx: 12, dy: 2)
        control.autoresizingMask = [.width]
        control.setButtonType(.radio)
        control.title = title; control.font = .menuFont(ofSize: 0)
        control.target = self; control.action = #selector(choose)
        host.addSubview(control); view = host
    }
    required init(coder: NSCoder) { fatalError("SettingsMenuItem is programmatic") }
    func synchronize() { control.state = state; control.isEnabled = isEnabled }
    @objc private func choose() {
        guard isEnabled else { synchronize(); return }
        NSApplication.shared.sendAction(settingAction, to: settingTarget, from: self)
        synchronize()
    }
}
