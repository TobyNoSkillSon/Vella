import Foundation

// Keep Hot and Memory submenu content as data (unit-tested, drawn by the app's menu builder), and the menu's
// tooltip strings. A menu item has a tooltip only where its title cannot carry the meaning (Toby, 29 Sep): Copy Skill
// for Your Agent, the header reporting an error or permission (or a kept recording that waits), the Get row of a
// waiting recording, the Keep Hot / Memory entries with a rule behind them, and Update after a failed attempt. Settings values come from the runtime (Residency/Configuration); this file only presents them.

/// Keep Hot idle windows in minutes; 0 = Always. Idle is timed per model since a dictation last used it (or it loaded).
public let keepHotChoices: [(minutes: Int, title: String)] = [(5, "5 min idle"), (15, "15 min idle"), (30, "30 min idle"), (60, "60 min idle"), (0, "Always")]
public let defaultManualIdleMinutes = 0
public let defaultOnDemandIdleMinutes = 15

public enum KeepHotClass: String, Equatable { case manual, onDemand = "on_demand" }

/// One entry of a settings submenu: a section header, a choice, a disabled caption or a separator.
/// `help` is the tooltip: one sentence for anything not self-explanatory at a glance.
public enum SettingsEntry: Equatable {
    case header(String, help: String? = nil)
    case choice(title: String, checked: Bool, action: SettingsAction, help: String? = nil)
    case caption(String)
    case separator
}
public enum SettingsAction: Equatable {
    case keepHot(KeepHotClass, minutes: Int)
    case memory(allowSwap: Bool)
}

public let manualLoadHelp = "Models you loaded yourself with Load in Models…; they load again when Vella starts."
public let onDemandLoadHelp = "Models a dictation needed, so Vella loaded them; they do not load again when Vella starts."
public let keepHotAlwaysHelp = "Never unloaded for being idle; only Unload, or Memory making room for another model, unloads them."
public let fitInFreeMemoryTitle = "Fit in free memory"
public let fitInFreeMemoryHelp =
    "Checks free memory before loading: a model loads only if it fits in memory that is free at that moment; otherwise idle models are unloaded (least recently used, on-demand first) or the load is refused with the reason. Best effort: memory use can change after the check."
public let allowSwapTitle = "Allow swap (slower)"
public let allowSwapHelp = "Loads even when memory is short; macOS moves data to disk and everything, including other apps, can slow down."
public let copySkillHelp =
    "Copies Vella's skill for a coding agent to the clipboard: when Vella is worth using for audio files, and how to call the vella command, its OpenAI-compatible API or Python. Paste it into your agent's skills."
public let accessibilityHeaderHelp = "Vella needs Accessibility access to type into other apps. Click to open System Settings."

/// The worker item: Restart Worker while a worker runs, Start Worker when none does (the family menu, 28 Sep 2026).
public func workerItemTitle(running: Bool) -> String { running ? "Restart Worker" : "Start Worker" }

/// The menu header's tooltip, only when it adds something to the header's own text: the error of a failed
/// dictation, the permission to grant, or why a kept recording waits for a model. Nil otherwise (no greeting, no
/// progress echo).
public func menuHeaderToolTip(failed: Bool, message: String, needsPermission: Bool, idle: Bool, pending: String?) -> String? {
    if failed { return message.isEmpty ? nil : message }
    if needsPermission { return accessibilityHeaderHelp }
    return idle ? pending : nil
}

/// Keep Hot: manually loaded (Load in Models…, the launch set) and loaded on demand (a dictation needed it).
public func keepHotEntries(manualIdle: Int, onDemandIdle: Int) -> [SettingsEntry] {
    func choices(_ kind: KeepHotClass, _ current: Int) -> [SettingsEntry] {
        keepHotChoices.map {
            .choice(
                title: $0.title, checked: current == $0.minutes, action: .keepHot(kind, minutes: $0.minutes),
                help: $0.minutes == 0 ? keepHotAlwaysHelp : nil)
        }
    }
    var entries: [SettingsEntry] = [.header("Manually loaded", help: manualLoadHelp)]
    entries += choices(.manual, manualIdle)
    entries += [.separator, .header("Loaded on demand", help: onDemandLoadHelp)]
    entries += choices(.onDemand, onDemandIdle)
    entries += [.separator, .caption("Unloaded models reload on the next dictation")]
    return entries
}

/// Memory: Fit in free memory (default) or Allow swap, with live captions (free memory now, the last eviction).
public func memoryEntries(allowSwap: Bool, availableMB: Double?, lastEvicted: String?) -> [SettingsEntry] {
    var entries: [SettingsEntry] = [
        .choice(title: fitInFreeMemoryTitle, checked: !allowSwap, action: .memory(allowSwap: false), help: fitInFreeMemoryHelp),
        .choice(title: allowSwapTitle, checked: allowSwap, action: .memory(allowSwap: true), help: allowSwapHelp)
    ]
    var captions: [String] = []
    if let mb = availableMB { captions.append(String(format: "~%.1f GB free now", Swift.max(0, mb) / 1000)) }
    if let lastEvicted { captions.append("Unloaded \(lastEvicted) to make room") }
    if !captions.isEmpty { entries.append(.separator); entries += captions.map { .caption($0) } }
    return entries
}
