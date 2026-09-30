import XCTest
import VellaTestSupport

final class IntegrationGateTests: XCTestCase {
    func testSkipsOnlyUnderCIWithoutTheFlag() {
        XCTAssertNil(Integration.skipReason([:]), "locally everything runs")
        XCTAssertNil(Integration.skipReason(["CI": "false"]))
        XCTAssertNotNil(Integration.skipReason(["CI": "true"]))
        XCTAssertNotNil(Integration.skipReason(["CI": "1"]))
        XCTAssertNil(Integration.skipReason(["CI": "true", "VELLA_INTEGRATION": "1"]))
    }
}
