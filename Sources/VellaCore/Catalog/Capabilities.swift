import Foundation

// The Models table's Capabilities column: fixed icon slots derived from models.json, one line of hover text each.
// Only what the catalog states is shown. Slots (in column order):
//   languages – the model transcribes more than one language (every Vella model); the globe shows Europe for a
//               Europe-only model, the whole world otherwise; its text is the count ("25 European languages").
//   cjk       – it transcribes Chinese, Japanese and Korean (and says so when it also lists Cantonese).
// Not slots: streaming (the table's Streaming section already says it), punctuation and casing (every model writes
// them; the Format column measures how well), timestamps (the catalog does not state them).

public enum Capability: String, CaseIterable, Codable {
    case languages, cjk
    /// The filter strip's label: "show only models with …".
    public var filterTitle: String {
        switch self {
        case .languages: return "Several languages"
        case .cjk: return "Chinese, Japanese and Korean"
        }
    }
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

/// A family's filled slots by capability (an absent key = an empty slot).
public func capabilitySlots(_ f: ModelFamily) -> [Capability: CapabilitySlot] {
    var slots: [Capability: CapabilitySlot] = [:]
    let codes = Set(f.languages.map { $0.lowercased() })
    if codes.count > 1 {
        let european = codes.isSubset(of: europeanLanguageCodes)
        slots[.languages] = CapabilitySlot(
            capability: .languages, symbol: european ? "globe.europe.africa" : "globe",
            help: european ? "\(codes.count) European languages" : "\(codes.count) languages")
    }
    if codes.isSuperset(of: ["zh", "ja", "ko"]) {
        slots[.cjk] = CapabilitySlot(
            capability: .cjk, symbol: "character.textbox.zh",
            help: codes.contains("yue") ? "Chinese (with Cantonese), Japanese and Korean" : "Chinese, Japanese and Korean")
    }
    return slots
}

/// Whether a family has every capability in `filter` (an empty filter keeps every family).
public func hasCapabilities(_ f: ModelFamily, _ filter: Set<Capability>) -> Bool {
    filter.isEmpty || filter.isSubset(of: Set(capabilitySlots(f).keys))
}

/// The capabilities worth a filter checkbox: present on some of `families` but not all (a checkbox that would keep or
/// drop every row is left out).
public func filterableCapabilities(_ families: [ModelFamily]) -> [Capability] {
    Capability.allCases.filter { c in
        let count = families.filter { capabilitySlots($0)[c] != nil }.count
        return count > 0 && count < families.count
    }
}
