import Foundation
import Testing
@testable import MLXAudioSTT

extension WorkerTests {
    /// The fast-path gate on the CPU: key composition (golden hashes derived independently with Python's hashlib from
    /// the documented recipe), switch membership, verdict persistence, and the streaming option dependencies.
    @Suite struct Gate {
        static let host = FastPathGate.Host(gpuFamily: "apple9", osBuild: "25A123")
        /// Production defaults: no recipe, no component switch.
        static let clean: [String: String?] = Dictionary(uniqueKeysWithValues: (["VELLA_RECIPE", "VELLA_NEMO_FUSED", "VELLA_FORCE_STOCK",
            "VELLA_PARAKEET_FORCE_STOCK", "VELLA_MLX_DEVICE"] + FastPathGate.componentSwitches).map { ($0, nil) })

        /// Two weight files and a config; `notes.txt` is not part of the key.
        func checkpoint(_ scratch: Scratch, _ name: String = "model") throws -> URL {
            let folder = try scratch.folder(name)
            try Data("alpha weights\n".utf8).write(to: folder.appendingPathComponent("a.safetensors"))
            try Data("beta weights\n".utf8).write(to: folder.appendingPathComponent("b.safetensors"))
            try Data("{\"model_type\": \"stub\"}\n".utf8).write(to: folder.appendingPathComponent("config.json"))
            try Data("ignored".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            return folder
        }

        @Test func versionIsPinned() { #expect(FastPathGate.version == "native-kernels-10") }

        @Test func keyGoldenHashes() throws {
            let scratch = try Scratch("vella-gate")
            let model = try checkpoint(scratch)
            func key(_ revision: String = "stub-1", _ environment: [String: String?] = [:]) throws -> String {
                try withEnvironment(Self.clean) { try withEnvironment(environment) { try FastPathGate.key(model, revision: revision, host: Self.host) } }
            }
            #expect(try key() == "fe9f3f82e7f5f2708a3fa0869935f9e0fd9c2accb51fe2e1d31024bcb493a4e7")
            #expect(try key("") == "84e4b1b7e7c1ad90ad1acaee3a03fb4f958a2fd263b639c7e88d24664ec83e2d")
            #expect(try key("stub-1", ["VELLA_RECIPE": "optimized_exact"]) == "0ef51effbaa74631c7ba7bd2dab36fff6d6c90d277112d51b7a66cc350cb7c0e")
            #expect(try key("stub-1", ["VELLA_PARAKEET_FAST": "decoder", "VELLA_NEMO_FUSED": "0"])
                    == "0244ffad6697ac8cef3431d1d02035b5823b950d5209dcd24ed660a75b9f5cfd")
        }

        @Test func derivedKeysHashTheRecipeAndTheSource() throws {
            let scratch = try Scratch("vella-gate")
            let source = try checkpoint(scratch, "source")
            let cases = [
                ("derived-4b", "{\"schema\": 1, \"precision\": \"4b\", \"bits\": 4, \"groupSize\": 64, \"source\": \"\(source.path)\"}",
                 "parakeet-r2-dense-encoder", "b1a7d02aa888050618fa04c585ee3432b9660e760d10755833350d68c15591de"),
                ("derived-bf16", "{\"schema\": 1, \"precision\": \"BF16\", \"dtype\": \"bfloat16\", \"source\": \"\(source.path)\"}",
                 "stub-1", "561a2df7cf0f53bfa866a4d1fdd2e17b10ecbb5eea4a80b276aa689d6817d6fb"),
            ]
            for (name, manifest, revision, expected) in cases {
                let folder = try scratch.folder(name)
                try Data(manifest.utf8).write(to: folder.appendingPathComponent(DerivedPrecision.manifestName))
                let key = try withEnvironment(Self.clean) { try FastPathGate.key(folder, revision: revision, host: Self.host) }
                #expect(key == expected, "\(name)")
            }
        }

        @Test func keyNeedsWeights() throws {
            let scratch = try Scratch("vella-gate")
            let folder = try scratch.folder("empty")
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
            #expect(throws: (any Error).self) { try FastPathGate.key(folder, revision: "stub-1", host: Self.host) }
        }

        @Test func currentHostIsTheDefault() throws {
            let scratch = try Scratch("vella-gate")
            let model = try checkpoint(scratch)
            #expect(try FastPathGate.key(model, revision: "stub-1") == FastPathGate.key(model, revision: "stub-1", host: .current))
        }

        @Test func componentConfigurationAndReportedSwitches() {
            let environment = ["VELLA_PARAKEET_FAST": "decoder", "VELLA_NEMO_FUSED": "0", "VELLA_WHISPER_FUSED": "", "VELLA_RECIPE": "optimized_exact",
                               "VELLA_FORCE_STOCK": "1", "VELLA_QWEN_PROFILE": "1", "HOME": "/x"]
            #expect(FastPathGate.componentConfiguration(environment) == "VELLA_NEMO_FUSED=0,VELLA_PARAKEET_FAST=decoder")
            #expect(FastPathGate.componentConfiguration(["HOME": "/x"]) == "")
            #expect(FastPathGate.reportedEnvironment(environment)
                    == ["VELLA_PARAKEET_FAST": "decoder", "VELLA_NEMO_FUSED": "0", "VELLA_FORCE_STOCK": "1", "VELLA_QWEN_PROFILE": "1"])
            #expect(FastPathGate.selectionSwitches == ["VELLA_RECIPE"])
            #expect(Set(FastPathGate.componentSwitches).isSubset(of: Set(FastPathGate.reportedSwitches)))
        }

        @Test func recipeParsing() {
            func under(_ environment: [String: String?]) -> (FastPathGate.Recipe, Bool, String) {
                withEnvironment(Self.clean) { withEnvironment(environment) { (FastPathGate.recipe, FastPathGate.forcedStock, FastPathGate.forcedStockReason) } }
            }
            #expect(under([:]).0 == .optimized_fast); #expect(!under([:]).1)
            #expect(under(["VELLA_RECIPE": "optimized_exact"]).0 == .optimized_exact)
            #expect(under(["VELLA_RECIPE": "bogus"]).0 == .optimized_fast)
            #expect(under(["VELLA_RECIPE": "standard"]).1)
            #expect(under(["VELLA_RECIPE": "standard"]).2 == "Standard selected: stock MLX.")
            #expect(under(["VELLA_PARAKEET_FORCE_STOCK": "1"]).1)
            #expect(!under(["VELLA_FORCE_STOCK": "0"]).1)
        }

        @Test func verdictPersistence() throws {
            let scratch = try Scratch("vella-gate")
            let url = scratch.url.appendingPathComponent("FastPath/key.json")
            FastPathGate.persist("fast", to: url, model: URL(fileURLWithPath: "/models/parakeet-ultra-bf16"),
                                 reason: FastPathGate.partialReason(["nax_gemm": "word edits 3 > 1"]), disabled: ["nax_gemm": "word edits 3 > 1"])
            #expect(FastPathGate.status(url) == "fast")
            #expect(FastPathGate.disabledComponents(url) == ["nax_gemm": "word edits 3 > 1"])
            #expect(FastPathGate.inconclusiveCount(url) == 0)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
            #expect(Set(object.keys) == ["status", "workerVersion", "gpuFamily", "osBuild", "date", "model", "reason", "disabled.nax_gemm"])
            #expect(object["model"] == "parakeet-ultra-bf16")
            #expect(object["workerVersion"] == "native-kernels-10")
            #expect(object["reason"] == "optimized without nax_gemm (word edits 3 > 1)")

            FastPathGate.persist("inconclusive", to: url, count: 1)
            #expect(FastPathGate.inconclusiveCount(url) == 1)
            #expect(FastPathGate.disabledComponents(url) == [:])
            #expect(FastPathGate.inconclusiveLimit == 2)
            FastPathGate.persist("stock", to: url, reason: "self-test: optimized output differs from stock MLX")
            #expect(FastPathGate.status(url) == "stock")
            #expect(FastPathGate.inconclusiveCount(url) == 0)
            #expect(FastPathGate.status(scratch.url.appendingPathComponent("missing.json")) == nil)
        }

        @Test func exitStatuses() {
            #expect(FastPathGate.inconclusive == 3)
            #expect(FastPathGate.verdictFailed == 2)
            #expect(FastPathGate.componentsFailed == 4)
            #expect(FastPathGate.resultVariable == "VELLA_SELFTEST_RESULT")
            #expect(FastPathGate.maxTolerantWordEdits == 1)
        }

        @Test func wordEdits() {
            #expect(FastPathGate.wordEdits([], []) == 0)
            #expect(FastPathGate.wordEdits([], ["a", "b"]) == 2)
            #expect(FastPathGate.wordEdits(["a", "b", "c"], ["a", "x", "c"]) == 1)
            #expect(FastPathGate.wordEdits(["a", "b", "c"], ["a", "c"]) == 1)
            #expect(FastPathGate.wordEdits(["kitten"], ["sitting", "kitten"]) == 1)
        }

        @Test func nemotronSwitchDependencies() {
            typealias S = VellaNemotronOptions.Switches
            let all = S(environment: [:], forcedStock: false)
            #expect(all.effective() == ["f32_weights": true, "coalesce": true, "batched_decode": true, "position_cache": true, "kv_cache": true,
                                        "fused_layer": true, "mel_batch": true, "bf16_linears": true])
            #expect(!S(environment: [:], forcedStock: true).anyEnabled)
            let exact = S(environment: [:], forcedStock: false, exactOnly: true).effective()
            #expect(exact["fused_layer"] == false); #expect(exact["bf16_linears"] == false); #expect(exact["kv_cache"] == true)
            // The fused layer needs the K/V cache; its BF16 Linears need the fused layer; the mel batch needs coalescing.
            let noCache = S(environment: ["VELLA_NEMO_KVCACHE": "0"], forcedStock: false).effective()
            #expect(noCache["fused_layer"] == false); #expect(noCache["bf16_linears"] == false)
            #expect(S(environment: ["VELLA_NEMO_COALESCE": "0"], forcedStock: false).effective()["mel_batch"] == false)
            #expect(all.effective(fusedPrepared: false)["fused_layer"] == false)
            #expect(all.effective(fusedPrepared: false)["bf16_linears"] == false)
            // The fused layer alone (K/V cache off) runs nothing.
            let fusedOnly = S(f32Weights: false, coalesce: false, batchedDecode: false, positionCache: false, keyValueCache: false, fusedLayer: true)
            #expect(!fusedOnly.anyEnabled)
            #expect(VellaNemotronOptions.revision == "nemotron-stream-5")
            let stock = VellaNemotronOptions.report(optimized: false, fusedPrepared: true, stockReason: "why", switches: all)
            #expect(stock.0 == "mlx"); #expect(stock.1 == "why"); #expect(stock.2.values.allSatisfy { !$0 })
            #expect(VellaNemotronOptions.report(optimized: true, fusedPrepared: true, stockReason: "", switches: all).0 == "optimized")
        }
    }
}

extension WorkerTests {
    /// The fast-path revisions under the default environment: the values every production gate key uses.
    @Suite struct Revisions {
        @Test func qwen() { #expect(Qwen3ASRModel.fastPathRevision == "qwen3-asr-3-f32-encoder-p3") }
    }
}
