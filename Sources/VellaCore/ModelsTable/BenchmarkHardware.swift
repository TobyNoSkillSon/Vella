import Foundation

/// Catalog measurements are qualified on one configuration, not an entire chip generation.
public struct BenchmarkHardware: Equatable, Sendable {
    public var chip: String?
    public var gpuCores: Int?
    public init(chip: String?, gpuCores: Int?) { self.chip = chip; self.gpuCores = gpuCores }
    public static let measured = BenchmarkHardware(chip: "Apple M5 Max", gpuCores: 40)
    public var isMeasuredConfiguration: Bool {
        displayChip(chip) == displayChip(Self.measured.chip) && gpuCores == Self.measured.gpuCores
    }
    public var label: String {
        (displayChip(chip) ?? "unknown chip") + (gpuCores.map { ", \($0) GPU cores" } ?? ", GPU core count unknown")
    }
    public var speedReferenceLabel: String? { isMeasuredConfiguration ? nil : "M5 Max" }
    public var caveat: String? {
        isMeasuredConfiguration ? nil : "Measured on an M5 Max (40-core GPU). Your Mac will differ; vella diagnose measures it."
    }
    public func speedText(_ value: Double?) -> String? { formatSpeed(value) }
    public func energyText(_ value: Double?) -> String? {
        isMeasuredConfiguration ? formatEnergy(value) : (value == nil ? nil : "not known")
    }
    public func figures(_ result: PrecisionResult) -> [String: Any] {
        let bytes = try? JSONEncoder().encode(result)
        var fields = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        fields["speed_kind"] = "measured"
        fields["speed_measured_on"] = "Apple M5 Max (40-core GPU)"
        fields["measured_on_this_mac"] = isMeasuredConfiguration
        fields["energy_kind"] = isMeasuredConfiguration ? "measured" : "not known"
        if !isMeasuredConfiguration { fields["j_per_min"] = NSNull(); fields["hardware_note"] = caveat }
        return fields
    }
}
