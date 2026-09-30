import Foundation

// The Models table's Capabilities column: fixed icon slots derived from models.json, one line of hover text each.
// Only what the catalog states is shown, and only capabilities that genuinely differ (Toby, 30 Sep). Slots (in column
// order):
//   languages – the model transcribes more than one language (every Vella model): one globe for every model, the count
//               in its text ("25 European languages", "30 languages").
//   streaming – the model transcribes audio as it arrives (catalog `mode: streaming`).
// Not slots: separate language groups such as Chinese, Japanese and Korean (the globe's count covers them),
// punctuation and casing (every model writes them; the Format column measures how well), timestamps and translation
// (the catalog does not state them; a slot needs a catalog field first).

public enum Capability: String, CaseIterable, Codable {
    case languages, streaming
    /// The filter strip's label: "show only models with …".
    public var filterTitle: String {
        switch self {
        case .languages: return "Several languages"
        case .streaming: return "Streaming"
        }
    }
    /// The one globe (every multilingual model) and the streaming waveform.
    public var symbol: String {
        switch self {
        case .languages: return "globe"
        case .streaming: return "waveform"
        }
    }
    /// A filter by it would only repeat a section of the table (Streaming has its own section).
    var repeatsASection: Bool { self == .streaming }
}

/// One filled slot: its SF Symbol and its one-line hover text.
public struct CapabilitySlot: Equatable {
    public var capability: Capability
    public var symbol: String
    public var help: String
    public init(capability: Capability, symbol: String, help: String) { self.capability = capability; self.symbol = symbol; self.help = help }
}

/// ISO 639 codes of languages spoken natively in Europe (a model listing only these is "European").
public let europeanLanguageCodes: Set<String> = [
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es",
    "sv", "ru", "uk", "no", "nb", "nn", "is", "ga", "cy", "eu", "ca", "gl", "sq", "mk", "sr", "bs", "be", "lb", "fo", "br", "oc", "la", "gd"
]

/// The streaming slot's text.
public let streamingCapabilityHelp = "Streams: types the text while you speak"

/// A family's filled slots by capability (an absent key = an empty slot).
public func capabilitySlots(_ f: ModelFamily) -> [Capability: CapabilitySlot] {
    var slots: [Capability: CapabilitySlot] = [:]
    let codes = Set(f.languages.map { $0.lowercased() })
    if codes.count > 1 {
        let european = codes.isSubset(of: europeanLanguageCodes)
        slots[.languages] = CapabilitySlot(
            capability: .languages, symbol: Capability.languages.symbol,
            help: european ? "\(codes.count) European languages" : "\(codes.count) languages")
    }
    if f.mode == .streaming {
        slots[.streaming] = CapabilitySlot(capability: .streaming, symbol: Capability.streaming.symbol, help: streamingCapabilityHelp)
    }
    return slots
}

/// Whether a family has every capability in `filter` (an empty filter keeps every family).
public func hasCapabilities(_ f: ModelFamily, _ filter: Set<Capability>) -> Bool {
    filter.isEmpty || filter.isSubset(of: Set(capabilitySlots(f).keys))
}

/// The capabilities worth a filter checkbox: present on some of `families` but not all (a checkbox that would keep or
/// drop every row is left out), and not one the table's sections already separate.
public func filterableCapabilities(_ families: [ModelFamily]) -> [Capability] {
    Capability.allCases.filter { c in
        let count = families.filter { capabilitySlots($0)[c] != nil }.count
        return !c.repeatsASection && count > 0 && count < families.count
    }
}
