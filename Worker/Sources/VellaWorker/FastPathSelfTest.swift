import Foundation
import MLX
import MLXAudioSTT
import VellaWorkerSupport

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

    /// The child's verdict: `failed` names the tolerant components that failed (component → why); an exact-component
    /// failure is `passed == false`.
    struct SelfTestOutcome: Equatable {
        var passed: Bool
        var failed: [String: String] = [:]
    }

    /// Child process, two stages (lab/notes/GATE-REVISION.md). Per clip: stock tokens; the optimized path with every
    /// tolerant component off must reproduce them exactly (non-empty, finite); then each tolerant component alone on
    /// top of it must stay finite and within its model-side bound (e.g. the NAX encoder deviation), and over all clips
    /// its words may differ from stock's by at most `maxTolerantWordEdits` edits. Without tolerant components this is
    /// the token-exact test of every optimized component.
    static func runSelfTest(_ model: any FastPathCapable, input: (MLXArray) -> MLXArray) throws -> SelfTestOutcome {
        debug("loaded")
        let names = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_CLIP"].map { [$0] } ?? model.fastPathSelfTestClips
        let component = ProcessInfo.processInfo.environment["VELLA_KERNEL_DIAGNOSTIC_COMPONENT"] ?? "both"
        guard !names.isEmpty else { return SelfTestOutcome(passed: false) }
        let tolerant = model.fastPathTolerantComponents
        var edits: [String: Int] = [:]
        var failed: [String: String] = [:]
        defer { model.fastPathDisabledComponents = []; _ = model.configureFastPath(enabled: false, component: component) }
        for name in names {
            guard let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : selfTestClip(name) else {
                // Setup, not evidence against the kernels: inconclusive, never a sticky failure.
                debug("\(name): clip not found"); exit(FastPathGate.inconclusive)
            }
            let audio = try Audio(url.path)
            let samples = input(MLXArray(audio.samples))
            let stock = model.qualificationTokens(audio: samples)
            debug("\(name): stock \(stock.count)")
            // Stage 1: exact components, token-exact.
            model.fastPathDisabledComponents = Set(tolerant)
            guard model.configureFastPath(enabled: true, component: component) else { debug("unsupported fast modules \(component)"); return SelfTestOutcome(passed: false) }
            let fast = model.qualificationTokens(audio: samples)
            let finite = model.fastPathFinite
            debug("\(name): fast \(fast.count); finite \(finite); equal \(stock == fast); first different \(Array(zip(stock, fast)).firstIndex(where: { $0.0 != $0.1 }).map(String.init) ?? "none")")
            _ = model.configureFastPath(enabled: false, component: component)
            guard stock == fast, !stock.isEmpty, finite else { return SelfTestOutcome(passed: false) }
            // Stage 2: each tolerant component on top of the exact path, within tolerance.
            let stockWords = model.qualificationWords(stock)
            for part in tolerant where failed[part] == nil {
                model.fastPathDisabledComponents = Set(tolerant).subtracting([part])
                guard model.configureFastPath(enabled: true, component: component) else { failed[part] = "unsupported"; continue }
                let tokens = model.qualificationTokens(audio: samples)
                let partFinite = model.fastPathFinite
                _ = model.configureFastPath(enabled: false, component: component)
                let words = FastPathGate.wordEdits(stockWords, model.qualificationWords(tokens))
                edits[part, default: 0] += words
                debug("\(name): \(part) \(tokens.count) tokens; finite \(partFinite); word edits \(words)")
                if !partFinite { failed[part] = "\(name): non-finite or over its deviation bound" }
                else if tokens.isEmpty { failed[part] = "\(name): empty output" }
                else if edits[part, default: 0] > FastPathGate.maxTolerantWordEdits {
                    failed[part] = "word edits \(edits[part, default: 0]) > \(FastPathGate.maxTolerantWordEdits) over the clips"
                }
            }
        }
        debug("tolerant: \(tolerant) word edits \(edits) failed \(failed)")
        return SelfTestOutcome(passed: true, failed: failed)
    }
}
