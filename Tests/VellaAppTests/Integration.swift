import Foundation
import XCTest

/// Tests that start another program (a built product such as the app or the `vella` binary, a compiler, an installer
/// script) run locally only: under CI (CI=true, set by GitHub Actions) they skip unless VELLA_INTEGRATION=1. Run them
/// with `VELLA_INTEGRATION=1 xcrun swift test` before a release. Tests with a real worker and a real model are opt-in
/// separately (their own environment variables) and never run in CI.
enum Integration {
    static func require(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let reason = skipReason(environment) { throw XCTSkip(reason) }
    }
    static func skipReason(_ environment: [String: String]) -> String? {
        let ci = (environment["CI"] ?? "").lowercased()
        guard ci == "true" || ci == "1", environment["VELLA_INTEGRATION"] != "1" else { return nil }
        return "integration test: runs locally, or under CI with VELLA_INTEGRATION=1"
    }
}
