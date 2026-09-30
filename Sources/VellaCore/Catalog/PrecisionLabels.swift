import Foundation

// MARK: Precision labels

/// `4-bit` → `4b`; exact float labels (`BF16`, `FP16`, `FP32`) stay. BF16 and FP16 are different formats.
public func precisionLabel(legacyQuantization q: String) -> String {
    if q.hasSuffix("-bit"), let bits = Int(q.dropLast(4)) { return "\(bits)b" }
    if q.lowercased() == "unquantized" { return "FP32" }
    return q
}
/// `4b` → `4-bit` (the downloader's spelling); other labels unchanged.
public func legacyQuantization(_ label: String) -> String {
    if label.hasSuffix("b"), let bits = Int(label.dropLast()) { return "\(bits)-bit" }
    return label
}
/// Bits per weight of a precision label, for ordering and the 4-bit floor: `4b` 4, `BF16`/`FP16` 16, `FP32` 32,
/// `ternary` 1.58. Nil for an unknown label.
public func labelBits(_ label: String) -> Double? {
    switch label.uppercased() {
    case "FP32", "F32": return 32
    case "BF16", "FP16", "F16": return 16
    case "TERNARY", "1.58B": return 1.58
    default:
        if label.lowercased().hasSuffix("b"), let bits = Double(label.dropLast()) { return bits }
        return nil
    }
}
/// Highest precision first; FP16 before BF16 at equal bits so the order is stable.
public func orderedPrecisions(_ labels: [String]) -> [String] {
    labels.sorted { a, b in
        let x = labelBits(a) ?? 0, y = labelBits(b) ?? 0
        return x == y ? a > b : x > y
    }
}
/// The Q column's bare width for a precision: `FP32` → `32`, `BF16` → `16`, `8b` → `8`, `4b` → `4`, ternary → `1.58`.
/// Nil for an unknown label.
public func precisionWidth(_ label: String) -> String? {
    guard let bits = labelBits(label) else { return nil }
    return bits == bits.rounded() ? String(Int(bits)) : String(format: "%g", bits)
}
/// A precision in prose (menu header, messages): quantized `4-bit`, `8-bit`; float formats exact (`BF16`, `FP32`).
public func precisionInProse(_ label: String) -> String { legacyQuantization(label) }
/// The exact format of a precision label, for tooltips: `BF16 (bfloat16)`, `FP16 (float16)`, `FP32 (float32)`,
/// `4-bit quantized`, `ternary (1.58-bit)`.
public func precisionFormatName(_ label: String) -> String {
    switch label.uppercased() {
    case "FP32", "F32": return "FP32 (float32)"
    case "BF16": return "BF16 (bfloat16)"
    case "FP16", "F16": return "FP16 (float16)"
    case "TERNARY", "1.58B": return "ternary (1.58-bit)"
    default:
        if label.lowercased().hasSuffix("b"), let bits = Int(label.dropLast()) { return "\(bits)-bit quantized" }
        return label
    }
}

/// Offered precisions for a family, highest first. With `tiers_offered` (the shipped catalog): the precision label of
/// each offered tier (16 = the 16-bit variant, 8 = `8b`, 4 = `4b`); FP32 is never a tier. Without it (older catalogs,
/// fixtures): every catalogued variant, never below 4 bits unless that is the model's native format.
public func precisionOptions(_ family: ModelFamily) -> [String] {
    if let tiers = family.tiersOffered {
        return orderedPrecisions(tiers.compactMap { ModelTier(rawValue: $0).flatMap { precisionLabel(family, tier: $0) } })
    }
    return orderedPrecisions(family.variants.keys.filter { $0 == family.native || (labelBits($0) ?? 0) >= 4 })
}
