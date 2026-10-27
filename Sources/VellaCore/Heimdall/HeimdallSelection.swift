import Foundation

/// Where dictation's model comes from: Heimdall's copy of Parakeet v3 Ultra (the "from Heimdall" row), or a model of
/// Vella's own (any other dictation row).
public enum DictationSource: String, Codable, Sendable {
    case heimdall, own
}

/// The "from Heimdall" row's state. Present: Heimdall's model answers. Offline: Heimdall is on this Mac (or was
/// answering) but its model is gone, busy or not answering. Absent: no Heimdall app on this Mac.
public enum HeimdallPresence: String, Sendable {
    case present, offline, absent
    public static func of(installed: Bool, ready: Bool, unavailable: Bool) -> HeimdallPresence {
        if ready && !unavailable { return .present }
        return installed || ready ? .offline : .absent
    }
}

public enum HeimdallApp {
    /// The personal build and the public alpha ("Heimdall Alpha").
    public static let bundleIdentifiers = ["dev.heimdall.app", "com.tobynoskillson.heimdall"]
    /// Info.plist key for Heimdall's public project page. Unset until that page exists: the absent row then opens nothing.
    public static let projectURLKey = "VellaHeimdallProjectURL"
    /// An https URL from the key, else nil.
    public static func projectURL(_ info: [String: Any]?) -> URL? {
        guard let text = info?[projectURLKey] as? String, let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
            url.scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// The dictation source in effect. An explicit choice always wins and survives Heimdall coming and going. Without one,
/// a selected model of Vella's own (chosen before this setting existed) stays; only a user who never chose (a fresh
/// install) gets Heimdall's model while Heimdall is on this Mac.
public func effectiveDictationSource(_ config: Configuration, heimdallDetected: Bool) -> DictationSource {
    if let chosen = config.dictationSource { return chosen }
    // A model chosen before this setting existed, or one an upgrade cleared (its reason is kept until a new choice).
    if !config.model.isEmpty || config.clearedSelectionReasons[RecognitionMode.dictation.rawValue] != nil { return .own }
    return heimdallDetected ? .heimdall : .own
}
