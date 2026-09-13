import Foundation

public struct ModelRecommendation: Codable, Identifiable {
    public var id: String
    public var name: String
    public var quantization: String
    public var repository: String
    public var revision: String
    public var downloadBytes: Int64
    public var architecture: String
    public var license: String
    public var recommendation: String
    public var recommended: Bool?
    public init(id: String, name: String, quantization: String, repository: String, revision: String, downloadBytes: Int64, architecture: String, license: String, recommendation: String, recommended: Bool? = nil) {
        self.id = id; self.name = name; self.quantization = quantization; self.repository = repository
        self.revision = revision; self.downloadBytes = downloadBytes; self.architecture = architecture
        self.license = license; self.recommendation = recommendation; self.recommended = recommended
    }
}
public struct InstalledModel: Codable {
    public var path: String
    public var revision: String?
    public var name: String?
    public var quantization: String?
    public init(path: String, revision: String? = nil, name: String? = nil, quantization: String? = nil) {
        self.path = path; self.revision = revision; self.name = name; self.quantization = quantization
    }
}
public struct BenchmarkClip: Codable, Identifiable {
    public let id: String
    public let reference: String
    public let lexicalReference: String?
    public let transcript: String
    public let duration: Double
    public let seconds: Double
    public let errors: Int
    public let referenceWords: Int
    public let allSeconds: [Double]
    public let repeatTextIdentical: Bool
}
public struct BenchmarkResult: Codable, Identifiable {
    public var id: String { modelID }
    public let modelID: String
    public let modelFingerprint: String
    public let modelName: String
    public let quantization: String
    public let suiteID: String
    public let suiteHash: String
    public let machine: String
    public let machineMemoryBytes: Int64
    public let mlxAudioVersion: String
    public let mlxVersion: String
    public let measuredAt: String
    public let repeats: Int
    public let audioSeconds: Double
    public let transcriptionSeconds: Double
    public let realtimeFactor: Double
    public let wordErrorRate: Double
    public let peakProcessBytes: Int64
    public let peakMLXBytes: Int64?
    public let runtimePeakMLXBytes: Int64?
    public let clips: [BenchmarkClip]
    public let note: String
    public let formatting: FormattingResult?
    /// Legacy records are batch/dictation. Streaming needs its own measured path.
    public let recognitionMode: RecognitionMode?
    public let streamingQualified: Bool?
    public let streamingWorkerSHA256: String?
    public let complete: Bool?
    public let measurementKind: String?
    /// An estimate for this benchmark range only; never a real completion percentage.
    public func estimatedSeconds(for audioSeconds: Double) -> Double? {
        guard !clips.isEmpty, audioSeconds > 0,
              let minLength = clips.map(\.duration).min(), let maxLength = clips.map(\.duration).max(),
              audioSeconds >= minLength, audioSeconds <= maxLength else { return nil }
        let n = Double(clips.count)
        let meanX = clips.map(\.duration).reduce(0, +) / n
        let meanY = clips.map(\.seconds).reduce(0, +) / n
        let denominator = clips.map { pow($0.duration - meanX, 2) }.reduce(0, +)
        guard denominator > 0 else { return nil }
        let slope = max(0, clips.map { ($0.duration - meanX) * ($0.seconds - meanY) }.reduce(0, +) / denominator)
        return max(0.05, max(0, meanY - slope * meanX) + slope * audioSeconds)
    }
}

public enum ModelSortColumn: String, CaseIterable {
    case name, quantization, errorRate, formattedError, speed, memory
}
/// Missing measurements always sort last, in either direction.
public func sortedRecommendations(_ models: [ModelRecommendation], results: [String: BenchmarkResult], column: ModelSortColumn, ascending: Bool) -> [ModelRecommendation] {
    models.sorted { a, b in
        let left = results[a.id], right = results[b.id]
        func compare(_ x: Double?, _ y: Double?) -> Bool {
            if x == nil || y == nil {
                if x == nil && y == nil { return a.id < b.id }
                return x != nil
            }
            if x == y { return a.id < b.id }
            return ascending ? x! < y! : x! > y!
        }
        switch column {
        case .name:
            let x = a.name + a.quantization, y = b.name + b.quantization
            return x == y ? a.id < b.id : ascending ? x < y : x > y
        case .quantization: return ascending ? a.quantization < b.quantization : a.quantization > b.quantization
        case .errorRate: return compare(left?.wordErrorRate, right?.wordErrorRate)
        case .formattedError: return compare(left?.formatting?.formattedCharacterErrorRate, right?.formatting?.formattedCharacterErrorRate)
        case .speed: return compare(left?.realtimeFactor, right?.realtimeFactor)
        case .memory: return compare(left?.runtimePeakMLXBytes.map(Double.init), right?.runtimePeakMLXBytes.map(Double.init))
        }
    }
}

/// Exact chip, nearest tier in its generation, then the measured M5 Max baseline.
/// Hardware provenance remains unchanged, including for fallback results.
public func preferredBenchmark(_ candidates: [BenchmarkResult], processor: String) -> BenchmarkResult? {
    func normalized(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "apple ", with: "").trimmingCharacters(in: .whitespaces) }
    func generation(_ value: String) -> String? {
        let value = normalized(value)
        guard let range = value.range(of: #"\bm[0-9]+\b"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }
    func tier(_ value: String) -> Int {
        let value = normalized(value)
        return value.contains("ultra") ? 3 : value.contains("max") ? 2 : value.contains("pro") ? 1 : 0
    }
    func rank(_ value: String) -> Int {
        if normalized(value) == normalized(processor) { return 0 }
        if let target = generation(processor), generation(value) == target { return 10 + abs(tier(value) - tier(processor)) }
        if normalized(value) == "m5 max" { return 20 }
        return 30
    }
    return candidates.filter { rank($0.machine) < 30 }.sorted {
        if rank($0.machine) != rank($1.machine) { return rank($0.machine) < rank($1.machine) }
        if $0.repeats != $1.repeats { return $0.repeats > $1.repeats }
        if $0.audioSeconds != $1.audioSeconds { return $0.audioSeconds > $1.audioSeconds }
        if $0.measuredAt != $1.measuredAt { return $0.measuredAt > $1.measuredAt }
        return $0.machine < $1.machine
    }.first
}

public struct FormattingResult: Codable {
    public let scoringVersion: String
    public let scorerSHA256: String?
    public let lexicalNormalizerSHA256: String?
    public let matchedWordCoverage: Double?
    public let boundaryCoverage: Double?
    public let punctuationCoverage: Double?
    public let formattedCharacterErrorRate: Double
    public let capitalizationAccuracy: Double?
    public let punctuationF1: Double?
    public let quotationF1: Double?
    public let quotedReferenceClips: Int
}
