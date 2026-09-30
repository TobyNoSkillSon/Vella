import Foundation
import VellaCore
import VellaWire

/// Launching a recognition helper (dictation, streaming, calibration): the helpers' offline environment, and reading
/// a helper's stdout off the main actor.
enum WorkerProcess {
    /// This process's environment with the Hub libraries held offline; `recipe` is the selection (`VELLA_RECIPE`).
    static func environment(recipe: Recipe? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"] { env[key] = "1" }
        if let recipe { env[Recipe.variable] = recipe.rawValue }
        return env
    }
    /// Delivers `handle`'s data as it arrives until end of file, then closes the handle and calls `ended`.
    static func forward(_ handle: FileHandle, to receive: @escaping (Data) async -> Void, ended: @escaping () async -> Void) {
        Task.detached {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                await receive(data)
            }
            try? handle.close()
            await ended()
        }
    }
}
