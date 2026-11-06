import Foundation
import Testing
import MLX
import MLXNN
@testable import MLXAudioSTT
@testable import VellaWorker
import VellaWire

extension WorkerTests {
    /// int8 and int4 of Nemotron 3.5 Transcribe are made at load from NVIDIA's BF16 checkpoint (Vella's derived-at-load
    /// precisions). The fixture test builds a tiny model in NVIDIA's NeMo layout and runs the real derivation; like the
    /// other MLX tests it runs on the CPU device, opt-in (`VELLA_TEST_MLX_CPU=1`, the helpers' unit lane loads no
    /// Metal library). The golden test derives from the real BF16 and compares with the reference exports.
    @Suite struct NemotronTranscribeDerivation {
        static let mlx = ProcessInfo.processInfo.environment["VELLA_TEST_MLX_CPU"] == "1"

        @Test func recipeRule() {
            typealias R = NemotronTranscribeRecipe
            let expert = "llm.backbone.layers.1.mixer.switch_mlp.fc1"
            #expect(R.decoderBits(expert, precisionBits: 4) == 4 && R.decoderBits(expert, precisionBits: 8) == 8)
            for path in [
                "llm.backbone.layers.0.mixer.in_proj", "llm.backbone.layers.0.mixer.out_proj", "llm.backbone.layers.2.mixer.q_proj",
                "llm.backbone.layers.2.mixer.o_proj", "llm.backbone.layers.1.mixer.shared_experts.up_proj"
            ] {
                #expect(R.decoderBits(path, precisionBits: 4) == 8 && R.decoderBits(path, precisionBits: 8) == 8, "\(path)")
            }
            for path in ["llm.lm_head", "llm.backbone.embeddings", "perception.proj", "perception.encoder.asr_encoder.layers.0.attn.w_qkv"] {
                #expect(R.decoderBits(path, precisionBits: 4) == nil, "\(path)")
            }
            #expect(R.mtpBits("moe.switch_mlp.fc2") == 4 && R.mtpBits("eh_proj") == 8 && R.mtpBits("attn.q_proj") == 8)
        }

        // MARK: Fixture

        static let config: [String: Any] = [
            "model_type": "nemo_speechlm", "architectures": ["Nemotron3_5TranscribeForConditionalGeneration"],
            "prompt_format": "nemotron3p5", "eos_token_id": [11], "pad_token_id": 0,
            "llm_config": [
                "model_type": "nemotron_h", "vocab_size": 128, "hidden_size": 64, "num_attention_heads": 2, "num_key_value_heads": 1,
                "head_dim": 32, "mamba_num_heads": 2, "mamba_head_dim": 32, "ssm_state_size": 32, "conv_kernel": 4, "n_groups": 1,
                "layer_norm_epsilon": 1e-5, "moe_intermediate_size": 64, "moe_shared_expert_intermediate_size": 64,
                "n_routed_experts": 4, "num_experts_per_tok": 2, "norm_topk_prob": true, "routed_scaling_factor": 2.5,
                "time_step_limit": [0.0, ["__float__": "Infinity"]], "layers_block_type": ["mamba", "moe", "attention", "moe"]
            ],
            "pe_encoder_config": [
                "asr_encoder_type": "transformer", "speaker_feature_config_version": 1, "speaker_feature_mode": "thresholded",
                "speaker_activity_threshold": 0.5,
                "asr_encoder_cfg": ["feat_in": 16, "d_model": 64, "n_heads": 2, "n_layers": 1, "subsampling_factor": 8, "qk_norm": true, "rotary_fraction": 0.5],
                "diarization_model_cfg": [
                    "encoder": ["feat_in": 16, "d_model": 32, "n_heads": 2, "n_layers": 1, "subsampling_factor": 8],
                    "sortformer_modules": ["num_spks": 4, "fc_d_model": 32, "tf_d_model": 16]
                ]
            ],
            "perception": ["output_dim": 64, "preprocessor": ["features": 16, "n_fft": 512, "window_size": 0.025, "window_stride": 0.01, "sample_rate": 16000]]
        ]

        /// The module tree's key → NVIDIA's NeMo key and whether NeMo stores it transposed (0, 2, 1).
        static func nemo(_ key: String) -> (String, Bool) {
            var k = key
            for (from, to) in [
                ("llm.backbone.embeddings.", "llm.model.embed_tokens."), ("llm.backbone.norm_f.", "llm.model.norm."),
                ("llm.backbone.layers.", "llm.model.layers."), (".ffn.linear1.", ".ffn.net.0."), (".ffn.linear2.", ".ffn.net.3."),
                (".preprocessor.fb", ".preprocessor.featurizer.fb"), (".preprocessor.window", ".preprocessor.featurizer.window")
            ] {
                k = k.replacingOccurrences(of: from, with: to)
            }
            for name in ["A_log", "D", "dt_bias"] where k.hasSuffix(".mixer.\(name)") {
                k = String(k.dropLast(name.count)) + "_fp32_params.\(name)"
            }
            if k.hasSuffix(".switch_mlp.fc1.weight") { return (k.replacingOccurrences(of: ".switch_mlp.fc1.weight", with: ".experts.gate_and_up_projs"), true) }
            if k.hasSuffix(".switch_mlp.fc2.weight") { return (k.replacingOccurrences(of: ".switch_mlp.fc2.weight", with: ".experts.down_projs"), true) }
            return (k, k.hasSuffix(".conv1d.weight") || k.hasSuffix(".subpixel_upsample.weight"))
        }

        /// A tiny BF16 checkpoint in NVIDIA's layout (Mamba, MoE with 4 experts, attention, the MTP block, both encoders),
        /// with its licence files, plus noise the loader must drop (CTC head, `_extra_state`).
        static func fixture(_ scratch: Scratch) throws -> URL {
            let dir = try scratch.folder("bf16")
            try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))
            let skeleton = try NemotronTranscribeModel.skeleton(dir)
            var tensors: [String: MLXArray] = [:]
            var seed: UInt64 = 1
            func random(_ shape: [Int], fp32: Bool) -> MLXArray {
                seed += 1
                let value = MLXRandom.normal(shape, key: MLXRandom.key(seed)) * 0.05
                return fp32 ? value : value.asType(.bfloat16)
            }
            func add(_ key: String, _ shape: [Int]) {
                let (name, transposed) = nemo(key)
                let fp32 = key.hasSuffix(".A_log") || key.hasSuffix(".D") || key.hasSuffix(".dt_bias") || key.hasSuffix("e_score_correction_bias")
                tensors[name] = random(transposed ? [shape[0], shape[2], shape[1]] : shape, fp32: fp32)
            }
            for (key, value) in skeleton.parameters().flattened() { add(key, value.shape) }
            let reverse = Dictionary(uniqueKeysWithValues: NTMTP.nvidiaKeys.map { ($1, $0) })
            for (key, value) in NTMTP(skeleton.decoderConfig).parameters().flattened() {
                let source = try #require(reverse[key], "MTP \(key)")
                tensors[source] = random(
                    source.hasSuffix("_projs") ? [value.dim(0), value.dim(2), value.dim(1)] : value.shape,
                    fp32: source.hasSuffix("e_score_correction_bias"))
            }
            tensors["ctc_timestamp.decoder.upsample.bias"] = MLXArray.zeros([4], dtype: .float32)
            tensors["llm.lm_head._extra_state"] = MLXArray.zeros([0], dtype: .bfloat16)
            try MLX.save(arrays: tensors, url: dir.appendingPathComponent("model.safetensors"))
            try "Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. OpenMDW License Agreement, version 1.1".write(
                to: dir.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
            try "# Third-Party Notices".write(to: dir.appendingPathComponent("THIRD_PARTY_NOTICES.md"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("licenses"), withIntermediateDirectories: true)
            try "Apache-2.0".write(to: dir.appendingPathComponent("licenses/vLLM-LICENSE.txt"), atomically: true, encoding: .utf8)
            return dir
        }

        /// Vella's derived-model directory: only `vella-derived.json`, as VellaCore's prepareDerivedModel writes it.
        static func manifest(_ scratch: Scratch, source: URL, bits: Int) throws -> URL {
            let dir = try scratch.folder("derived-\(bits)b")
            let object: [String: Any] = [
                "schema": 1, "precision": "\(bits)b", "source": source.path, "bits": bits, "groupSize": 64,
                "family": "nemotron-3.5-transcribe"
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent(DerivedPrecision.manifestName))
            return dir
        }

        /// Largest |source − dequantized| of a quantized layer, in steps of its group (the stored scale), dequantized in
        /// FP32 so the output is not rounded again.
        static func errorInSteps(source: MLXArray, weight: MLXArray, scales: MLXArray, biases: MLXArray, bits: Int) -> Float {
            let deq = dequantized(weight, scales: scales.asType(.float32), biases: biases.asType(.float32), groupSize: 64, bits: bits)
            let src = source.asType(.float32)
            let groups = src.reshaped(Array(src.shape.dropLast()) + [-1, 64])
            let step = maximum(abs(expandedDimensions(scales.asType(.float32), axis: -1)), 1e-12)
            let ratio = (abs(groups - deq.reshaped(groups.shape)) / step).max().item(Float.self)
            return ratio
        }

        /// MLX's affine bound, in steps. MLX computes the codes with the full-precision scale and bias, then stores both
        /// in BF16 (8 significant bits, relative rounding up to 2⁻⁸). So: half a step of rounding, plus up to one step
        /// where the group's far edge is clipped (MLX snaps the scale so the near edge, and zero, are exact), plus the
        /// stored scale's rounding times up to 2^bits − 1 levels and the stored bias's rounding (bounded the same way).
        static func affineBound(bits: Int) -> Float { 0.5 + 1 + 2 * Float((1 << bits) - 1) / 256 + 0.05 }

        /// The layer holds exactly what MLX's own quantize makes of the source tensor (bits, group, layout).
        static func sameAsQuantize(_ source: MLXArray, weight: MLXArray, scales: MLXArray, biases: MLXArray?, bits: Int) -> Bool {
            let (w, s, b) = MLX.quantized(source, groupSize: 64, bits: bits, mode: .affine)
            guard let b, let biases else { return false }
            return arrayEqual(w, weight).item(Bool.self) && arrayEqual(s.view(dtype: .uint16), scales.view(dtype: .uint16)).item(Bool.self)
                && arrayEqual(b.view(dtype: .uint16), biases.view(dtype: .uint16)).item(Bool.self)
        }

        @Test(.enabled(if: mlx)) func derivesInt4AndInt8FromTheNeMoLayout() throws {
            try Device.withDefaultDevice(.cpu) {
                let scratch = try Scratch("vella-nt-derive")
                let source = try Self.fixture(scratch)
                let original = NemotronTranscribeModel.sanitize(try NemotronTranscribeModel.checkpointTensors(source))
                let originalMTP = NemotronTranscribeModel.mtpWeights(try NemotronTranscribeModel.checkpointTensors(source))
                for bits in [4, 8] {
                    let directory = try Self.manifest(scratch, source: source, bits: bits)
                    // Vella's normal validation: the manifest resolves, the worker admits it, the source carries its licence.
                    let derived = try #require(try DerivedPrecision.resolve(directory))
                    #expect(try admit(directory) == .nemotronTranscribe)
                    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/vLLM-LICENSE.txt"] {
                        #expect(FileManager.default.fileExists(atPath: derived.source.appendingPathComponent(name).path), "\(name)")
                    }
                    let model = try NemotronTranscribeModel.skeleton(derived.source)
                    try model.loadWeights(derived.source, derived: derived) // update(verify: .all) inside
                    let mtp = try #require(model.mtp)
                    for (owner, sourceWeights, rule) in [
                        (model as Module, original, { NemotronTranscribeRecipe.decoderBits($0, precisionBits: bits) }),
                        (mtp as Module, originalMTP, { Optional(NemotronTranscribeRecipe.mtpBits($0)) })
                    ] as [(Module, [String: MLXArray], (String) -> Int?)] {
                        var quantizedPaths = Set<String>()
                        for (path, leaf) in owner.leafModules().flattened() {
                            let planned = (leaf is Linear || leaf is NTSwitchLinear) ? rule(path) : nil
                            let source = sourceWeights[path + ".weight"]
                            switch leaf {
                            case let q as QuantizedLinear:
                                #expect(planned == q.bits && q.groupSize == 64, "\(path): \(q.bits)-bit")
                                let s = try #require(source)
                                #expect(q.weight.shape == [s.dim(0), s.dim(1) * q.bits / 32] && q.scales.shape == [s.dim(0), s.dim(1) / 64])
                                #expect(Self.sameAsQuantize(s, weight: q.weight, scales: q.scales, biases: q.biases, bits: q.bits), "\(path)")
                                #expect(
                                    Self.errorInSteps(source: s, weight: q.weight, scales: q.scales, biases: q.biases!, bits: q.bits) <= Self.affineBound(bits: q.bits), "\(path)")
                                quantizedPaths.insert(path)
                            case let q as NTQuantizedSwitchLinear:
                                #expect(planned == q.bits && q.groupSize == 64, "\(path): \(q.bits)-bit")
                                let s = try #require(source)
                                #expect(q.weight.shape == [s.dim(0), s.dim(1), s.dim(2) * q.bits / 32])
                                #expect(Self.sameAsQuantize(s, weight: q.weight, scales: q.scales, biases: q.biases, bits: q.bits), "\(path)")
                                #expect(
                                    Self.errorInSteps(source: s, weight: q.weight, scales: q.scales, biases: q.biases!, bits: q.bits) <= Self.affineBound(bits: q.bits), "\(path)")
                                quantizedPaths.insert(path)
                            default:
                                #expect(planned == nil, "\(path) should be quantized")
                            }
                        }
                        #expect(!quantizedPaths.isEmpty)
                        // Everything else is the source tensor, byte for byte (the router as its FP32 cast).
                        for (key, value) in owner.parameters().flattened() {
                            let module = key.split(separator: ".").dropLast().joined(separator: ".")
                            guard !quantizedPaths.contains(module) else { continue }
                            let s = try #require(sourceWeights[key], "\(key) missing from the source")
                            #expect(value.dtype == s.dtype && value.shape == s.shape && arrayEqual(value, s).item(Bool.self), "\(key) changed")
                        }
                    }
                    // Experts 4-bit only in int4; every decoder projection 8-bit in int8.
                    let expert = model.llm.backbone.layers[1].mixer as! NTMoE
                    #expect((expert.switchMLP.fc1 as? NTQuantizedSwitchLinear)?.bits == bits)
                    #expect((expert.shared.up as? QuantizedLinear)?.bits == 8)
                    #expect((mtp.moe.switchMLP.fc1 as? NTQuantizedSwitchLinear)?.bits == 4 && (mtp.ehProj as? QuantizedLinear)?.bits == 8)
                }
            }
        }

        /// A precision is derived from the 16-bit download only: never from a quantized (MLX-layout) folder.
        @Test(.enabled(if: mlx)) func refusesToDeriveFromAnMLXFolder() throws {
            try Device.withDefaultDevice(.cpu) {
                let scratch = try Scratch("vella-nt-derive")
                let source = try Self.fixture(scratch)
                let mlxDir = try scratch.folder("mlx")
                var config = Self.config
                config["model_type"] = "nemotron_transcribe"
                try JSONSerialization.data(withJSONObject: config).write(to: mlxDir.appendingPathComponent("config.json"))
                try MLX.save(
                    arrays: NemotronTranscribeModel.sanitize(try NemotronTranscribeModel.checkpointTensors(source)),
                    url: mlxDir.appendingPathComponent("model.safetensors"))
                let derived = try #require(try DerivedPrecision.resolve(try Self.manifest(scratch, source: mlxDir, bits: 4)))
                let model = try NemotronTranscribeModel.skeleton(mlxDir)
                #expect(throws: DerivedPrecision.Invalid.self) { try model.loadWeights(mlxDir, derived: derived) }
            }
        }

        // MARK: Golden (opt-in, real weights)

        /// VELLA_NEMOTRON_TRANSCRIBE_GOLDEN=1: derive int4 and int8 tensor by tensor from the real BF16 and compare with
        /// the reference Python exports (mlx-audio, MLX affine quantize): weights, scales and biases bit for bit; kept
        /// tensors byte for byte. One source tensor at a time, MLX cache capped; the report goes to stdout and
        /// VELLA_NEMOTRON_TRANSCRIBE_GOLDEN_REPORT when set. Paths: ~/Models/{NVIDIA-…, …-MLX-q4mix, …-MLX-q8mix}.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["VELLA_NEMOTRON_TRANSCRIBE_GOLDEN"] == "1"))
        func derivationMatchesTheReferenceExports() throws {
            let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Models")
            let bf16 = home.appendingPathComponent("NVIDIA-Nemotron-3.5-Transcribe-30B-A4B")
            let references = [
                4: home.appendingPathComponent("Nemotron-3.5-Transcribe-30B-A4B-MLX-q4mix"),
                8: home.appendingPathComponent("Nemotron-3.5-Transcribe-30B-A4B-MLX-q8mix")
            ]
            let savedCacheLimit = Memory.cacheLimit
            Memory.cacheLimit = 256 << 20
            defer { Memory.cacheLimit = savedCacheLimit }
            let start = Date()
            Memory.peakMemory = 0
            let model = try NemotronTranscribeModel.skeleton(bf16)
            let head = NTMTP(model.decoderConfig)
            // One pass over the source: each BF16 tensor is read once, compared with both references, and every array
            // that held it is dropped before the next (an evaluated lazy array keeps its bytes while referenced).
            var all = try NemotronTranscribeModel.checkpointTensors(bf16)
            var sources: [(name: String, tensors: [String: MLXArray], plans: [Int: [String: Int]], refs: [Int: [String: MLXArray]])] = [
                (
                    "decoder", NemotronTranscribeModel.sanitize(all),
                    [4: NemotronTranscribeRecipe.decoderPlan(model, precisionBits: 4), 8: NemotronTranscribeRecipe.decoderPlan(model, precisionBits: 8)],
                    try references.mapValues { try NemotronTranscribeModel.checkpointTensors($0) }
                ),
                (
                    "mtp", NemotronTranscribeModel.mtpWeights(all),
                    [4: NemotronTranscribeRecipe.mtpPlan(head), 8: NemotronTranscribeRecipe.mtpPlan(head)],
                    try references.mapValues { try MLX.loadArrays(url: $0.appendingPathComponent("extras/mtp.safetensors")) }
                )
            ]
            all = [:]
            func same(_ a: MLXArray, _ b: MLXArray?) -> Bool {
                guard let b, a.dtype == b.dtype, a.shape == b.shape else { return false }
                let width: DType = a.dtype == .uint32 || a.dtype == .float32 ? .uint32 : .uint16
                return arrayEqual(a.view(dtype: width), b.view(dtype: width)).item(Bool.self)
            }
            var report: [String: Any] = [:]
            var mismatches: [Int: [String]] = [4: [], 8: []], compared: [Int: Int] = [4: 0, 8: 0]
            for index in sources.indices {
                var produced: [Int: Set<String>] = [4: [], 8: []]
                for key in sources[index].tensors.keys.sorted() {
                    try autoreleasepool {
                        let value = try #require(sources[index].tensors[key])
                        sources[index].tensors[key] = nil
                        let module = key.split(separator: ".").dropLast().joined(separator: ".")
                        for bits in [4, 8] {
                            if key.hasSuffix(".weight"), let b = sources[index].plans[bits]?[module] {
                                let q = NemotronTranscribeRecipe.quantize(value, bits: b, groupSize: 64)
                                for (suffix, array) in [("weight", q.weight), ("scales", q.scales), ("biases", q.biases!)] {
                                    let name = "\(module).\(suffix)"
                                    produced[bits]!.insert(name)
                                    if !same(array, sources[index].refs[bits]?[name]) { mismatches[bits]!.append(name) }
                                    sources[index].refs[bits]?[name] = nil
                                    compared[bits]! += 1
                                }
                            } else {
                                produced[bits]!.insert(key)
                                if !same(value, sources[index].refs[bits]?[key]) { mismatches[bits]!.append(key) }
                                sources[index].refs[bits]?[key] = nil
                                compared[bits]! += 1
                            }
                        }
                    }
                    Memory.clearCache()
                }
                for bits in [4, 8] {
                    // Whatever the reference holds that the derivation did not produce.
                    let left = sources[index].refs[bits]?.keys.sorted() ?? []
                    mismatches[bits]! += left.map { "\(sources[index].name): missing from derived: \($0)" }
                    report["\(bits)b.\(sources[index].name)_tensors"] = produced[bits]!.count
                }
                sources[index].refs = [:]
            }
            for bits in [4, 8] {
                report["\(bits)b"] = [
                    "compared": compared[bits]!, "mismatches": mismatches[bits]!.count,
                    "first_mismatches": Array(mismatches[bits]!.prefix(20))
                ]
                #expect(mismatches[bits]!.isEmpty, "\(bits)b: \(mismatches[bits]!.prefix(10))")
            }
            report["seconds"] = Date().timeIntervalSince(start)
            report["mlx_peak_gb"] = Double(Memory.peakMemory) / 1e9
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if let path = ProcessInfo.processInfo.environment["VELLA_NEMOTRON_TRANSCRIBE_GOLDEN_REPORT"] {
                try data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
