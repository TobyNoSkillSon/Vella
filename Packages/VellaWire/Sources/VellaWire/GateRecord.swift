/// A persisted fast-path gate verdict (`<Worker data>/FastPath/<key>.json`): every value a string, as the gate writes
/// it and `vella diagnose` reads it.
public struct GateRecord: Equatable, Sendable {
    public enum Status: String, Sendable { case fast, stock, inconclusive }
    public var status: Status
    public var workerVersion: String?
    public var gpuFamily: String?
    public var osBuild: String?
    public var date: String?
    /// Consecutive inconclusive self-tests (only with `inconclusive`).
    public var count: Int?
    /// The model folder's name, never its path.
    public var model: String?
    /// Why the model runs stock, or which tolerant components stay off.
    public var reason: String?
    /// Tolerant components a `fast` verdict leaves off, with why (`disabled.<component>` keys).
    public var disabled: [String: String]

    public init(status: Status, workerVersion: String? = nil, gpuFamily: String? = nil, osBuild: String? = nil, date: String? = nil,
                count: Int? = nil, model: String? = nil, reason: String? = nil, disabled: [String: String] = [:]) {
        self.status = status; self.workerVersion = workerVersion; self.gpuFamily = gpuFamily; self.osBuild = osBuild; self.date = date
        self.count = count; self.model = model; self.reason = reason; self.disabled = disabled
    }

    static let disabledPrefix = "disabled."

    /// Reads a decoded verdict file; nil without a known status. Values that are not strings are ignored.
    public init?(json: [String: Any]) {
        guard let raw = json["status"] as? String, let status = Status(rawValue: raw) else { return nil }
        func text(_ key: String) -> String? { json[key] as? String }
        self.init(status: status, workerVersion: text("workerVersion"), gpuFamily: text("gpuFamily"), osBuild: text("osBuild"),
                  date: text("date"), count: text("count").flatMap(Int.init), model: text("model"), reason: text("reason"),
                  disabled: Dictionary(uniqueKeysWithValues: json.compactMap { key, value in
                      guard key.hasPrefix(Self.disabledPrefix), let why = value as? String else { return nil }
                      return (String(key.dropFirst(Self.disabledPrefix.count)), why)
                  }))
    }

    /// The file's object.
    public var json: [String: String] {
        var object = ["status": status.rawValue]
        for (key, value) in [("workerVersion", workerVersion), ("gpuFamily", gpuFamily), ("osBuild", osBuild), ("date", date),
                             ("count", count.map(String.init)), ("model", model), ("reason", reason)] {
            if let value { object[key] = value }
        }
        for (component, why) in disabled { object[Self.disabledPrefix + component] = why }
        return object
    }
}
