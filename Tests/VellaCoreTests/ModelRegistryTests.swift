import XCTest
@testable import VellaCore
import VellaWire
import VellaTestSupport

/// The app's model descriptors agree with the shipped catalog: every family belongs to exactly one descriptor, of the
/// same mode and architecture, and every descriptor's family exists.
final class ModelRegistryTests: XCTestCase {
    func testDescriptorsCoverTheCatalog() throws {
        let catalog = try decodeCatalog(Data(contentsOf: Repository.root.appendingPathComponent("Resources/models.json")))
        for family in catalog.families {
            let owners = ModelRegistry.all.filter { $0.catalogFamilies.contains(family.id) }
            XCTAssertEqual(owners.count, 1, family.id)
            guard let owner = owners.first else { continue }
            XCTAssertEqual(owner.mode, family.mode, family.id)
            for (label, variant) in family.variants {
                XCTAssertEqual(variant.architecture, owner.architecture.rawValue, "\(family.id) \(label)")
            }
        }
        let families = Set(catalog.families.map(\.id))
        for descriptor in ModelRegistry.all {
            XCTAssertTrue(Set(descriptor.catalogFamilies).isSubset(of: families), descriptor.architecture.rawValue)
        }
    }

    func testModesAndPolicies() {
        XCTAssertEqual(Set(ModelRegistry.architectures(.dictation)), [.parakeet, .qwen3ASR, .whisper])
        XCTAssertEqual(ModelRegistry.architectures(.streaming), [.nemotronASR])
        XCTAssertEqual(ModelRegistry.descriptor(architecture: "whisper")?.preferredSegmentSeconds, 20)
        XCTAssertEqual(ModelRegistry.all.filter { $0.preferredSegmentSeconds != nil }.map(\.architecture), [.whisper])
        XCTAssertEqual(ModelRegistry.all.filter(\.calibratable).map(\.architecture.rawValue).sorted(), ["parakeet", "qwen3_asr", "whisper"])
        XCTAssertNil(ModelRegistry.descriptor(architecture: "stub"))
        XCTAssertNil(ModelRegistry.descriptor(architecture: nil))
    }
}
