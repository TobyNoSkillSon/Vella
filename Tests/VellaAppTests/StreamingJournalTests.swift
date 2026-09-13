import XCTest
@testable import Vella

final class StreamingJournalTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vella-journal-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func add(_ text: String, to directory: URL) throws {
        let file = try FileHandle(forWritingTo: directory.appendingPathComponent(StreamingJournal.filename))
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data(text.utf8)); try file.synchronize()
    }
    func testEndpointsReplacePartialAndPreserveUnicode() throws {
        let d = try directory(), j = try StreamingJournal(directory: d)
        try j.append(committed: "", partial: "outdated", frames: 0)
        try j.append(committed: "Hello 🐈", partial: "provisional", frames: 1600)
        try j.append(committed: "world", partial: "", frames: 1600)
        try j.append(committed: "", partial: "ending", frames: 1631)
        XCTAssertEqual(try StreamingJournal.recover(directory: d), StreamingJournal.incompletePrefix + "Hello 🐈 world ending")
        j.close(); j.close()
        XCTAssertThrowsError(try j.append(committed: "", partial: "", frames: 1631))
    }
    func testCrashAndTruncatedTail() throws {
        let d = try directory()
        do { let j = try StreamingJournal(directory: d); try j.append(committed: "Saved", partial: "tail", frames: 1) }
        try add("{\"committed\":\"lost", to: d)
        XCTAssertEqual(try StreamingJournal.recover(directory: d), StreamingJournal.incompletePrefix + "Saved tail")
        // Even an unbounded corrupt unterminated tail uses a bounded parser buffer.
        try add(String(repeating: "x", count: 200_000), to: d)
        XCTAssertEqual(try StreamingJournal.recover(directory: d), StreamingJournal.incompletePrefix + "Saved tail")
        try add("\n", to: d)
        XCTAssertThrowsError(try StreamingJournal.recover(directory: d))
    }
    func testCompleteCorruptionFailsClosed() throws {
        for line in ["not json\n", "\n", "{}\n", "{\"committed\":\"x\",\"partial\":\"\",\"frames\":-1}\n",
                     "{\"committed\":\"x\",\"partial\":\"\",\"frames\":1}\n"] {
            let d = try directory(), j = try StreamingJournal(directory: d)
            try j.append(committed: "valid", partial: "", frames: 2); j.close()
            try add(line, to: d)
            XCTAssertThrowsError(try StreamingJournal.recover(directory: d))
        }
    }
    func testOverflowAndFrameValidationDoNotWrite() throws {
        let d = try directory(), j = try StreamingJournal(directory: d)
        let path = d.appendingPathComponent(StreamingJournal.filename)
        try j.append(committed: "stable", partial: "", frames: 10)
        let before = try Data(contentsOf: path)
        XCTAssertThrowsError(try j.append(committed: String(repeating: "x", count: 65_536), partial: "", frames: 11))
        XCTAssertThrowsError(try j.append(committed: String(repeating: "\0", count: 12_000), partial: "", frames: 11))
        XCTAssertThrowsError(try j.append(committed: "", partial: "", frames: 9))
        XCTAssertEqual(try Data(contentsOf: path), before)
        try j.append(committed: "", partial: "ok", frames: 10)
    }
    func testEmptyArchiveAndPermissions() throws {
        let d = try directory()
        XCTAssertNil(try StreamingJournal.recover(directory: d))
        try StreamingJournal.archiveForRetry(directory: d)
        let j = try StreamingJournal(directory: d)
        XCTAssertNil(try StreamingJournal.recover(directory: d))
        XCTAssertThrowsError(try StreamingJournal(directory: d))
        try j.append(committed: "public fixture", partial: "", frames: 42); j.close()
        let path = d.appendingPathComponent(StreamingJournal.filename)
        let original = try Data(contentsOf: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try StreamingJournal.archiveForRetry(directory: d)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let archived = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: archived), original)
        let next = try StreamingJournal(directory: d)
        try next.append(committed: "retry only", partial: "", frames: 1)
        XCTAssertEqual(try StreamingJournal.recover(directory: d), StreamingJournal.incompletePrefix + "retry only")
    }
    func testExactLineLimitAndNonregularFiles() throws {
        let d = try directory(), j = try StreamingJournal(directory: d)
        let path = d.appendingPathComponent(StreamingJournal.filename)
        try j.append(committed: "", partial: "", frames: 0)
        let overhead = try Data(contentsOf: path).count
        try j.append(committed: String(repeating: "a", count: StreamingJournal.maximumLineBytes - overhead), partial: "", frames: 0)
        XCTAssertEqual(try Data(contentsOf: path).count, overhead + StreamingJournal.maximumLineBytes)
        XCTAssertNotNil(try StreamingJournal.recover(directory: d))
        XCTAssertThrowsError(try j.append(committed: String(repeating: "a", count: StreamingJournal.maximumLineBytes - overhead + 1), partial: "", frames: 0))
        j.close()
        let linked = try directory()
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(StreamingJournal.filename), withDestinationURL: path)
        XCTAssertThrowsError(try StreamingJournal.recover(directory: linked))
        XCTAssertThrowsError(try StreamingJournal(directory: linked))
    }
    func testThreeHoursOfBoundedUpdatesRecoverExactly() throws {
        let d = try directory(), j = try StreamingJournal(directory: d)
        var expected: [String] = [], partial: [String] = []
        for index in 0..<21_600 { // Two updates/second for three hours, accelerated.
            let word = "fixture\(index % 31)"
            expected.append(word); partial.append(word)
            let drain = partial.count == 200
            try j.append(committed: drain ? partial.joined(separator: " ") : "",
                         partial: drain ? "" : partial.joined(separator: " "), frames: (index + 1) * 8000)
            if drain { partial.removeAll(keepingCapacity: true) }
        }
        j.close()
        XCTAssertEqual(try StreamingJournal.recover(directory: d), StreamingJournal.incompletePrefix + expected.joined(separator: " "))
        let data = try Data(contentsOf: d.appendingPathComponent(StreamingJournal.filename))
        XCTAssertEqual(data.split(separator: 10).count, 21_600)
        XCTAssertTrue(data.split(separator: 10).allSatisfy { $0.count + 1 <= StreamingJournal.maximumLineBytes })
    }
}
