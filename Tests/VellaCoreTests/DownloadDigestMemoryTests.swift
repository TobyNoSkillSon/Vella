import XCTest
import CryptoKit
import Darwin
@testable import VellaCore

/// Review 1 regressions in VellaCore (lab/notes/REVIEW.md).
final class Review1CoreTests: XCTestCase {
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
    }

    /// R12: verifying a large download from an async task must not keep the file's bytes alive until the task ends.
    /// A disposable sparse file (no real weights), hashed on the real download-verification path, both identities.
    func testR12DownloadDigestKeepsPeakFootprintBoundedAndDigestsMatch() async throws {
        let size = 768 * 1024 * 1024
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vella-r12-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size)); try handle.close()

        // Expected identities from in-memory zero chunks (no file reads).
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        sha1.update(data: Data("blob \(size)\0".utf8))
        let chunk = Data(count: 8 * 1024 * 1024)
        for _ in 0..<(size / chunk.count) { sha256.update(data: chunk); sha1.update(data: chunk) }
        let lfs = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        let blob = sha1.finalize().map { String(format: "%02x", $0) }.joined()

        for etag in [lfs, blob] {
            // Measured inside the task, before it ends: that is where unpooled autoreleased reads would still be alive.
            let (matched, growth) = try await Task.detached { () throws -> (Bool, Double) in
                let before = Self.footprintMB()
                let matched = try NativeModelDownload.digest(file, size: Int64(size), etag: etag)
                return (matched, Self.footprintMB() - before)
            }.value
            XCTAssertTrue(matched, "digest \(etag.count == 64 ? "SHA-256" : "SHA-1")")
            XCTAssertLessThan(growth, 128, "footprint grew \(Int(growth)) MB hashing a 768 MB file")
        }
    }
}
