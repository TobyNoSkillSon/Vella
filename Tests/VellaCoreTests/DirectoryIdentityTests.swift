import XCTest
import Foundation
@testable import VellaCore

final class DirectoryIdentityTests: XCTestCase {
    func testStringBuiltTmpDirectoryAndDirectoryHintShareIdentity() {
        let string = URL(fileURLWithPath: "/tmp/vella-string-support")
        let hinted = URL(fileURLWithPath: "/tmp/vella-string-support/", isDirectory: true)
        XCTAssertTrue(sameDirectory(string, hinted)); XCTAssertTrue(sameDirectory(hinted, string))
        XCTAssertTrue(sameDirectory(string.appendingPathComponent("Models"), hinted.appendingPathComponent("Models", isDirectory: true)))
        XCTAssertTrue(isWithinDirectory(string.appendingPathComponent("Models"), root: hinted))
        XCTAssertFalse(isWithinDirectory(URL(fileURLWithPath: "/tmp/vella-string-support-other/Models"), root: hinted))
        XCTAssertFalse(isWithinDirectory(string, root: hinted))
        XCTAssertTrue(isWithinDirectory(string, root: hinted, includingRoot: true))
        XCTAssertTrue(isWithinDirectory(string, root: URL(fileURLWithPath: "/", isDirectory: true)))
    }
    func testNormalizationDoesNotSilentlyResolveOwnershipLinks() throws {
        let root = URL(fileURLWithPath: "/tmp/vella-path-identities-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertFalse(sameDirectory(alias, real), "ownership checks retain the declared path")
        XCTAssertTrue(sameDirectory(alias.resolvingSymlinksInPath(), real.resolvingSymlinksInPath()))
        XCTAssertTrue(sameFiles(root.path + "/real/./", real.path))
    }
}
