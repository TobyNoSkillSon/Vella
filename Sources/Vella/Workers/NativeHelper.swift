import Foundation
import VellaCore

/// A private executable shipped in the same immutable bundle as Vella.
/// An explicit override is reserved for isolated tests, never read from user config.
enum NativeHelper {
    static func executable(_ name: String, override: URL? = nil) throws -> URL {
        let url = override ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VellaError.message(
                "Vella's native \(name == "VellaWorker" ? "dictation" : "streaming") helper is missing or not executable. Reinstall the app; saved audio is retained.")
        }
        return url
    }
}
