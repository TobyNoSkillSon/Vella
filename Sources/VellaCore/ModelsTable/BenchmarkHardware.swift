import Foundation

/// Catalog measurements are qualified on one configuration, not an entire chip generation. Speed and energy depend on
/// the Mac; word error, format errors and peak memory depend on the precision, not the chip (Toby, 15 Oct), so they
/// read the same everywhere. On any other Mac speed and J / min show the measured M5 Max figure as a reference, marked
/// by a triangle, with the plain number (never a relative claim).
public struct BenchmarkHardware: Equatable, Sendable {
    public var chip: String?
    public var gpuCores: Int?
    public init(chip: String?, gpuCores: Int?) { self.chip = chip; self.gpuCores = gpuCores }
    public static let measured = BenchmarkHardware(chip: "Apple M5 Max", gpuCores: 40)
    /// The measured configuration's name in tooltips and labels.
    public static let measuredName = "M5 Max"
    public var isMeasuredConfiguration: Bool {
        displayChip(chip) == displayChip(Self.measured.chip) && gpuCores == Self.measured.gpuCores
    }
    public var label: String {
        (displayChip(chip) ?? "unknown chip") + (gpuCores.map { ", \($0) GPU cores" } ?? ", GPU core count unknown")
    }
    /// The measured configuration as this Mac's reference names it: "M5 Max", or "M5 Max 40-core" on an M5 Max with
    /// another GPU core count, so the same chip name does not read as this Mac's figure.
    public var referenceName: String {
        displayChip(chip) == displayChip(Self.measured.chip) ? "\(Self.measuredName) \(Self.measured.gpuCores ?? 40)-core" : Self.measuredName
    }
    /// The reference's name on any Mac but the measured one (nil there).
    public var speedReferenceLabel: String? { isMeasuredConfiguration ? nil : referenceName }
    public var caveat: String? {
        isMeasuredConfiguration ? nil : "Measured on an M5 Max (40-core GPU). Your Mac will differ; vella diagnose measures it."
    }
    public func speedText(_ value: Double?) -> String? { formatSpeed(value) }
    /// The measured joules per audio minute, on every Mac (a reference figure outside the measured configuration).
    public func energyText(_ value: Double?) -> String? { formatEnergy(value) }
    /// The first tooltip line of a reference figure: `Not measured on your Mac. M5 Max: 507× real time.`; nil on the
    /// measured configuration or without a figure.
    public func referenceLine(speed: Double?) -> String? {
        guard !isMeasuredConfiguration, let text = formatSpeed(speed) else { return nil }
        return "Not measured on your Mac. \(referenceName): \(text) real time."
    }
    public func referenceLine(energy: Double?) -> String? {
        guard !isMeasuredConfiguration, let text = formatEnergy(energy) else { return nil }
        return "Not measured on your Mac. \(referenceName): \(text) per audio minute."
    }
    public func figures(_ result: PrecisionResult) -> [String: Any] {
        let bytes = try? JSONEncoder().encode(result)
        var fields = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let kind = isMeasuredConfiguration ? "measured" : "measured on M5 Max, not this Mac"
        fields["speed_kind"] = kind
        fields["speed_measured_on"] = "Apple M5 Max (40-core GPU)"
        fields["measured_on_this_mac"] = isMeasuredConfiguration
        fields["energy_kind"] = kind
        if !isMeasuredConfiguration { fields["hardware_note"] = caveat }
        return fields
    }
}
