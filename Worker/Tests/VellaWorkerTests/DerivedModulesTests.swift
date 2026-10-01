import Foundation
import Testing
@testable import MLXAudioSTT

extension WorkerTests {
    /// floatModules are checked against the loaded model's quantizable module paths (`quantizationTargets` collects
    /// them from the model, then `targets(quantizable:)`): a prefix that keeps no quantizable module fails the load with
    /// a clear error instead of silently quantizing everything under the mixed recipe's key.
    @Suite struct DerivedModules {
        /// Parakeet's top-level layout: encoder layers, the decoder's embedding, the joint's three Linears.
        static let parakeet = ["encoder.layers.0.linear1", "encoder.layers.0.linear2", "decoder.prediction.embed", "joint.enc", "joint.pred", "joint.joint_net.2"]
        func recipe(_ modules: [String]) -> DerivedPrecision {
            DerivedPrecision(source: URL(fileURLWithPath: "/tmp/x"), precision: "8b", dtype: nil, bits: 8, groupSize: 64, floatModules: modules)
        }
        @Test func knownPrefixesKeepTheirModulesFloat() throws {
            #expect(try recipe([]).targets(quantizable: Self.parakeet) == Set(Self.parakeet))
            #expect(try recipe(["decoder", "joint"]).targets(quantizable: Self.parakeet) == ["encoder.layers.0.linear1", "encoder.layers.0.linear2"])
        }
        @Test func unknownOrIneffectivePrefixesFail() {
            // A typo, another architecture's path (Whisper's), a partial name, a path below every leaf.
            for bad in [["joints"], ["model.encoder"], ["decoder", "dec"], ["joint.enc.weight"]] {
                #expect(throws: DerivedPrecision.Invalid.self) { try recipe(bad).targets(quantizable: Self.parakeet) }
            }
        }
    }
}
