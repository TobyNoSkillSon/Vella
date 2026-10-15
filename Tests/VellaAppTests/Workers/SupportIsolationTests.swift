import XCTest
import VellaCore
@testable import Vella

final class SupportIsolationTests: XCTestCase {
    @MainActor func testDefaultRuntimeRecoveryProbeCannotUseTheRealProfileUnderXCTest() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella")
        let runtime = Runtime()
        XCTAssertFalse(sameDirectory(runtime.support, real))
        if ProcessInfo.processInfo.environment["VELLA_SUPPORT_DIR"] == nil {
            XCTAssertTrue(runtime.support.lastPathComponent.hasPrefix("vella-xctest-"))
        }
        defer {
            if runtime.support.lastPathComponent.hasPrefix("vella-xctest-") { try? FileManager.default.removeItem(at: runtime.support) }
        }
        let environment = runtime.workerEnvironment(ModelRef(id: "isolation", path: "/fixture/model", mode: .dictation))
        XCTAssertEqual(environment["VELLA_SUPPORT_DIR"], runtime.support.path)
        let files = try FileManager.default.contentsOfDirectory(at: runtime.support.appendingPathComponent("Worker"), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasPrefix("stock-recovery-") })
    }
}
