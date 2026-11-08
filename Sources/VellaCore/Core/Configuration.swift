import Foundation

public enum RecognitionMode: String, Codable, CaseIterable, Sendable {
    case dictation, streaming
    public var title: String { self == .dictation ? "Dictation" : "Streaming" }
}

public struct Configuration: Codable {
    /// Saved dictation selection, independent of the current mode.
    public var model: String
    public var mode: RecognitionMode
    public var streamingModel: String
    public var preferredMicrophone: String
    public var fallbackMicrophone: String
    /// Keep Hot windows, memory mode and the launch set (manual loads only; empty on a fresh install).
    public var residency = ResidencySettings()
    /// Catalog family id → the precision it was last loaded at (exact label). Written only by a successful Load or
    /// Reload, next to `model`/`streamingModel`; the Models table shows it on an unloaded row.
    public var lastLoaded: [String: String] = [:]
    /// Catalog family id → the tier × Exact/Fast it was last loaded with (Selection.swift; always the optimized request,
    /// a 2.0 Standard entry decodes as one). Written only by a successful Load or Reload, or adjusted during an upgrade
    /// migration; a family without one shows 16 · Fast.
    public var selections: [String: ModelSelection] = [:]
    /// An upgrade-cleared mode retains its reason until the user selects a replacement.
    public var clearedSelectionReasons: [String: String] = [:]
    /// The user's explicit choice between Heimdall's model and Vella's own (HeimdallSelection.swift); nil: never chosen.
    public var dictationSource: DictationSource?
    /// Top-level keys this version does not know, written by a newer Vella, kept exactly as read and written back, so
    /// running an older build (an update rolled back, a reinstall of an older release) never drops a newer setting.
    /// 2.2.0 did not know `dictationSource` and dropped the "from Heimdall" choice that way.
    public var unknownKeys: [String: StoredJSON] = [:]
    public init(
        model: String,
        preferredMicrophone: String = "", fallbackMicrophone: String = "",
        mode: RecognitionMode = .dictation, streamingModel: String = ""
    ) {
        self.model = model
        self.mode = mode; self.streamingModel = streamingModel
        self.preferredMicrophone = preferredMicrophone; self.fallbackMicrophone = fallbackMicrophone
    }
    /// Earlier versions also stored `executable` (the Python runtime of 0.8.x); it is ignored when read.
    private enum CodingKeys: String, CodingKey {
        case model, mode, streamingModel, preferredMicrophone, fallbackMicrophone, residency, lastLoaded, selections, clearedSelectionReasons
        case dictationSource
    }
    /// Keys that are dropped on purpose rather than kept as unknown.
    static let retiredKeys: Set<String> = ["executable"]
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public init(from decoder: Decoder) throws {
        if let all = try? decoder.container(keyedBy: AnyKey.self) {
            for key in all.allKeys where CodingKeys(stringValue: key.stringValue) == nil && !Self.retiredKeys.contains(key.stringValue) {
                if let value = try? all.decode(StoredJSON.self, forKey: key) { unknownKeys[key.stringValue] = value }
            }
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Each field on its own: a value a newer Vella writes that this one cannot read (a new mode, say) resets only
        // that field, never the whole file (every writer would then save a blank configuration over it).
        model = (try? values.decodeIfPresent(String.self, forKey: .model)) ?? ""
        mode = (try? values.decodeIfPresent(RecognitionMode.self, forKey: .mode)) ?? .dictation
        streamingModel = (try? values.decodeIfPresent(String.self, forKey: .streamingModel)) ?? ""
        preferredMicrophone = (try? values.decodeIfPresent(String.self, forKey: .preferredMicrophone)) ?? ""
        fallbackMicrophone = (try? values.decodeIfPresent(String.self, forKey: .fallbackMicrophone)) ?? ""
        residency = (try? values.decodeIfPresent(ResidencySettings.self, forKey: .residency)) ?? ResidencySettings()
        lastLoaded = (try? values.decodeIfPresent([String: String].self, forKey: .lastLoaded)) ?? [:]
        clearedSelectionReasons = (try? values.decodeIfPresent([String: String].self, forKey: .clearedSelectionReasons)) ?? [:]
        selections = (try? values.decodeIfPresent([String: ModelSelection].self, forKey: .selections)) ?? [:]
        dictationSource = try? values.decodeIfPresent(DictationSource.self, forKey: .dictationSource)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: AnyKey.self)
        // Unknown keys first, so a known key of the same name (never expected) is written by this version.
        for (key, value) in unknownKeys where CodingKeys(stringValue: key) == nil { try values.encode(value, forKey: AnyKey(key)) }
        try values.encode(model, forKey: AnyKey(CodingKeys.model.stringValue))
        try values.encode(mode, forKey: AnyKey(CodingKeys.mode.stringValue))
        try values.encode(streamingModel, forKey: AnyKey(CodingKeys.streamingModel.stringValue))
        try values.encode(preferredMicrophone, forKey: AnyKey(CodingKeys.preferredMicrophone.stringValue))
        try values.encode(fallbackMicrophone, forKey: AnyKey(CodingKeys.fallbackMicrophone.stringValue))
        try values.encode(residency, forKey: AnyKey(CodingKeys.residency.stringValue))
        try values.encode(lastLoaded, forKey: AnyKey(CodingKeys.lastLoaded.stringValue))
        try values.encode(selections, forKey: AnyKey(CodingKeys.selections.stringValue))
        try values.encode(clearedSelectionReasons, forKey: AnyKey(CodingKeys.clearedSelectionReasons.stringValue))
        try values.encodeIfPresent(dictationSource, forKey: AnyKey(CodingKeys.dictationSource.stringValue))
    }
    /// A successful Load/Reload: the model becomes its mode's model (what the next dictation or streaming session
    /// loads) and its family remembers the precision.
    public mutating func recordLoad(path: String, mode: RecognitionMode, family: String?, precision: String?, selection: ModelSelection? = nil) {
        selectModel(path, for: mode)
        markOwnChoice(mode)
        if let family, let precision { lastLoaded[family] = precision }
        if let family, let selection { selections[family] = selection.request }
    }
    public var selectedModel: String { mode == .dictation ? model : streamingModel }
    /// The user chose a dictation model of Vella's own (Load, Get, Use): an explicit choice over Heimdall's row. Only user
    /// actions call this; migrations re-select through `selectModel` and leave the choice as it was.
    public mutating func markOwnChoice(_ mode: RecognitionMode) { if mode == .dictation { dictationSource = .own } }
    public mutating func selectModel(_ path: String, for mode: RecognitionMode) {
        if !path.isEmpty { clearedSelectionReasons[mode.rawValue] = nil }
        if mode == .dictation { model = path } else { streamingModel = path }
    }
    public func forRecording() throws -> Configuration {
        try validate()
        var snapshot = self
        snapshot.model = selectedModel
        return snapshot
    }
    public func validate(requiresModel: Bool = true) throws {
        guard !requiresModel || !selectedModel.isEmpty else {
            throw VellaError.message("Open Vella → Models… and choose Get or Load for a \(mode.title) model.")
        }
    }
}

/// Any JSON value, kept as read (Configuration.unknownKeys).
public enum StoredJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([StoredJSON]), object([String: StoredJSON])
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([StoredJSON].self) {
            self = .array(value)
        } else {
            self = .object(try single.decode([String: StoredJSON].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let value): try single.encode(value)
        case .number(let value): try single.encode(value)
        case .string(let value): try single.encode(value)
        case .array(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        }
    }
}
