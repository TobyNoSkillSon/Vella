import XCTest
import Darwin
@testable import VellaCore

/// worker-status.json carries the API token that lets a caller make Vella read local files. Every version of it,
/// the first and each atomic replacement, must be owner-only whatever the umask or the directory's ACL.
final class StatusFilePermissionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("status-mode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }
    func aclEntries(_ url: URL) -> Int {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return 0 }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var count = 0
        var id = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, Int32(id), &entry) == 0 { count += 1; id = ACL_NEXT_ENTRY.rawValue }
        return count
    }

    func testStatusWithTokenIsOwnerOnlyWhenCreatedAndReplaced() throws {
        let previous = umask(0o022); defer { umask(previous) }
        let target = root.appendingPathComponent("worker-status.json")
        var status = WorkerStatus(); status.api_token = "synthetic-token"
        try status.write(to: target)
        XCTAssertEqual(try mode(target), 0o600, "created")
        // A replacement must not inherit the umask either, even over a file someone widened.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try status.write(to: target)
        XCTAssertEqual(try mode(target), 0o600, "replaced")
        XCTAssertEqual(WorkerStatus.read(target)?.api_token, "synthetic-token")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["worker-status.json"], "no temporary left")
    }

    func testStatusDropsACLEntriesInheritedFromTheDirectory() throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,file_inherit", root.path]
        try chmod.run(); chmod.waitUntilExit()
        try XCTSkipUnless(chmod.terminationStatus == 0, "this volume does not take ACLs")
        let probe = root.appendingPathComponent("plain")
        try Data().write(to: probe)
        XCTAssertGreaterThan(aclEntries(probe), 0, "the directory's inheritable entry applies to a plain new file")

        let target = root.appendingPathComponent("worker-status.json")
        var status = WorkerStatus(); status.api_token = "synthetic-token"
        try status.write(to: target)
        XCTAssertEqual(aclEntries(target), 0)
        XCTAssertEqual(try mode(target), 0o600)
    }
}
