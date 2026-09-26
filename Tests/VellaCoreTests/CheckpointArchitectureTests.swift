import XCTest
@testable import VellaCore

final class CheckpointArchitectureTests: XCTestCase {
    func testNemoTargetsAndModelType() {
        XCTAssertEqual(checkpointArchitecture(["model_type": "whisper"]), "whisper")
        XCTAssertEqual(checkpointArchitecture(["target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"]), "parakeet")
        // parakeet-tdt_ctc-110m: hybrid TDT-CTC, loaded by the Parakeet worker path (TDT decoder).
        XCTAssertEqual(checkpointArchitecture(["target": "nemo.collections.asr.models.hybrid_rnnt_ctc_bpe_models.EncDecHybridRNNTCTCBPEModel"]), "parakeet")
        XCTAssertNil(checkpointArchitecture(["target": "nemo.collections.asr.models.ctc_bpe_models.EncDecCTCModelBPE"]))
        XCTAssertNil(checkpointArchitecture([:]))
        XCTAssertNil(checkpointArchitecture(nil))
    }
}
