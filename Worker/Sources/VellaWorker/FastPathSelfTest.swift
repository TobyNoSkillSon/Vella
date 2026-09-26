import Foundation
import MLX
import MLXAudioSTT

enum FastPathNonFinite: Error { case invalid }

extension FastPathGate {
    /// Child process: stock and fast must emit identical, non-empty, finite token IDs on every clip.
    static func runSelfTest(_ model: any FastPathCapable, input: (MLXArray) -> MLXArray) throws -> Bool {
        debug("loaded")
        let names = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_CLIP"].map { [$0] } ?? model.fastPathSelfTestClips
        let component = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_COMPONENT"] ?? "both"
        guard !names.isEmpty else { return false }
        for name in names {
            guard let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : Bundle.module.url(forResource: name, withExtension: "wav") else { return false }
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
