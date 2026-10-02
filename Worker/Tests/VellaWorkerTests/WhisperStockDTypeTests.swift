import Foundation
import Testing
@testable import MLXAudioSTT
import MLX
import VellaWire

extension WorkerTests {
    /// Whisper's stock path computes in the checkpoint dtype, like mlx-whisper (`sinusoids(...).astype(dtype)`):
    /// mlx-whisper checkpoints omit the encoder's positional table, and a Float32 synthesised table promoted the whole
    /// encoder and decoder to Float32 (lab/notes/STANDARD-FAITHFULNESS-2026-10-03.md). The test build has no Metal
    /// library and MLX creates its GPU stream with the first array, so this checks the dtype rule, not a graph; the
    /// graph's dtype is checked on real weights by the lab probe in that note.
    @Suite struct WhisperStockDType {
        @Test func synthesisedTableTakesTheCheckpointsHalfPrecision() {
            #expect(WhisperModel.positionTableDType(checkpoint: .float16) == .float16)
            #expect(WhisperModel.positionTableDType(checkpoint: .bfloat16) == .bfloat16)
            #expect(WhisperModel.positionTableDType(checkpoint: .float32) == .float32)
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
