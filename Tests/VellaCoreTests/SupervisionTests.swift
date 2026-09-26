import XCTest
import Foundation
@testable import VellaCore

final class SupervisionTests: XCTestCase {
    func testRestartPolicyBacksOffThenGivesUpAndResets() {
        var policy = RestartPolicy()
        XCTAssertEqual(policy.nextDelay(), 2)
        XCTAssertEqual(policy.nextDelay(), 4)
        XCTAssertEqual(policy.nextDelay(), 6)
        XCTAssertFalse(policy.exhausted)
        XCTAssertNil(policy.nextDelay(), "fourth consecutive crash stays failed")
        XCTAssertTrue(policy.exhausted)
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 2, "ready resets the counter")
    }

    func testExitSummaryAndLogTail() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("vella-log-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        try "one\ntwo\n\nthree\nfour\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(logTail(log), "two\nthree\nfour")
        XCTAssertEqual(logTail(log.appendingPathExtension("missing")), "")
        XCTAssertEqual(workerExitSummary(status: 9, reason: .uncaughtSignal, logTail: logTail(log, lines: 1)), "Worker exited (signal 9). four")
        XCTAssertEqual(workerExitSummary(status: 1, reason: .exit, logTail: ""), "Worker exited (code 1).")
    }

    /// A copied executable stands in for a bundled helper. Only real processes of that
    /// file are matched: a shell whose command line mentions the path survives, and
    /// `orphansOnly` spares a helper whose parent is still alive.
    func testSweepMatchesExecutableFileNotCommandLine() throws {
        try Integration.require()   // compiles and runs a stand-in helper
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vella-sweep-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Copied system binaries are killed (platform arm64e), so build a tiny stand-in.
        let source = dir.appendingPathComponent("fake.c"), helper = dir.appendingPathComponent("FakeWorker")
        try "#include <unistd.h>\nint main(void){sleep(60);return 0;}\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        cc.arguments = ["clang", "-o", helper.path, source.path]
        try cc.run(); cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw XCTSkip("clang unavailable to build the stand-in helper") }

        // Orphan: the intermediate shell exits, so launchd adopts the helper.
        let spawn = Process()
        spawn.executableURL = URL(fileURLWithPath: "/bin/bash")
        spawn.arguments = ["-c", "'\(helper.path)' </dev/null >/dev/null 2>&1 & echo $!"]
        let out = Pipe(); spawn.standardOutput = out
        try spawn.run(); spawn.waitUntilExit()
        let orphan = try XCTUnwrap(pid_t(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(orphan, SIGKILL) }

        // Live child of this process: not an orphan.
        let child = Process(); child.executableURL = helper
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        // Decoy: its command line contains the helper path, its executable is bash.
        let decoy = Process(); decoy.executableURL = URL(fileURLWithPath: "/bin/bash")
        decoy.arguments = ["-c", "/bin/sleep 60; : '\(helper.path)'"]
        try decoy.run()
        defer { if decoy.isRunning { decoy.terminate() } }

        var waited = 0
        while StraySweep.parentPID(orphan) != 1 && waited < 40 { usleep(50_000); waited += 1 }
        XCTAssertEqual(StraySweep.parentPID(orphan), 1)

        let all = Set(StraySweep.matching(executables: [helper], orphansOnly: false).map(\.pid))
        XCTAssertEqual(all, [orphan, child.processIdentifier])

        var lines: [String] = []
        let stopped = StraySweep.sweep(executables: [helper], grace: 2) { lines.append($0) }
        XCTAssertEqual(stopped, [orphan])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("pid \(orphan)"))
        usleep(200_000)
        XCTAssertNotEqual(kill(orphan, 0), 0, "orphan helper stopped")
        XCTAssertTrue(child.isRunning, "a live instance's worker is untouched")
        XCTAssertTrue(decoy.isRunning, "a command line mentioning the path is not a helper")
        XCTAssertEqual(StraySweep.sweep(executables: [dir.appendingPathComponent("missing")]), [])
    }
}
