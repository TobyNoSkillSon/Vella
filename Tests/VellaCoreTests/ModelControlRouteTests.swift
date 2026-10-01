import XCTest
@testable import VellaCore

final class ModelControlRouteTests: XCTestCase {
    func testCatalogAndAuthenticatedControlsAreAdditiveRoutes() {
        XCTAssertEqual(APIRoute.match("/v1/models/catalog"), .catalog)
        XCTAssertEqual(APIRoute.match("/v1/models/alpha"), .model("alpha"))
        for action in ["select", "load", "unload", "reload", "get", "delete"] {
            let route = APIRoute.match("/v1/models/alpha/" + action)
            XCTAssertEqual(route, .modelAction("alpha", action))
            XCTAssertEqual(route?.method, "POST")
        }
        XCTAssertEqual(APIRoute.match("/v1/settings/memory"), .settingAction("memory"))
        XCTAssertNil(APIRoute.match("/v1/models/alpha/frobnicate"))
    }
    func testMutationHeadersRequireNonSimpleJSONAndRejectDuplicateToken() {
        func refusal(_ method: String = "POST", _ extra: String = "") -> Int? {
            let text = "\(method) /v1/models/alpha/get HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Type: application/json\r\nContent-Length: 2\r\n" + extra
            return APIRequestCheck.refusal(HTTPHead.parse(Data(text.utf8))!, port: 1234)?.status
        }
        XCTAssertNil(refusal())
        XCTAssertEqual(refusal("GET"), 405)
        XCTAssertEqual(refusal("POST", "Origin: https://evil.example"), 403)
        XCTAssertEqual(refusal("POST", "X-Vella-Token: a\r\nX-Vella-Token: b"), 400)
    }
}
