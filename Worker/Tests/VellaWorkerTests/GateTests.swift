import Foundation
import Testing
@testable import MLXAudioSTT
import MLX
import SmallMGEMM
import VellaWire

extension WorkerTests {
    /// The fast-path gate on the CPU: key composition (golden hashes derived independently with Python's hashlib from
    /// the documented recipe), switch membership, verdict persistence, and the streaming option dependencies.
    @Suite struct Gate {
        static let host = FastPathGate.Host(gpuFamily: "apple9", gpuArchitecture: "applegpu_g17s", gpuName: "Apple M5 Max", osBuild: "25A123")
        /// Production defaults: no recipe, no component switch.
        static let clean: [String: String?] = Dictionary(
            uniqueKeysWithValues: ([
                "VELLA_RECIPE", "VELLA_NEMO_FUSED", "VELLA_FORCE_STOCK",
                "VELLA_PARAKEET_FORCE_STOCK", "VELLA_MLX_DEVICE"
            ] + FastPathGate.componentSwitches).map { ($0, nil) })

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
            #expect(try key() == "7f973547927e5eac29eeb5c584bfd4516991b3762e57bd4af8de8aef0c8201de")
            #expect(try key("") == "126dd394e80cf9e9094c7f68c2c0c5fefaa951e0bbd00cdcda5be50a1f750b36")
            #expect(try key("stub-1", ["VELLA_RECIPE": "optimized_exact"]) == "17eefd4989df3e9d8f30494982ef94323e0fc2430b3c5b1686bc185e036dff8a")
            #expect(
                try key("stub-1", ["VELLA_PARAKEET_FAST": "decoder", "VELLA_NEMO_FUSED": "0"])
                    == "74d496dc62f2d5c41fba6c1db3f02cc6423c4c1a5558dd7b547fc1efd3ae50ba")
        }

        @Test func derivedKeysHashTheRecipeAndTheSource() throws {
            let scratch = try Scratch("vella-gate")
            let source = try checkpoint(scratch, "source")
            let cases = [
                (
                    "derived-4b", "{\"schema\": 1, \"precision\": \"4b\", \"bits\": 4, \"groupSize\": 64, \"source\": \"\(source.path)\"}",
                    "parakeet-r2-dense-encoder", "3f5a6ba8ea5d22494145dd36ea39015a1c2bef33a77cb3b788dc719f2de529c6"
                ),
                (
                    "derived-bf16", "{\"schema\": 1, \"precision\": \"BF16\", \"dtype\": \"bfloat16\", \"source\": \"\(source.path)\"}",
                    "stub-1", "ff50349837ce02526c468228b8d602682f7515ff3d213eb030c43bb2e9dfe55d"
                )
            ]
            for (name, manifest, revision, expected) in cases {
                let folder = try scratch.folder(name)
                try Data(manifest.utf8).write(to: folder.appendingPathComponent(DerivedPrecision.manifestName))
                let key = try withEnvironment(Self.clean) { try FastPathGate.key(folder, revision: revision, host: Self.host) }
                #expect(key == expected, "\(name)")
            }
        }

        /// A mixed per-layer recipe (`floatModules`) is its own recipe identity; uniform recipes keep theirs.
        @Test func derivedFloatModules() throws {
            let scratch = try Scratch("vella-gate")
            let source = try checkpoint(scratch, "source")
            func resolve(_ name: String, _ extra: String) throws -> DerivedPrecision? {
                let folder = try scratch.folder(name)
                let manifest = "{\"schema\": 1, \"precision\": \"8b\", \"bits\": 8, \"groupSize\": 64, \"source\": \"\(source.path)\"\(extra)}"
                try Data(manifest.utf8).write(to: folder.appendingPathComponent(DerivedPrecision.manifestName))
                return try DerivedPrecision.resolve(folder)
            }
            let uniform = try #require(try resolve("uniform", ""))
            #expect(uniform.canonical == "derived:8b:dtype=-:bits=8:group=64")
            #expect(uniform.floatModules.isEmpty && !uniform.keepsFloat("model.encoder.layers.0.fc1"))
            let mixed = try #require(try resolve("mixed", ", \"floatModules\": [\"model.encoder\"]"))
            #expect(mixed.canonical == "derived:8b:dtype=-:bits=8:group=64:float=model.encoder")
            #expect(mixed.keepsFloat("model.encoder") && mixed.keepsFloat("model.encoder.layers.0.fc1"))
            #expect(!mixed.keepsFloat("model.encoder_x.fc1") && !mixed.keepsFloat("model.decoder.layers.0.fc1"))
            for (index, bad) in [", \"floatModules\": []", ", \"floatModules\": \"model.encoder\"", ", \"floatModules\": [\"a/b\"]"].enumerated() {
                #expect(throws: (any Error).self) { try resolve("bad\(index)", bad) }
            }
        }

        @Test func keyNeedsWeights() throws {
            let scratch = try Scratch("vella-gate")
            let folder = try scratch.folder("empty")
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
            #expect(throws: (any Error).self) { try FastPathGate.key(folder, revision: "stub-1", host: Self.host) }
        }

        @Test func gpuIdentityScopesPersistedVerdicts() throws {
            let scratch = try Scratch("vella-gate-hardware")
            let model = try checkpoint(scratch)
            try withEnvironment(Self.clean) {
                func url(_ host: FastPathGate.Host) throws -> URL {
                    scratch.url.appendingPathComponent(try FastPathGate.key(model, revision: "stub-1", host: host) + ".json")
                }
                let qualified = try url(Self.host)
                FastPathGate.persist("fast", to: qualified)
                #expect(FastPathGate.status(try url(Self.host)) == "fast")
                var migrated = Self.host
                migrated.gpuArchitecture = "applegpu_g16s"
                #expect(FastPathGate.status(try url(migrated)) == nil)
                migrated = Self.host
                migrated.gpuName = "Apple M5 Pro"
                #expect(FastPathGate.status(try url(migrated)) == nil)
                // Historical keys/files survive for diagnose, but never qualify the new host key.
                let old = scratch.url.appendingPathComponent("fe9f3f82e7f5f2708a3fa0869935f9e0fd9c2accb51fe2e1d31024bcb493a4e7.json")
                let legacy = """
                    {"status":"fast","workerVersion":"native-kernels-10","gpuFamily":"apple9","osBuild":"25A123",
                     "disabled.nax_gemm":"self-test: word edits 3 > 1"}
                    """
                try Data(legacy.utf8).write(to: old)
                let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: old)) as? [String: Any])
                let record = try #require(GateRecord(json: object))
                #expect(record.gpuArchitecture == nil && record.gpuName == nil)
                #expect(record.disabled == ["nax_gemm": "self-test: word edits 3 > 1"])
                try FileManager.default.removeItem(at: qualified)
                #expect(FastPathGate.status(try url(Self.host)) == nil)
                #expect(FastPathGate.disabledComponents(try url(Self.host)).isEmpty)
                #expect(FastPathGate.status(old) == "fast")
                #expect(FastPathGate.disabledComponents(old) == record.disabled)
            }
        }

        @Test func tensorAvailabilityMirrorsMLXAndParakeetFallsBack() {
            func os(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
                OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
            }
            for version in [os(25, 6), os(26, 0), os(26, 1)] {
                #expect(!SmallMGEMM.tensorOpsAvailable(architecture: "applegpu_g17s", osVersion: version))
                let nax = FastParakeetNAX.available(architecture: "applegpu_g17s", osVersion: version)
                let int8 = FastParakeetInt8.available(architecture: "applegpu_g17s", osVersion: version)
                #expect(!nax && !int8)
                // A null sentinel must not be inspected when unavailable. No arrays, streams, evaluation or GPU work.
                let x = MLXArray.mlxNone
                #expect(FastParakeetNAX.matmul(x, x, tensorOpsAvailable: nax) == nil)
                #expect(
                    FastParakeetInt8.matmul(
                        x, weight: x, scales: x, biases: x, bits: 8,
                        groupSize: 64, bias: nil, tensorOpsAvailable: int8) == nil)
            }
            for version in [os(26, 2), os(26, 6), os(27, 0)] {
                #expect(SmallMGEMM.tensorOpsAvailable(architecture: "applegpu_g17s", osVersion: version))
                #expect(!SmallMGEMM.tensorOpsAvailable(architecture: "applegpu_g16s", osVersion: version))
                #expect(!SmallMGEMM.tensorOpsAvailable(architecture: "applegpu_g17p", osVersion: version))
                #expect(SmallMGEMM.tensorOpsAvailable(architecture: "applegpu_g18p", osVersion: version))
                #expect(!SmallMGEMM.tensorOpsAvailable(architecture: "unknown", osVersion: version))
            }
        }

        @Test func currentHostIsTheDefault() throws {
            let scratch = try Scratch("vella-gate")
            let model = try checkpoint(scratch)
            #expect(try FastPathGate.key(model, revision: "stub-1") == FastPathGate.key(model, revision: "stub-1", host: .current))
        }

        @Test func componentConfigurationAndReportedSwitches() {
            let environment = [
                "VELLA_PARAKEET_FAST": "decoder", "VELLA_NEMO_FUSED": "0", "VELLA_PARAKEET_NAX": "", "VELLA_RECIPE": "optimized_exact",
                "VELLA_FORCE_STOCK": "1", "VELLA_QWEN_PROFILE": "1", "HOME": "/x"
            ]
            #expect(FastPathGate.componentConfiguration(environment) == "VELLA_NEMO_FUSED=0,VELLA_PARAKEET_FAST=decoder")
            #expect(FastPathGate.componentConfiguration(["HOME": "/x"]) == "")
            #expect(
                FastPathGate.reportedEnvironment(environment)
                    == ["VELLA_PARAKEET_FAST": "decoder", "VELLA_NEMO_FUSED": "0", "VELLA_FORCE_STOCK": "1", "VELLA_QWEN_PROFILE": "1"])
            #expect(FastPathGate.selectionSwitches == ["VELLA_RECIPE"])
            #expect(Set(FastPathGate.componentSwitches).isSubset(of: Set(FastPathGate.reportedSwitches)))
        }

        @Test func recipeParsing() {
            func under(_ environment: [String: String?]) -> (Recipe, Bool, String) {
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
            FastPathGate.persist(
                "fast", to: url, model: URL(fileURLWithPath: "/models/parakeet-ultra-bf16"),
                reason: FastPathGate.partialReason(["nax_gemm": "word edits 3 > 1"]), disabled: ["nax_gemm": "word edits 3 > 1"])
            #expect(FastPathGate.status(url) == "fast")
            #expect(FastPathGate.disabledComponents(url) == ["nax_gemm": "word edits 3 > 1"])
            #expect(FastPathGate.inconclusiveCount(url) == 0)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
            #expect(Set(object.keys) == ["status", "workerVersion", "gpuFamily", "gpuArchitecture", "gpuName", "osBuild", "date", "model", "reason", "disabled.nax_gemm"])
            #expect(object["gpuArchitecture"] == FastPathGate.Host.current.gpuArchitecture)
            #expect(object["gpuName"] == FastPathGate.Host.current.gpuName)
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
            #expect(
                all.effective() == [
                    "f32_weights": true, "coalesce": true, "batched_decode": true, "position_cache": true, "kv_cache": true,
                    "fused_layer": true, "mel_batch": true, "bf16_linears": true
                ])
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

        /// The joint batch's small-M Linear refuses what its kernel cannot take (shape/dtype admission, CPU-checkable:
        /// the test build has no Metal library; the lossy-copy refusal and a quantized joint need MLX arrays).
        @Test func jointBatchLinearRefusals() {
            typealias L = VellaNemotronSmallLinear
            #expect(L.fits(weightShape: [13088, 640], dtype: .bfloat16, r: 4, s: 1))
            #expect(L.fits(weightShape: [13088, 640], dtype: .float32, r: 4, s: 1))
            #expect(!L.fits(weightShape: [13088, 640], dtype: .float16, r: 4, s: 1)) // dtype
            #expect(!L.fits(weightShape: [13088, 640], dtype: .uint32, r: 4, s: 1)) // packed quantized weight
            #expect(!L.fits(weightShape: [13088, 640, 1], dtype: .bfloat16, r: 4, s: 1)) // not a matrix
            #expect(!L.fits(weightShape: [13086, 640], dtype: .bfloat16, r: 4, s: 1)) // N % R
            #expect(!L.fits(weightShape: [13088, 644], dtype: .bfloat16, r: 4, s: 1)) // K % (S · 8)
            #expect(!L.fits(weightShape: [13088, 640], dtype: .bfloat16, r: 8, s: 1)) // M · R > S · 32
            // Inputs other than (1, M ≤ 8, K) Float32 are declined, so the caller keeps its stock path.
            #expect(L.accepts(inputShape: [1, 8, 640], dtype: .float32, k: 640))
            #expect(L.accepts(inputShape: [1, 1, 640], dtype: .float32, k: 640))
            #expect(!L.accepts(inputShape: [1, 9, 640], dtype: .float32, k: 640))
            #expect(!L.accepts(inputShape: [1, 0, 640], dtype: .float32, k: 640))
            #expect(!L.accepts(inputShape: [1, 2, 640], dtype: .bfloat16, k: 640))
            #expect(!L.accepts(inputShape: [2, 2, 640], dtype: .float32, k: 640))
            #expect(!L.accepts(inputShape: [1, 2, 641], dtype: .float32, k: 640))
            #expect(!L.accepts(inputShape: [2, 640], dtype: .float32, k: 640))
        }

        /// The opt-in levers: absent by default; the inexact joint batch never runs (or keys, or reports) under
        /// Optimized · Exact or forced stock, and reports only when its BF16 copy was built.
        @Test func nemotronLabLevers() {
            typealias S = VellaNemotronOptions.Switches
            let both = ["VELLA_NEMO_KEEPCACHE": "1", "VELLA_NEMO_JOINTBATCH": "1"]
            let unset = S(environment: [:], forcedStock: false)
            #expect(unset.labLevers.isEmpty); #expect(!unset.jointBatch); #expect(!unset.keepCache)
            #expect(unset.effective()["joint_batch"] == nil); #expect(unset.effective()["keep_cache"] == nil)
            #expect(S(environment: ["VELLA_NEMO_JOINTBATCH": "true"], forcedStock: false).labLevers.isEmpty)
            let fast = S(environment: both, forcedStock: false)
            #expect(fast.labLevers == ["keepcache-1", "jointbatch-1"])
            #expect(fast.effective()["joint_batch"] == true); #expect(fast.effective()["keep_cache"] == true)
            #expect(fast.effective(jointPrepared: false)["joint_batch"] == false)
            #expect(
                S(environment: both.merging(["VELLA_NEMO_BATCHED_DECODE": "0"]) { $1 }, forcedStock: false)
                    .effective()["joint_batch"] == false)
            let exact = S(environment: both, forcedStock: false, exactOnly: true)
            #expect(exact.labLevers == ["keepcache-1"]); #expect(!exact.jointBatch); #expect(!exact.jointBatchActive())
            #expect(exact.effective()["joint_batch"] == nil)
            let stock = S(environment: both, forcedStock: true)
            #expect(stock.labLevers.isEmpty); #expect(!stock.anyEnabled)
            // A lever alone runs nothing.
            let leversOnly = S(
                f32Weights: false, coalesce: false, batchedDecode: false, positionCache: false, keyValueCache: false,
                fusedLayer: false, keepCache: true, jointBatch: true)
            #expect(!leversOnly.anyEnabled)
            // Reason: bit-identical only when no inexact component runs.
            let bitIdentical = "Self-tested on this Mac against stock MLX (identical streamed text); output is bit-identical by construction."
            let noFused = S(environment: both.merging(["VELLA_NEMO_FUSED": "0"]) { $1 }, forcedStock: false)
            let jointOnly = VellaNemotronOptions.report(optimized: true, fusedPrepared: true, jointPrepared: true, stockReason: "", switches: noFused)
            #expect(jointOnly.1 == "Self-tested on this Mac against stock MLX (same streamed text; the joint batch is within a small numeric tolerance).")
            #expect(jointOnly.2["joint_batch"] == true)
            #expect(VellaNemotronOptions.report(optimized: true, fusedPrepared: true, jointPrepared: false, stockReason: "", switches: noFused).1 == bitIdentical)
            let exactNoFused = S(environment: both.merging(["VELLA_NEMO_FUSED": "0"]) { $1 }, forcedStock: false, exactOnly: true)
            #expect(VellaNemotronOptions.report(optimized: true, fusedPrepared: true, jointPrepared: true, stockReason: "", switches: exactNoFused).1 == bitIdentical)
            #expect(
                VellaNemotronOptions.report(optimized: true, fusedPrepared: true, jointPrepared: true, stockReason: "", switches: fast).1
                    == "Self-tested on this Mac against stock MLX (same streamed text; the fused layer and the joint batch are within a small numeric tolerance).")
            // Unchanged default wording and components.
            #expect(
                VellaNemotronOptions.report(optimized: true, fusedPrepared: true, stockReason: "", switches: unset).1
                    == "Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).")
            #expect(VellaNemotronOptions.report(optimized: true, fusedPrepared: true, stockReason: "", switches: unset).2 == unset.effective())
        }
    }
}

extension WorkerTests {
    /// The fast-path revisions under the default environment: the values every production gate key uses.
    @Suite struct Revisions {
        @Test func parakeet() {
            #expect(ParakeetModel.fastPathRevision == "parakeet-r2-dense-encoder+nax2+smallm-tile-1")
            #expect(ParakeetModel.inputDType == .bfloat16)
            // Tail blocks cover the expected steps; checkpoint-resolved defaults are covered in Defaults.
            #expect([0, 16, 17, 32, 33, 64, 65, 400].map { FastParakeetDecodeOptions.blockSteps(remainingFrames: $0) } == [8, 8, 16, 16, 32, 32, 32, 32])
        }
        /// The registry maps each dictation architecture to its runtime, whose gate revision is the model's own.
        @Test func registry() {
            #expect(ModelRuntimeRegistry.dictation.map { $0.architecture } == [.parakeet, .qwen3ASR, .whisper])
            #expect(ModelRuntimeRegistry.streaming.map { $0.architecture } == [.nemotronASR])
            #expect(ModelRuntimeRegistry.dictation(.parakeet)?.gateRevision == ParakeetModel.fastPathRevision)
            #expect(ModelRuntimeRegistry.dictation(.qwen3ASR)?.gateRevision == "qwen3-asr-3-f32-encoder-p3")
            #expect(ModelRuntimeRegistry.dictation(.whisper)?.gateRevision == WhisperModel.fastPathRevision)
            #expect(ModelRuntimeRegistry.streaming(.nemotronASR)?.gateRevision == "nemotron-stream-5")
            #expect(ModelRuntimeRegistry.dictation.allSatisfy { $0.requiredGPUFamily == "apple9" })
            #expect(NemotronRuntime.requiredGPUFamily == nil)
            #expect(ModelRuntimeRegistry.dictation(.stub) == nil && ModelRuntimeRegistry.dictation(.nemotronASR) == nil)
        }
        @Test func qwen() { #expect(Qwen3ASRModel.fastPathRevision == "qwen3-asr-3-f32-encoder-p3") }
        /// Whisper has one revision for every recipe (all its components are exact against the checkpoint-dtype stock).
        @Test func whisper() { #expect(WhisperModel.fastPathRevision == "whisper-4") }
    }
}

extension WorkerTests {
    /// Only Parakeet TDT loads: hybrid TDT-CTC, CTC and RNN-T without TDT durations are refused (the worker reports
    /// the load as failed).
    @Suite struct ParakeetTargets {
        @Test func onlyTDT() throws {
            let rnnt = "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"
            try ParakeetVariantResolver.requireTDT(target: rnnt, hasTDTDurations: true)
            for (target, tdt) in [
                (rnnt, false), ("nemo.collections.asr.models.hybrid_rnnt_ctc_bpe_models.EncDecHybridRNNTCTCBPEModel", true),
                ("nemo.collections.asr.models.ctc_bpe_models.EncDecCTCModelBPE", false), ("", true)
            ] {
                #expect(throws: (any Error).self) { try ParakeetVariantResolver.requireTDT(target: target, hasTDTDurations: tdt) }
            }
        }
    }
}

extension WorkerTests {
    /// SmallMGEMM's revisions (part of Parakeet's gate key) and self-test bounds. Which classes run is checked on the
    /// GPU (Phase-3 D-8 check), since the test build has no Metal library.
    @Suite struct SmallM {
        @Test func revisionsAndBounds() {
            #expect(SmallMGEMM.tileRevision == "tile-1")
            #expect(SmallMGEMM.gemvRevision == "gemv-1")
            #expect(SmallMGEMM.qtileRevision == "qtile-1")
            #expect(SmallMGEMM.revision == "tile-1 gemv-1")
            #expect(SmallMGEMM.selfTestBound("qtile.bf16.affine8.none") == 3e-2)
            #expect(SmallMGEMM.selfTestFailures([:]).isEmpty)
            #expect(SmallMGEMM.selfTestFailures(["tile.bf16.dense.none": 0.03, "gemv.bf16.affine4.none": 0.029]) == ["tile.bf16.dense.none"])
            #expect(SmallMGEMM.selfTestFailures(["tile.bf16.dense.none": .infinity]) == ["tile.bf16.dense.none"])
        }

        /// The plain `selfTest()` (what a sibling vendoring the package runs) selects the tile and GEMV classes only.
        @Test func defaultSelectionExcludesNativeClasses() {
            for name in ["tile.bf16.dense.none", "tile.f16.dense.biasResidual", "gemv.bf16.affine8.siluGate", "gemv.f16.mxfp4.none"] {
                #expect(SmallMGEMM.standardClasses(name), "\(name)")
            }
            for name in ["qtile.bf16.affine8.none", "qtile.f16.affine4.bias"] { #expect(!SmallMGEMM.standardClasses(name), "\(name)") }
        }

        /// Parakeet's integer components qualify exactly the classes they dispatch: their own bit width's native tile
        /// (none/bias) and the BF16 dense tile; a failure of the other bit width cannot disable the active one.
        @Test func parakeetIntegerQualification() {
            #expect(FastParakeetInt8.libraryClasses(component: "int8_gemm") == ["qtile.bf16.affine8.none", "qtile.bf16.affine8.bias", "tile.bf16.dense.none"])
            #expect(FastParakeetInt8.libraryClasses(component: "int4_gemm") == ["qtile.bf16.affine4.none", "qtile.bf16.affine4.bias", "tile.bf16.dense.none"])
            let int4Broken: [String: Float] = [
                "qtile.bf16.affine8.none": 0.005, "qtile.bf16.affine8.bias": 0.005, "tile.bf16.dense.none": 1e-4,
                "qtile.bf16.affine4.none": .infinity, "qtile.bf16.affine4.bias": 0.5, "gemv.bf16.affine8.none": .infinity
            ]
            #expect(FastParakeetInt8.libraryFailures(component: "int8_gemm", results: int4Broken).isEmpty)
            #expect(FastParakeetInt8.libraryFailures(component: "int4_gemm", results: int4Broken) == ["qtile.bf16.affine4.bias", "qtile.bf16.affine4.none"])
            #expect(FastParakeetInt8.libraryFailures(component: "int8_gemm", results: ["tile.bf16.dense.none": 0.03]) == ["tile.bf16.dense.none"])
            // Every qualified class is a native tile class or the dense tile: nothing from the GEMV family.
            for component in ["int8_gemm", "int4_gemm"] {
                #expect(FastParakeetInt8.libraryClasses(component: component).allSatisfy { !$0.hasPrefix("gemv.") })
            }
            #expect(SmallMGEMM.qtileRows == 9...256)
        }
    }
}
