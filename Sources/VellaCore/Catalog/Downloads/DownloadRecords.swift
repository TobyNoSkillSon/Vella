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
    /// The files Get fetches and the folder must hold afterwards (catalog `files`); nil = every allowed data file.
    public var files: [String]?
    public init(
        id: String, name: String, quantization: String, repository: String, revision: String, downloadBytes: Int64, architecture: String, license: String, recommendation: String,
        recommended: Bool? = nil, files: [String]? = nil
    ) {
        self.id = id; self.name = name; self.quantization = quantization; self.repository = repository
        self.revision = revision; self.downloadBytes = downloadBytes; self.architecture = architecture
        self.license = license; self.recommendation = recommendation; self.recommended = recommended
        self.files = files
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
