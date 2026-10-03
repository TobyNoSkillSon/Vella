import Foundation
import VellaWire

public func humanDType(precision: String?, tier: ModelTier? = nil, familyID: String) -> String {
    switch (precision ?? "").lowercased() {
    case "bf16", "bfloat16": return "bf16"
    case "fp16", "float16": return "fp16"
    default:
        switch tier ?? precision.flatMap(modelTier(ofPrecision:)) ?? .t16 {
        case .t8: return "int8"
        case .t4: return "int4"
        case .t16: return familyID.lowercased().contains("whisper") ? "fp16" : "bf16"
        }
    }
}
public func compactText(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let prefix = text.prefix(max(1, limit - 1)), end = prefix.lastIndex(where: { $0.isWhitespace }) ?? prefix.endIndex
    return prefix[..<end].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
}
public func sentence(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed + (trimmed.last.map { ".!?…".contains($0) } == true ? "" : ".")
}
