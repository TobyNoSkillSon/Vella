import Foundation
import Testing
@testable import MLXAudioSTT
import VellaWire

extension WorkerTests {
    @Suite struct Defaults {
        // Every frozen env-map cell, including absent tiers and families with no kept lever.
        @Test func frozenTable() {
            let families = [
                "parakeet-v3", "parakeet-v3-ultra", "nemotron-3.5-streaming-0.6b",
                "qwen3-asr-1.7b", "qwen3-asr-0.6b", "whisper-large-v3", "whisper-large-v3-turbo", "unknown"
            ]
            for family in families {
                for precision in ["BF16", "FP16", "8b", "4b", "FP32", "2b"] {
                    for recipe in Recipe.allCases {
                        var expected: Set<String> = []
                        if recipe != .standard {
                            if family == "parakeet-v3-ultra", ["BF16", "8b", "4b"].contains(precision) {
                                expected.insert("VELLA_PARAKEET_TAILBLOCK")
                            }
                            if ["parakeet-v3", "parakeet-v3-ultra"].contains(family), recipe == .optimized_fast {
                                if precision == "8b" { expected.insert("VELLA_PARAKEET_INT8") }
                                if precision == "4b" { expected.insert("VELLA_PARAKEET_INT4") }
                            }
                            if family == "nemotron-3.5-streaming-0.6b", ["BF16", "8b", "4b"].contains(precision) {
                                expected.insert("VELLA_NEMO_KEEPCACHE")
                                if recipe == .optimized_fast, precision == "BF16" { expected.insert("VELLA_NEMO_JOINTBATCH") }
                            }
                        }
                        #expect(
                            KeptLevers(family: family, precision: precision, recipe: recipe).enabled == expected,
                            "\(family):\(precision):\(recipe)")
                        let off = Dictionary(uniqueKeysWithValues: KeptLevers.switches.map { ($0, "0") })
                        #expect(KeptLevers(family: family, precision: precision, recipe: recipe, environment: off).enabled.isEmpty)
                    }
                }
            }
        }
        @Test func overridesRespectRecipe() {
            let on = Dictionary(uniqueKeysWithValues: KeptLevers.switches.map { ($0, "1") })
            for family in ["parakeet-v3", "parakeet-v3-ultra", "nemotron-3.5-streaming-0.6b"] {
                for precision in ["BF16", "8b", "4b"] {
                    let fast = KeptLevers(family: family, precision: precision, recipe: .optimized_fast, environment: on)
                    #expect(fast.enabled.count == (family.hasPrefix("parakeet") ? 3 : 2))
                    #expect(KeptLevers(family: family, precision: precision, recipe: .standard, environment: on).enabled.isEmpty)
                    #expect(KeptLevers(family: family, precision: precision, recipe: .optimized_fast, environment: on, forcedStock: true).enabled.isEmpty)
                    let exact = KeptLevers(family: family, precision: precision, recipe: .optimized_exact, environment: on)
                    #expect(exact.enabled == Set([family.hasPrefix("parakeet") ? "VELLA_PARAKEET_TAILBLOCK" : "VELLA_NEMO_KEEPCACHE"]))
                }
            }
        }
        @Test func effectiveKeyConfiguration() {
            let cell = KeptLevers(family: "parakeet-v3-ultra", precision: "8b", recipe: .optimized_fast)
            #expect(
                FastPathGate.effectiveConfiguration(cell, environment: [:])
                    == "VELLA_PARAKEET_INT8=1,VELLA_PARAKEET_TAILBLOCK=1")
            let explicit = ["VELLA_PARAKEET_INT8": "1", "VELLA_PARAKEET_TAILBLOCK": "1"]
            #expect(
                FastPathGate.effectiveConfiguration(cell, environment: explicit)
                    == FastPathGate.effectiveConfiguration(cell, environment: [:]))
            #expect(
                FastPathGate.effectiveRevision("parakeet-r2-dense-encoder", levers: cell)
                    == "parakeet-r2-dense-encoder+int8-2+smallm-qtile-1+tailblock-1")
        }
        @Test func actualDefaultAndOverrideKeysAgree() throws {
            let scratch = try Scratch("vella-default-keys")
            let model = try scratch.folder("parakeet-ultra-mlx-bf16")
            try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
            try Data("test weights".utf8).write(to: model.appendingPathComponent("model.safetensors"))
            try withEnvironment(WorkerTests.Gate.clean) {
                let base = "parakeet-r2-dense-encoder"
                let host = FastPathGate.Host(gpuFamily: "apple9", osBuild: "25G72")
                let defaultKey = try FastPathGate.key(model, revision: base, host: host)
                let explicitKey = try withEnvironment(["VELLA_PARAKEET_TAILBLOCK": "1"]) {
                    try FastPathGate.key(model, revision: base, host: host)
                }
                #expect(defaultKey == explicitKey)
                let offKey = try withEnvironment(["VELLA_PARAKEET_TAILBLOCK": "0"]) {
                    try FastPathGate.key(model, revision: base, host: host)
                }
                #expect(offKey != defaultKey)
            }
        }
        @Test func checkpointIdentityAndNoGlobalLeak() throws {
            let scratch = try Scratch("vella-defaults")
            let ultra = try scratch.folder("parakeet-ultra-mlx-bf16")
            let v3 = try scratch.folder("parakeet-tdt-0.6b-v3-mlx-bf16-local")
            for path in [ultra, v3] { try Data("{}".utf8).write(to: path.appendingPathComponent("config.json")) }
            #expect(try KeptLevers.resolve(ultra, environment: [:]).contains("VELLA_PARAKEET_TAILBLOCK"))
            #expect(try !KeptLevers.resolve(v3, environment: [:]).contains("VELLA_PARAKEET_TAILBLOCK"))
            let derived = DerivedPrecision(source: v3, precision: "4b", dtype: nil, bits: 4, groupSize: 64, family: "parakeet-v3")
            #expect(try KeptLevers.resolve(v3, derived: derived, environment: [:]).enabled == Set(["VELLA_PARAKEET_INT4"]))
            #expect(try KeptLevers.resolve(ultra, environment: [:]).enabled == Set(["VELLA_PARAKEET_TAILBLOCK"]))
        }
    }
}
