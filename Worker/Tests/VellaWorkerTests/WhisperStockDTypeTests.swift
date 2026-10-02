import Foundation
import Testing
@testable import MLXAudioSTT
import MLX
import VellaWire

extension WorkerTests {
    /// The helper test is array-free. The opt-in sanitizer graph test below uses MLX's CPU device and requires
    /// a built default.metallib for MLX scheduler initialization (no GPU kernels run). Python reference probes and
    /// the old CPU smoke do not read Vella's Swift graph; this test exercises the actual loader sanitizer call.
    @Suite struct WhisperStockDType {
        @Test func synthesisedTableTakesTheCheckpointsHalfPrecision() {
            #expect(WhisperModel.positionTableDType(checkpoint: .float16) == .float16)
            #expect(WhisperModel.positionTableDType(checkpoint: .bfloat16) == .bfloat16)
            #expect(WhisperModel.positionTableDType(checkpoint: .float32) == .float32)
        }
        @Test(.enabled(if: ProcessInfo.processInfo.environment["VELLA_TEST_MLX_CPU"] == "1"))
        func loaderSanitizerNormalizesBothFormats() {
            Device.withDefaultDevice(.cpu) {
                let config = WhisperConfig(dModel: 4, maxSourcePositions: 3)
                let tableKey = "model.encoder.embed_positions.weight"
                for mlxFormat in [false, true] {
                    for checkpoint in [DType.float16, .float32] {
                        for suppliedDType in [DType?.none, .some(.float16), .some(.float32)] {
                            for quantized in [false, true] {
                                let convKey = mlxFormat ? "encoder.conv1.weight" : "model.encoder.conv1.weight"
                                var weights = [convKey: MLXArray(Array(repeating: Float(0), count: 16)).reshaped([4, 2, 2]).asType(checkpoint)]
                                // A blocks key selects the real mlx-whisper format detector, even on dense tiers.
                                let linearKey = mlxFormat ? "encoder.blocks.0.mlp.0.weight" : "model.encoder.layers.0.fc1.weight"
                                weights[linearKey] = quantized ? MLXArray([UInt32(7)]) : MLXArray([Float(7)]).asType(checkpoint)
                                if quantized {
                                    let scalesKey = mlxFormat ? "encoder.blocks.0.mlp.0.scales" : "model.encoder.layers.0.fc1.scales"
                                    weights[scalesKey] = MLXArray([Float(0.25)]).asType(checkpoint)
                                }
                                let supplied = MLXArray((0..<12).map { Float($0) / 7 }).reshaped([3, 4])
                                if let dtype = suppliedDType {
                                    weights[mlxFormat ? "encoder.positional_embedding" : tableKey] = supplied.asType(dtype)
                                }
                                let sanitized = WhisperModel.sanitize(weights: weights, config: config)
                                let table = sanitized[tableKey]!
                                #expect(table.dtype == checkpoint)
                                #expect(table.shape == [3, 4])
                                let expected =
                                    suppliedDType.map { supplied.asType($0).asType(checkpoint) }
                                    ?? WhisperModel.whisperSinusoids(length: 3, channels: 4, dtype: checkpoint)
                                #expect(table.asType(.float32).asArray(Float.self) == expected.asType(.float32).asArray(Float.self))
                                // Positional add, the promotion site that originally changed the whole model.
                                let hidden = MLXArray(Array(repeating: Float(0), count: 12)).reshaped([3, 4]).asType(checkpoint) + table
                                #expect(hidden.dtype == checkpoint)
                                eval(hidden)
                                if quantized { #expect(sanitized["model.encoder.layers.0.fc1.weight"]?.dtype == .uint32) }
                            }
                        }
                    }
                }
            }
        }
        @Test func revisionIsTheSameForEveryRecipe() {
            for recipe in ["optimized_fast", "optimized_exact", "standard"] {
                withEnvironment(["VELLA_RECIPE": recipe]) {
                    #expect(WhisperModel.fastPathRevision == "whisper-4")
                    #expect(ModelRuntimeRegistry.dictation(.whisper)?.gateRevision == "whisper-4")
                }
            }
        }
    }
}
