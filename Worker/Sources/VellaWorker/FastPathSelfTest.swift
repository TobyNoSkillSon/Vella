import Foundation
import MLX
import MLXAudioSTT

enum FastPathNonFinite: Error { case invalid }

extension FastPathGate {
    /// A bundled self-test clip, found explicitly. SwiftPM's generated resource accessor looks beside the app bundle and in the
    /// build machine's `.build` directory, and traps when neither exists, so a release built elsewhere crashed every
    /// self-test (inconclusive, then stock for good). The app ships the resource bundle in Contents/Resources; a
    /// package build keeps it next to the executable.
    static func selfTestClip(_ name: String) -> URL? {
        let bundleName = "VellaWorker_VellaWorker.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                     Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")]
        for root in roots.compactMap({ $0 }) {
            for folder in [root.appendingPathComponent(bundleName), root.appendingPathComponent(bundleName).appendingPathComponent("Contents/Resources")] {
                let url = folder.appendingPathComponent("\(name).wav")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Child process: stock and fast must emit identical, non-empty, finite token IDs on every clip.
    static func runSelfTest(_ model: any FastPathCapable, input: (MLXArray) -> MLXArray) throws -> Bool {
        debug("loaded")
        let names = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_CLIP"].map { [$0] } ?? model.fastPathSelfTestClips
        let component = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_COMPONENT"] ?? "both"
        guard !names.isEmpty else { return false }
        for name in names {
            guard let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : selfTestClip(name) else {
                // Setup, not evidence against the kernels: inconclusive, never a sticky failure.
                debug("\(name): clip not found"); exit(FastPathGate.inconclusive)
            }
            let audio = try Audio(url.path)
            let samples = input(MLXArray(audio.samples))
            let stock = model.qualificationTokens(audio: samples)
            debug("\(name): stock \(stock.count)")
            guard model.configureFastPath(enabled: true, component: component) else { debug("unsupported fast modules \(component)"); return false }
            let fast = model.qualificationTokens(audio: samples)
            let finite = model.fastPathFinite
            debug("\(name): fast \(fast.count); equal \(stock == fast); first different \(Array(zip(stock, fast)).firstIndex(where: { $0.0 != $0.1 }).map(String.init) ?? "none")")
            _ = model.configureFastPath(enabled: false, component: component)
            guard stock == fast, !stock.isEmpty, finite else { return false }
        }
        return true
    }
}
