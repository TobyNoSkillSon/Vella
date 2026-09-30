import Foundation
@testable import Vella
import VellaCore

extension Runtime {
    /// An isolated runtime: its own support dir, a fake memory probe and fast minutes. Never the real support dir.
    @MainActor static func isolated(_ root: URL, availableMB: Double = 100_000, minuteSeconds: Double = 60) throws -> Runtime {
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let memory = root.appendingPathComponent("memory.json")
        try JSONSerialization.data(withJSONObject: ["available_mb": availableMB]).write(to: memory)
        return Runtime(support: support, environment: ["VELLA_TEST_MEMORY_FILE": memory.path, "VELLA_TEST_MINUTE_SECONDS": String(minuteSeconds)])
    }
    @MainActor func setAvailableMB(_ value: Double) throws {
        guard let file = probe.testFile else { return }
        try JSONSerialization.data(withJSONObject: ["available_mb": value]).write(to: file)
    }
}
