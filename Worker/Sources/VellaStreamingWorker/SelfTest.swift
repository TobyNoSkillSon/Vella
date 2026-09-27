import Foundation
import MLX
import MLXAudioSTT

/// `VellaStreamingWorker fast-selftest --model <dir>`: the child `FastPathGate.qualify` runs before the optimized
/// streaming path is used. One stream — public clip-b, 1.2 s of silence (an endpoint and reset), clip-e, finish —
/// goes through the production `StreamingSession` in 100-ms packets on stock MLX and then on the optimized path
/// of the same loaded model. Exit 0: text non-empty, encoder outputs finite, and every reply (committed, partial,
/// frames, done) identical — or, with the fused conformer layer, within its tolerance (`FusedTolerance`: encoder
/// deviation, committed words, commit timing, partial replies). Exit 2: evidence against the optimized path.
/// Exit 3: could not run (inconclusive).
enum StreamingSelfTest {
    static let clips = ["clip-b", "clip-e"]

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 2, arguments[0] == "--model", let path = try? streamingModelPath(arguments[1]) else { return FastPathGate.inconclusive }
        switch ProcessInfo.processInfo.environment["VELLA_TEST_SELFTEST_FAULT"] {
        case "crash": abort()
        case "exit": return 9
        case "mismatch": return FastPathGate.verdictFailed
        default: break
        }
        guard let audio = stream() else { FastPathGate.debug("streaming self-test: clips not found"); return FastPathGate.inconclusive }
        guard let native = try? withError({ try NemotronNative(path, gate: false) }) else { return FastPathGate.inconclusive }
        native.strict = true
        defer { native.close() }
        do {
            let stock = try withError { try replies(native, path: path, audio: audio) }
            native.enableOptimized()
            try native.reset()
            let fast = try withError { try replies(native, path: path, audio: audio) }
            let text = FusedTolerance.committedText(stock)
            guard !text.isEmpty, !native.sawNonFinite, stock.count == fast.count else { return FastPathGate.verdictFailed }
            guard let deviation = native.fusedDeviation(audio: audio) else {
                // Every other optimization is bit-identical by construction: every reply must match.
                let equal = NSArray(array: stock).isEqual(to: fast)
                FastPathGate.debug("streaming self-test: \(stock.count) replies, equal \(equal), text \(text.utf8.count) B")
                return equal ? 0 : FastPathGate.verdictFailed
            }
            // Fused layer (summation order differs from stock): the documented tolerance, reply timing included.
            let verdict = FusedTolerance.judge(stock: stock, fast: fast, rms: deviation.rms)
            FastPathGate.debug("streaming self-test: \(stock.count) replies, fused deviation rms \(deviation.rms) max \(deviation.max), \(verdict.summary), text \(text.utf8.count) B")
            return verdict.accepted ? 0 : FastPathGate.verdictFailed
        } catch {
            FastPathGate.debug("streaming self-test error: \(error)")
            return FastPathGate.verdictFailed
        }
    }

    /// The production Session over one fresh session of `native`; replies without their ids.
    static func replies(_ native: NemotronNative, path: URL, audio: [Float]) throws -> [[String: Any]] {
        let session = StreamingSession { _ in native }
        var out: [[String: Any]] = []
        func call(_ request: [String: Any]) throws {
            var reply = try session.handle(request)
            reply["id"] = nil; out.append(reply)
        }
        var serial = 0
        func id() -> String { serial += 1; return String(format: "00000000-0000-4000-8000-%012x", serial) }
        try call(["id": id(), "op": "start", "model": path.path])
        for start in stride(from: 0, to: audio.count, by: 1600) {
            let packet = Array(audio[start..<min(start + 1600, audio.count)])
            try call(["id": id(), "op": "audio", "pcm": packet.withUnsafeBytes { Data($0).base64EncodedString() }])
        }
        try call(["id": id(), "op": "finish"])
        return out
    }

    /// clip-b + 1.2 s silence + clip-e, from the dictation worker's bundled public clips.
    static func stream() -> [Float]? {
        var parts: [[Float]] = []
        for name in clips {
            guard let url = clipURL(name), let samples = pcm16(url) else { return nil }
            parts.append(samples)
        }
        return parts[0] + [Float](repeating: 0, count: 19_200) + parts[1]
    }
    static func clipURL(_ name: String) -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let roots = [Bundle.main.resourceURL, executable, executable.deletingLastPathComponent().appendingPathComponent("Resources")].compactMap { $0 }
        for root in roots {
            let bundle = root.appendingPathComponent("VellaWorker_VellaWorker.bundle")
            for candidate in [bundle.appendingPathComponent("\(name).wav"), bundle.appendingPathComponent("Contents/Resources/\(name).wav")]
            where FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    /// 16-kHz mono 16-bit PCM WAV → Float in [-1, 1).
    static func pcm16(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        var offset = 12
        var format: (channels: UInt16, rate: UInt32, bits: UInt16)?
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) })
            let body = offset + 8
            guard body + size <= data.count else { return nil }
            if id == "fmt " {
                format = data.withUnsafeBytes { ($0.loadUnaligned(fromByteOffset: body + 2, as: UInt16.self),
                                                 $0.loadUnaligned(fromByteOffset: body + 4, as: UInt32.self),
                                                 $0.loadUnaligned(fromByteOffset: body + 14, as: UInt16.self)) }
            } else if id == "data" {
                guard let format, format.channels == 1, format.rate == 16_000, format.bits == 16 else { return nil }
                return data.withUnsafeBytes { raw in
                    (0..<(size / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: body + 2 * $0, as: Int16.self))) / 32768 }
                }
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
