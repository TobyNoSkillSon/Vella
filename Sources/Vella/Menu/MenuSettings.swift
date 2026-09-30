import AppKit
import SwiftUI
import QuartzCore
import ServiceManagement
import VellaCore

/// Keep Hot and Memory values for the menu and the action that applies a choice. The runtime implements it.
@MainActor protocol MenuSettingsSource: AnyObject {
    var manualIdleMinutes: Int { get }
    var onDemandIdleMinutes: Int { get }
    var allowSwap: Bool { get }
    var availableMB: Double? { get }
    var lastEvicted: String? { get }
    func apply(_ action: SettingsAction)
}

/// Defaults held in memory until the runtime's settings are attached (also the render harness's source).
@MainActor final class DefaultMenuSettings: MenuSettingsSource {
    var manualIdleMinutes = defaultManualIdleMinutes
    var onDemandIdleMinutes = defaultOnDemandIdleMinutes
    var allowSwap = false
    var availableMB: Double?
    var lastEvicted: String?
    init(manualIdleMinutes: Int = defaultManualIdleMinutes, onDemandIdleMinutes: Int = defaultOnDemandIdleMinutes, allowSwap: Bool = false,
         availableMB: Double? = nil, lastEvicted: String? = nil) {
        self.manualIdleMinutes = manualIdleMinutes; self.onDemandIdleMinutes = onDemandIdleMinutes; self.allowSwap = allowSwap
        self.availableMB = availableMB; self.lastEvicted = lastEvicted
    }
    func apply(_ action: SettingsAction) {
        switch action {
        case .keepHot(.manual, let minutes): manualIdleMinutes = minutes
        case .keepHot(.onDemand, let minutes): onDemandIdleMinutes = minutes
        case .memory(let allow): allowSwap = allow
        }
    }
}

/// Carries a VellaCore settings action through NSMenuItem.representedObject.
final class SettingsActionBox: NSObject {
    let action: SettingsAction
    init(_ action: SettingsAction) { self.action = action }
}

/// Resources/SKILL.md from the app bundle (the source checkout's copy when run unbundled, e.g. tests).
func skillText(bundle: Bundle = .main) -> String {
    let candidates = [bundle.url(forResource: "SKILL", withExtension: "md"),
                      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                          .appendingPathComponent("Resources/SKILL.md")]
    for url in candidates.compactMap({ $0 }) { if let text = try? String(contentsOf: url, encoding: .utf8) { return text } }
    return "Vella's skill file is missing from the app bundle; run `vella skill` or see the repository's Resources/SKILL.md."
}
