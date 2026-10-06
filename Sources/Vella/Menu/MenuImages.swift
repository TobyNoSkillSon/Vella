import AppKit

/// macOS 27 hides SF Symbols in menus by default for apps linked against SDK 26 or later.
@MainActor enum MenuImages {
    static func show(in menu: NSMenu) {
        for item in menu.items { show(in: item) }
    }

    static func show(in item: NSMenuItem) {
        guard #available(macOS 27.0, *) else { return }
        if item.image != nil, item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            // KVC keeps this buildable with the release toolchain's macOS 26 SDK. Visible = 1.
            item.setValue(1, forKey: "preferredImageVisibility")
        }
        if let submenu = item.submenu { show(in: submenu) }
    }
}
