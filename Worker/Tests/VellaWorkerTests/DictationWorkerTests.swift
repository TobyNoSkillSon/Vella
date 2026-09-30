import Darwin
import Foundation
import Testing
@testable import VellaWorker
import MLXAudioSTT
import VellaWorkerSupport
import VellaWire

extension WorkerTests {
    /// The dictation worker's checkpoint admission rules and its wire helpers (CPU only).
    @Suite struct DictationWorker {
        func folder(_ scratch: Scratch, _ name: String, config: String, files: [String: String] = ["model.safetensors": "w"]) throws -> URL {
            let url = try scratch.folder(name)
            try Data(config.utf8).write(to: url.appendingPathComponent("config.json"))
            for (file, text) in files {
                try FileManager.default.createDirectory(at: url.appendingPathComponent(file).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url.appendingPathComponent(file))
            }
            return url
        }

        // MARK: admission

        @Test func admitsCatalogArchitecturesAndQuantizations() throws {
            let s = try Scratch("vella-admit")
            #expect(try admitCheckpoint(folder(s, "w", config: #"{"model_type": "whisper"}"#)) == .whisper)
            #expect(try admitCheckpoint(folder(s, "q4", config: #"{"model_type": "qwen3_asr", "quantization": {"bits": 4, "group_size": 64}}"#)) == .qwen3ASR)
            #expect(try admitCheckpoint(folder(s, "q8", config: #"{"model_type": "qwen3_asr", "quantization_config": {"bits": 8}}"#)) == .qwen3ASR)
            // NeMo transducer checkpoints (the catalog's MLX Parakeet) carry no model_type, only the NeMo target.
            let target = #"{"target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"}"#
            #expect(try admitCheckpoint(folder(s, "tdt", config: target)) == .parakeet)
        }

        @Test func refusesOtherBitWidthsArchitecturesAndCode() throws {
            let s = try Scratch("vella-admit")
            let refused: [(String, String, [String: String])] = [
                ("q3", #"{"model_type": "whisper", "quantization": {"bits": 3}}"#, ["model.safetensors": "w"]),
                ("q2", #"{"model_type": "whisper", "quantization": {"bits": 2}}"#, ["model.safetensors": "w"]),
                ("bits-string", #"{"model_type": "whisper", "quantization": {"bits": "4"}}"#, ["model.safetensors": "w"]),
                ("llama", #"{"model_type": "llama"}"#, ["model.safetensors": "w"]),
                ("typed", #"{"model_type": 7}"#, ["model.safetensors": "w"]),
                ("py", #"{"model_type": "whisper"}"#, ["model.safetensors": "w", "sub/code.py": "x"]),
                ("automap", #"{"model_type": "whisper", "auto_map": {"a": "b"}}"#, ["model.safetensors": "w"]),
                ("tok-automap", #"{"model_type": "whisper"}"#, ["model.safetensors": "w", "tokenizer_config.json": #"{"auto_map": ["x"]}"#]),
                ("noweights", #"{"model_type": "whisper"}"#, [:])
            ]
            // A ternary 2-bit Parakeet (not in the catalog) is refused like any 2-bit checkpoint.
            let nemo = #"{"target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel", "quantization": {"bits": 2, "group_size": 64}}"#
            let ternary: [(String, String, [String: String])] = [
                (
                    "ternary", nemo,
                    [
                        "model.safetensors": "w",
                        "ternary.json": #"{"quant": {"mode": "ternary", "group_size": 64}}"#
                    ]
                )
            ]
            for (name, config, files) in refused + ternary {
                let url = try folder(s, name, config: config, files: files)
                #expect(throws: (any Error).self, "\(name)") { try admitCheckpoint(url) }
            }
        }

        @Test func stubOnlyWithTheTestHook() throws {
            let s = try Scratch("vella-admit")
            let stub = try folder(s, "stub", config: #"{"model_type": "stub"}"#)
            let without = withEnvironment(["VELLA_STUB_MODELS": nil]) { try? admitCheckpoint(stub) }
            let with = withEnvironment(["VELLA_STUB_MODELS": "1"]) { try? admitCheckpoint(stub) }
            #expect(without == nil)
            #expect(with == .stub)
        }

        @Test func derivedAdmissionUsesTheFloatSource() throws {
            let s = try Scratch("vella-admit")
            let source = try folder(s, "source", config: #"{"model_type": "whisper"}"#)
            let derived = try s.folder("derived")
            try Data(#"{"schema": 1, "precision": "4b", "bits": 4, "groupSize": 64, "source": "\#(source.path)"}"#.utf8)
                .write(to: derived.appendingPathComponent("vella-derived.json"))
            #expect(try admit(derived) == .whisper)
            let quantized = try folder(s, "qsource", config: #"{"model_type": "whisper", "quantization": {"bits": 4}}"#)
            try Data(#"{"schema": 1, "precision": "4b", "bits": 4, "groupSize": 64, "source": "\#(quantized.path)"}"#.utf8)
                .write(to: derived.appendingPathComponent("vella-derived.json"))
            #expect(throws: (any Error).self) { try admit(derived) }
        }

        // MARK: wire helpers

        @Test func decodeJSONAcceptsPythonConstantsOutsideStrings() throws {
            let object = try #require(decodeJSON(Data(#"{"a": NaN, "b": -Infinity, "c": Infinity, "d": "NaN Infinity"}"#.utf8)) as? [String: Any])
            #expect(object["a"] as? Int == 1); #expect(object["b"] as? Int == 1); #expect(object["c"] as? Int == 1)
            #expect(object["d"] as? String == "NaN Infinity")
            #expect(try decodeJSON(Data(#""esc\"NaN""#.utf8)) as? String == #"esc"NaN"#)
            #expect(pythonTruthy(1)); #expect(!pythonTruthy(0)); #expect(!pythonTruthy(NSNull()))
            #expect(!pythonTruthy("")); #expect(!pythonTruthy([Any]())); #expect(!pythonTruthy([String: Any]()))
        }

        @Test func responseBytesAreSortedASCIIWithUnescapedSlashes() throws {
            let bytes = try responseBytes(["b": "é/ü", "a": 1, "c": NSNull()])
            #expect(String(decoding: bytes, as: UTF8.self) == #"{"a":1,"b":"\u00e9/\u00fc","c":null}"# + "\n")
            #expect(String(decoding: try responseBytes(["x": "😀"]), as: UTF8.self) == #"{"x":"\ud83d\ude00"}"# + "\n")
        }

        @Test func readBoundedLineDrainsOverlongLines() throws {
            let s = try Scratch("vella-wire")
            let long = String(repeating: "x", count: maximumLine + 10)
            let url = s.url.appendingPathComponent("stdin")
            try Data(("short\n" + long + "\n" + "next\n").utf8).write(to: url)
            let file = try #require(fopen(url.path, "r")); defer { fclose(file) }
            #expect(readBoundedLine(file) == Data("short\n".utf8))
            let over = try #require(readBoundedLine(file))
            alarm(0) // the overlong path arms the request deadline
            #expect(over.count == maximumLine + 1)
            #expect(readBoundedLine(file) == Data("next\n".utf8))
            #expect(readBoundedLine(file) == nil)
            #expect(maximumLine == 16 * 1024)
        }

        @Test func identifiers() {
            let id = "6f1c2a4e-8d3b-4c1a-9e7f-2b5d8c0a1e34"
            #expect(requestIdentifier(id) == id)
            #expect(requestIdentifier("{\(id)}") == "{\(id)}")
            #expect(requestIdentifier("urn:uuid:\(id)") == "urn:uuid:\(id)")
            #expect(requestIdentifier("6F1C2A4E8D3B4C1A9E7F2B5D8C0A1E34") == "6F1C2A4E8D3B4C1A9E7F2B5D8C0A1E34")
            #expect(requestIdentifier("g1") == nil)
            #expect(requestIdentifier(String(id.dropLast()) + "g") == nil)
            #expect(requestIdentifier(42) == nil)
        }

        // MARK: audio

        static func wav(frames: Int, rate: Int = 16000, bits: Int = 16) -> Data {
            var d = Data()
            func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
            func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16) }
            d.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 2); d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(bits)
            d.append(contentsOf: Array("data".utf8)); u32(frames * 2)
            for i in 0..<frames { u16(i % 2 == 0 ? 16384 : 0xc000) }
            return d
        }

        @Test func audioBounds() throws {
            let s = try Scratch("vella-audio")
            let good = s.url.appendingPathComponent("good.wav")
            try Self.wav(frames: 1600).write(to: good)
            let audio = try Audio(good.path)
            #expect(audio.samples.count == 1600)
            #expect(audio.samples[0] == 0.5); #expect(audio.samples[1] == -0.5)
            #expect(abs(audio.seconds - 0.1) < 1e-9)
            let longest = s.url.appendingPathComponent("max.wav")
            try Self.wav(frames: 480_000).write(to: longest)
            #expect(try Audio(longest.path).samples.count == 480_000)
            for (name, data) in [
                ("rate.wav", Self.wav(frames: 1600, rate: 44100)), ("bits.wav", Self.wav(frames: 1600, bits: 24)),
                ("long.wav", Self.wav(frames: 480_001)), ("empty.wav", Self.wav(frames: 0)), ("tiny.wav", Data("RIFF".utf8))
            ] {
                let url = s.url.appendingPathComponent(name)
                try data.write(to: url)
                #expect(throws: (any Error).self, "\(name)") { try Audio(url.path) }
            }
            #expect(throws: (any Error).self) { try Audio("relative.wav") }
        }

        // MARK: buffer cache between requests

        /// Kept by default; only `VELLA_DICTATION_KEEP_CACHE=0` restores the per-request clear.
        @Test func keepCacheSwitch() {
            #expect(Worker.keepCache(environment: [:]))
            #expect(Worker.keepCache(environment: ["VELLA_DICTATION_KEEP_CACHE": "1"]))
            #expect(!Worker.keepCache(environment: ["VELLA_DICTATION_KEEP_CACHE": "0"]))
            #expect(cacheBytes == 64 * 1024 * 1024)
        }

        /// The idle cache ends at most at the limit: MLX's own limit admits one freed buffer past it (a 128 MiB buffer
        /// freed into a 64 MiB-limited cache stays cached until the next allocation), so the request boundary trims.
        @Test func idleCacheIsBoundedAtTheLimit() {
            final class Fake {
                var cached: Int
                var trims = 0, clears = 0
                let afterTrim: Int
                init(_ cached: Int, afterTrim: Int) { self.cached = cached; self.afterTrim = afterTrim }
                func bound(_ limit: Int) -> BufferCache.Outcome {
                    BufferCache.bound(
                        limit: limit, cached: { self.cached },
                        trim: {
                            self.trims += 1; self.cached = self.afterTrim
                        },
                        clear: {
                            self.clears += 1; self.cached = 0
                        })
                }
            }
            let limit = cacheBytes
            // Below or at the limit: nothing runs, the cache is kept.
            for size in [0, limit - 1, limit] {
                let f = Fake(size, afterTrim: -1)
                #expect(f.bound(limit) == .within); #expect(f.cached == size); #expect(f.trims == 0 && f.clears == 0)
            }
            // Overshoot by one oversized buffer (Astra's reproduction: 134,217,732 bytes cached at a 64 MiB limit): the
            // allocator's trim brings it under and keeps the rest.
            let trimmed = Fake(134_217_732, afterTrim: limit - 4096)
            #expect(trimmed.bound(limit) == .trimmed); #expect(trimmed.cached <= limit); #expect(trimmed.clears == 0)
            // A trim that leaves it above the limit clears it.
            let stuck = Fake(limit + 1, afterTrim: limit + 1)
            #expect(stuck.bound(limit) == .cleared); #expect(stuck.cached == 0)
            // Repeated requests of varying size: after each one the cache is within the limit.
            let varying = Fake(0, afterTrim: limit / 2)
            for peak in [limit / 4, 3 * limit, limit + 1, limit, 10 * limit, 1] {
                varying.cached = peak
                _ = varying.bound(limit)
                #expect(varying.cached <= limit, "\(peak)")
            }
        }
    }
}
