import XCTest
@testable import VellaCore

final class CheckpointArchitectureTests: XCTestCase {
    func testNemoTargetsAndModelType() {
        XCTAssertEqual(checkpointArchitecture(["model_type": "whisper"]), "whisper")
        XCTAssertEqual(checkpointArchitecture(["target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"]), "parakeet")
        // The hybrid TDT-CTC target (only Parakeet TDT-CTC 110M, removed from the catalog) is no longer admitted.
        XCTAssertNil(checkpointArchitecture(["target": "nemo.collections.asr.models.hybrid_rnnt_ctc_bpe_models.EncDecHybridRNNTCTCBPEModel"]))
        XCTAssertNil(checkpointArchitecture(["target": "nemo.collections.asr.models.ctc_bpe_models.EncDecCTCModelBPE"]))
        XCTAssertNil(checkpointArchitecture([:]))
        XCTAssertNil(checkpointArchitecture(nil))
    }
}
