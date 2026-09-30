import Foundation
import Testing

/// One serialized root for every worker suite: several tests set process environment variables that the code under
/// test reads (`VELLA_RECIPE`, component switches, `VELLA_STUB_MODELS`), so no two tests may run at once.
/// The worker package builds with the Command Line Tools toolchain, which ships swift-testing but not XCTest.
@Suite(.serialized) struct WorkerTests {}

/// A fresh directory under the temporary folder, removed when the value goes away.
final class Scratch {
    let url: URL
    init(_ prefix: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Sets environment variables for the duration of `body`, then restores what was there.
func withEnvironment<T>(_ values: [String: String?], _ body: () throws -> T) rethrows -> T {
    let saved = values.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (key, value) in values { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
    defer { for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
    return try body()
}
