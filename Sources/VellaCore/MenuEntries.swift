import Foundation

// Keep Hot and Memory submenu content as data (unit-tested, drawn by the app's menu builder), and the menu's
// tooltip strings. Shape follows the Verdict-family reference (Verdict 95ddba5, keepHotMenu/memoryMenu in Core.swift).
// Settings values come from the runtime (vr-runtime's Residency/Configuration); this file only presents them.

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
public let fitInFreeMemoryHelp = "Checks free memory before loading: a model loads only if it fits in memory that is free at that moment; otherwise idle models are unloaded (least recently used, on-demand first) or the load is refused with the reason. Best effort: memory use can change after the check."
public let allowSwapTitle = "Allow swap (slower)"
public let allowSwapHelp = "Loads even when memory is short; macOS moves data to disk and everything, including other apps, can slow down."
public let openFilesHelp = "Opens ~/Library/Application Support/Vella: settings, downloaded models and saved recordings."
public let copyLastHelp = "Copies the last recognized text, including a transcript recovered from a saved recording."
public let restartWorkerHelp = "Stops Vella's transcription workers; they start again with the next dictation."
public let modelsHelp = "Compare models and precisions, download, load and unload them."
public let modeHelp = "Dictation transcribes when you finish; Streaming types text while you speak."
public let microphoneHelp = "The input Vella records from; it falls back to the built-in microphone when this one is missing."
public let shortcutsHelp = "The key, modifier or mouse button that starts and finishes a dictation."
public let keepHotHelp = "How long an idle model stays in memory before Vella unloads it."
public let memoryHelp = "What Vella does when a model would not fit in free memory."
public let supportHelp = "Opens GitHub Sponsors in your browser."

/// Keep Hot: manually loaded (Load in Models…, the launch set) and loaded on demand (a dictation needed it).
public func keepHotEntries(manualIdle: Int, onDemandIdle: Int) -> [SettingsEntry] {
    func choices(_ kind: KeepHotClass, _ current: Int) -> [SettingsEntry] {
        keepHotChoices.map { .choice(title: $0.title, checked: current == $0.minutes, action: .keepHot(kind, minutes: $0.minutes),
                                     help: $0.minutes == 0 ? keepHotAlwaysHelp : nil) }
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
        .choice(title: allowSwapTitle, checked: allowSwap, action: .memory(allowSwap: true), help: allowSwapHelp),
    ]
    var captions: [String] = []
    if let mb = availableMB { captions.append(String(format: "~%.1f GB free now", Swift.max(0, mb) / 1000)) }
    if let lastEvicted { captions.append("Unloaded \(lastEvicted) to make room") }
    if !captions.isEmpty { entries.append(.separator); entries += captions.map { .caption($0) } }
    return entries
}

/// The first-dictation row when no model is downloaded: `Get Parakeet v3 (637 MB)`, with its tooltip.
public func pendingModelEntry(name: String, precision: String, downloadBytes: Int64) -> (title: String, help: String) {
    ("Get \(name) (\(formatBytes(downloadBytes)))",
     "Downloads \(name) \(precisionInProse(precision)) from Hugging Face, then transcribes the recording you just made. It is kept until then.")
}
