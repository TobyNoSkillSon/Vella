import Foundation
import Testing
import MLX
import VellaWire
@testable import MLXAudioSTT

extension WorkerTests {
    /// Nemotron 3.5 Transcribe: prompt, vocabulary, chunking, markup and loading rules. No model inference.
    @Suite struct NemotronTranscribe {
        @Test func registeredAsDictationWithoutSelfTestChild() {
            #expect(ModelRuntimeRegistry.dictation(.nemotronTranscribe) == NemotronTranscribeRuntime.self)
            #expect(ModelRuntimeRegistry.streaming(.nemotronTranscribe) == nil)
            // Qualifying would load a second 21–68 GB copy in a child process.
            #expect(NemotronTranscribeRuntime.hasFastPath == false)
            #expect(ParakeetRuntime.hasFastPath && NemotronRuntime.hasFastPath)
        }

        @Test func plainASRPromptOnly() {
            let user = NemotronTranscribePrompt.user(words: [])
            #expect(user == NemotronTranscribePrompt.asr + " <|audio|>")
            for word in ["speaker", "<spk", "<ev:", "<sty:", "Translate", "Contextual"] { #expect(!user.contains(word)) }
            let turns = NemotronTranscribePrompt.turns(words: [])
            #expect(turns == ["<|im_start|>system\n<|im_end|>\n", "<|im_start|>user\n\(user)<|im_end|>\n", "<|im_start|>assistant\n<think></think>"])
        }

        @Test func vocabularyPromptHoldsOnlyTheWordList() {
            let user = NemotronTranscribePrompt.user(words: ["Parakeet", " Heimdall ", "", "parakeet", "Poznań"])
            #expect(user == NemotronTranscribePrompt.asr + "\nContextual vocabulary: Parakeet, Heimdall, Poznań <|audio|>")
            #expect(user.components(separatedBy: "<|audio|>").count == 2)
            let many = (0 ..< 300).map { "Word\($0)" }
            #expect(NemotronTranscribePrompt.vocabulary(many).count == NemotronTranscribePrompt.maxWords)
        }

        /// The worker passes `words` only: Parakeet's acoustic entries and variants never reach the prompt.
        @Test func vocabularyFileEntriesAndVariantsStayOut() throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-vocab-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("vocabulary.json")
            try #"{"words": ["Zephyr", "Heimdall"], "boost": 4, "entries": [{"word": "Zephyr", "surface": "se", "prefix": "ze"}], "variants": [{"word": "Heimdall", "spelling": "Heimdal"}]}"#
                .write(to: file, atomically: true, encoding: .utf8)
            let vocabulary = try ParakeetVocabulary.read(from: file)
            let user = NemotronTranscribePrompt.user(words: vocabulary.words)
            #expect(user.hasSuffix("\nContextual vocabulary: Zephyr, Heimdall <|audio|>"))
            #expect(!user.contains("Heimdal,") && !user.contains(" se") && !user.contains("Heimdal "))
        }

        @Test func chunksAtMostTwoMinutesCutAtSilence() {
            let rate = NemotronTranscribeChunking.sampleRate
            #expect(NemotronTranscribeChunking.plan([Float](repeating: 0.1, count: 120 * rate)) == [0 ..< 120 * rate])
            // 5 minutes of tone with silence at 110 s and 225 s.
            var samples = (0 ..< 300 * rate).map { Float(sin(Double($0) * 0.05)) * 0.3 }
            for s in [110, 225] { for i in (s * rate) ..< (s * rate + rate / 2) { samples[i] = 0 } }
            let plan = NemotronTranscribeChunking.plan(samples)
            #expect(plan.count == 3)
            #expect(plan.allSatisfy { $0.count <= 120 * rate })
            #expect(plan.first?.lowerBound == 0 && plan.last?.upperBound == samples.count)
            for (a, b) in zip(plan, plan.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
            #expect(abs(plan[0].upperBound - (110 * rate + rate / 4)) < rate / 4)
            #expect(abs(plan[1].upperBound - (225 * rate + rate / 4)) < rate / 4)
            // No silence anywhere: still never over the limit.
            let dense = (0 ..< 250 * rate).map { Float(sin(Double($0) * 0.05)) * 0.3 + 0.01 }
            #expect(NemotronTranscribeChunking.plan(dense).allSatisfy { $0.count <= 120 * rate })
        }

        /// 28 Oct, Toby's speech: the 17-word list made the model append "Poznań", never spoken.
        @Test func trailingVocabularyGuard() {
            typealias G = NemotronTranscribeVocabularyGuard
            let words = ["Poznań", "Heimdall", "Liquid AI"]
            let invented = G.trailingCandidate("Apparently two caches supported. Poznań", words: words)
            #expect(invented?.kept == "Apparently two caches supported.")
            #expect(invented?.dropped == "Poznań")
            #expect(G.trailingCandidate("We met in Poznań. Liquid AI.", words: words)?.dropped == "Liquid AI.")
            // A segment that is only a list word is a candidate too (kept empty); the plain decode decides.
            #expect(G.trailingCandidate("Poznań.", words: words)?.kept == "")
            // A list word inside a real sentence, or no list: no candidate.
            #expect(G.trailingCandidate("We met in Poznań.", words: words) == nil)
            #expect(G.trailingCandidate("Done. Poznań", words: []) == nil)
            #expect(G.trailingCandidate("Done. Poznań is lovely.", words: words) == nil)
            // The plain decode heard nothing there: drop.
            #expect(G.shouldDrop(withList: "Apparently two caches supported. Poznań", withoutList: "Apparently two kishi supported.", dropped: "Poznań"))
            #expect(G.shouldDrop(withList: "Poznań.", withoutList: "", dropped: "Poznań."))
            // It heard a word there, however it spelled or punctuated it: keep.
            #expect(!G.shouldDrop(withList: "We start now. Poznań.", withoutList: "We start now. Posnan.", dropped: "Poznań."))
            #expect(!G.shouldDrop(withList: "We start now. Poznań.", withoutList: "We start now, Posnan.", dropped: "Poznań."))
            #expect(!G.shouldDrop(withList: "Poznań.", withoutList: "Posnan.", dropped: "Poznań."))
            // A filler only the list decode kept does not decide it (round-2 review case), nor a misspelt anchor.
            #expect(!G.shouldDrop(withList: "So, um, we start now. Poznań.", withoutList: "So we start now Posnan.", dropped: "Poznań."))
            #expect(G.shouldDrop(withList: "So, um, we start now. Poznań.", withoutList: "So we start now.", dropped: "Poznań."))
            #expect(G.shouldDrop(withList: "We met in Liquid. Heimdall.", withoutList: "We met in liquids.", dropped: "Heimdall."))
            #expect(G.split("Dr. No? Yes… ok") == ["Dr. ", "No? ", "Yes… ", "ok"])
        }

        @Test func markupIsStrippedWordsKept() {
            #expect(NemotronTranscribeMarkup.strip("<spk:0> Hello there. <spk:1> Hi, how are you?") == "Hello there. Hi, how are you?")
            #expect(NemotronTranscribeMarkup.strip("I said <ev:laugh> that <sty:whisper>quietly</sty:whisper> , right") == "I said that quietly, right")
            #expect(NemotronTranscribeMarkup.strip("<think>plan the answer</think>Dzień dobry <spk:3>wszystkim.") == "Dzień dobry wszystkim.")
            #expect(NemotronTranscribeMarkup.strip("Stray </think> tag and <think> here<|im_end|>") == "Stray tag and here")
            // Text without markup is untouched, French spacing included.
            #expect(NemotronTranscribeMarkup.strip("Vraiment ? Oui : bien sûr !") == "Vraiment ? Oui : bien sûr !")
            #expect(NemotronTranscribeMarkup.strip("<spk:0>Bonjour <spk:1> ?") == "Bonjour?")
            #expect(NemotronTranscribeMarkup.strip("a < b and c > d") == "a < b and c > d")
            #expect(NemotronTranscribeMarkup.strip("Plain text.") == "Plain text.")
        }

        @Test func configDecodesAndRejectsOtherVariants() throws {
            var llm: [String: Any] = [
                "model_type": "nemotron_h", "vocab_size": 64, "hidden_size": 32, "num_attention_heads": 4, "num_key_value_heads": 2,
                "head_dim": 8, "mamba_num_heads": 4, "mamba_head_dim": 8, "ssm_state_size": 32, "conv_kernel": 4, "n_groups": 2,
                "layer_norm_epsilon": 1e-5, "moe_intermediate_size": 16, "moe_shared_expert_intermediate_size": 16,
                "n_routed_experts": 8, "num_experts_per_tok": 2, "norm_topk_prob": true, "routed_scaling_factor": 2.5,
                "time_step_limit": [0.0, ["__float__": "Infinity"]], "layers_block_type": ["mamba", "moe", "attention", "moe"]
            ]
            let config = try NTDecoderConfig(json: llm)
            #expect(config.pattern == ["M", "E", "*", "E"])
            #expect(config.timeStepLimit.0 == 0 && config.timeStepLimit.1 == .infinity)
            llm["n_group"] = 2
            #expect(throws: NemotronTranscribeError.self) { try NTDecoderConfig(json: llm) }
        }

        /// The BF16 tier is NVIDIA's NeMo layout: keys are mapped, the MTP and CTC heads dropped, experts transposed.
        @Test func nvidiaLayoutKeys() {
            typealias T = NemotronTranscribeKeys.Transform
            func map(_ k: String, _ shape: [Int] = [2, 2]) -> (String, T)? { NemotronTranscribeKeys.map(k, shape: shape) }
            #expect(map("llm.model.embed_tokens.weight")?.0 == "llm.backbone.embeddings.weight")
            #expect(map("llm.model.norm.weight")?.0 == "llm.backbone.norm_f.weight")
            #expect(map("llm.model.layers.0.mixer._fp32_params.A_log")?.0 == "llm.backbone.layers.0.mixer.A_log")
            let fc1 = map("llm.model.layers.1.mixer.experts.gate_and_up_projs", [128, 2688, 1856])
            #expect(fc1?.0 == "llm.backbone.layers.1.mixer.switch_mlp.fc1.weight" && fc1?.1 == T(transpose: true))
            #expect(map("llm.model.layers.1.mixer.experts.down_projs", [128, 1856, 2688])?.0 == "llm.backbone.layers.1.mixer.switch_mlp.fc2.weight")
            #expect(map("llm.model.layers.1.mixer.gate.weight")?.1 == T(float32: true))
            #expect(map("llm.model.layers.0.mixer.conv1d.weight", [6144, 1, 4])?.1 == T(transpose: true))
            #expect(map("llm.model.layers.0.mixer.conv1d.weight", [6144, 4, 1])?.1 == T())
            #expect(map("perception.encoder.diarization_model.sortformer_modules.subpixel_upsample.weight", [1536, 192, 3])?.1 == T(transpose: true))
            #expect(map("perception.preprocessor.featurizer.fb")?.0 == "perception.preprocessor.fb")
            #expect(map("perception.encoder.asr_encoder.layers.0.ffn.net.3.weight")?.0 == "perception.encoder.asr_encoder.layers.0.ffn.linear2.weight")
            for dropped in ["llm.mtp.layers.0.eh_proj.weight", "ctc_timestamp.decoder.upsample.bias", "llm.lm_head._extra_state"] {
                #expect(map(dropped) == nil)
            }
        }

        /// NVIDIA's BF16 checkpoint carries the MTP head under llm.mtp.*; every one maps to the head (header only).
        @Test func nvidiaMTPKeysCoverTheCheckpoint() throws {
            let file = URL(fileURLWithPath: Self.localFolders[2]).appendingPathComponent("model.safetensors")
            guard let handle = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? handle.close() }
            let size = try handle.read(upToCount: 8)!.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let header = try JSONSerialization.jsonObject(with: handle.read(upToCount: Int(size))!) as! [String: Any]
            let mtp = Set(header.keys.filter { $0.hasPrefix("llm.mtp.") && !$0.hasSuffix("._extra_state") })
            #expect(mtp == Set(NTMTP.nvidiaKeys.keys))
        }

        @Test func modelFolderLicenceFilesPresent() throws {
            for path in Self.localFolders {
                let dir = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/Qwen3-ASR-LICENSE.txt", "licenses/vLLM-LICENSE.txt"] {
                    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(path) lacks \(name)")
                }
                let licence = try String(contentsOf: dir.appendingPathComponent("LICENSE"), encoding: .utf8)
                #expect(licence.contains("OpenMDW") && licence.contains("NVIDIA CORPORATION"))
            }
        }

        static let localFolders = [
            NSHomeDirectory() + "/Models/Nemotron-3.5-Transcribe-30B-A4B-MLX-q4mix",
            NSHomeDirectory() + "/Models/Nemotron-3.5-Transcribe-30B-A4B-MLX-q8mix",
            NSHomeDirectory() + "/Models/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B"
        ]

        // MARK: Opt-in model test (one at a time, int4 only, ~25 GB)

        /// VELLA_NEMOTRON_TRANSCRIBE_MODEL=<int4 folder> VELLA_NEMOTRON_TRANSCRIBE_REF=<dir with ref.json, clip*.f32>:
        /// loads the model, checks the prompt tokens and, per clip, the stock and MTP token IDs against mlx-audio.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["VELLA_NEMOTRON_TRANSCRIBE_MODEL"] != nil))
        func parityWithPythonReference() async throws {
            let env = ProcessInfo.processInfo.environment
            let model = try await NemotronTranscribeModel.fromModelDirectory(URL(fileURLWithPath: env["VELLA_NEMOTRON_TRANSCRIBE_MODEL"]!))
            let refDir = URL(fileURLWithPath: env["VELLA_NEMOTRON_TRANSCRIBE_REF"]!)
            let ref = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("ref.json"))) as! [String: [String: Any]]
            var report: [String: Any] = [:]
            for key in ref.keys.sorted() {
                let entry = ref[key]!
                let parts = key.split(separator: "/")
                let clip = String(parts[0]), words = parts[1] == "vocab" ? ["Poznań", "Warszawa", "Parakeet"] : []
                let data = try Data(contentsOf: refDir.appendingPathComponent("\(clip).f32"))
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let tokens = try model.promptTokens(words: words)
                #expect(tokens == (entry["prompt_ids"] as! [Int]).map { $0 == 0 ? model.audioToken : $0 }.reduce(into: [Int]()) { out, t in
                    if t != model.audioToken || out.last != model.audioToken { out.append(t) }
                }, "\(key) prompt tokens")
                let audio = model.perception(MLXArray(samples))
                let embeddings = try model.inputs(tokens: tokens, audio: audio)
                let start = Date()
                let stock = model.decodeGreedy(embeddings, maxTokens: 1024)
                let stockSeconds = Date().timeIntervalSince(start)
                let mtpStart = Date()
                let chain = model.mtp.map { model.decodeMTP(embeddings, maxTokens: 1024, mtp: $0) } ?? []
                let mtpSeconds = Date().timeIntervalSince(mtpStart)
                let refStock = entry["stock"] as! [Int], refChain = entry["chain"] as! [Int]
                func agree(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).prefix { $0 == $1 }.count }
                report[key] = ["stock_equal": stock == refStock, "stock_prefix": agree(stock, refStock), "stock_len": [stock.count, refStock.count],
                               "mtp_equal": chain == refChain, "mtp_prefix": agree(chain, refChain), "mtp_len": [chain.count, refChain.count],
                               "stock_s": stockSeconds, "mtp_s": mtpSeconds, "seconds_audio": Double(samples.count) / 16000,
                               "text": model.text(stock), "mtp_text": model.text(chain)]
            }
            // Token-exact where the reference runs agreed on 28 Oct (the 15 s clip, the 60 s clip without a list).
            for key in ["clip15/plain", "clip15/vocab", "clip60/plain"] {
                let row = report[key] as? [String: Any]
                #expect(row?["stock_equal"] as? Bool == true, "\(key) stock tokens")
            }
            for key in ["clip15/plain", "clip15/vocab"] {
                #expect((report[key] as? [String: Any])?["mtp_equal"] as? Bool == true, "\(key) MTP tokens")
            }
            // The worker's own entry point: chunk plan, prompt, guard and markup strip, on the 15 s clip.
            let clip = try Data(contentsOf: refDir.appendingPathComponent("clip15.f32")).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            model.vocabularyWords = []
            let output = model.generate(audio: MLXArray(clip))
            #expect(model.lastError == nil)
            #expect(output.text == (ref["clip15/plain"]!["text"] as! String).trimmingCharacters(in: .whitespacesAndNewlines))
            report["peak_gb"] = Double(Memory.peakMemory) / 1e9
            let out = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: refDir.appendingPathComponent("swift-parity.json"))
            print(String(decoding: out, as: UTF8.self))
        }
    }
}
