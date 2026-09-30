import Foundation
import Darwin

// Helper-process supervision shared by every worker slot. No app names inside:
// callers pass the exact bundled executables.

/// Restart after an unrequested worker exit: up to three attempts, 2/4/6 s apart.
/// `reset()` when the worker reaches ready, so a later crash starts again at 2 s.
public struct RestartPolicy: Equatable {
    public static let delays: [TimeInterval] = [2, 4, 6]
    public private(set) var failures = 0
    public init() {}
    /// Delay before the next restart, or nil once the attempts are used up (stay failed).
    public mutating func nextDelay() -> TimeInterval? {
        failures += 1
        return failures <= Self.delays.count ? Self.delays[failures - 1] : nil
    }
    public mutating func reset() { failures = 0 }
    public var exhausted: Bool { failures > Self.delays.count }
}

/// `Worker exited (code 9). <last lines>` for the orange header and its alert.
public func workerExitSummary(status: Int32, reason: Process.TerminationReason, logTail: String) -> String {
    let what = reason == .uncaughtSignal ? "signal \(status)" : "code \(status)"
    let tail = logTail.trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? "Worker exited (\(what))." : "Worker exited (\(what)). \(tail)"
}

/// The last `lines` non-empty lines of a log, reading at most the final 64 KiB.
public func logTail(_ url: URL, lines: Int = 3) -> String {
    guard lines > 0, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
}

/// Finds and stops helpers left behind by an earlier app instance.
///
/// Matching is by the running process's **executable file** (`proc_pidpath`, then
/// device + inode), never by command line: a shell or `tail` whose arguments merely
/// mention the helper path is not a helper and must survive.
public enum StraySweep {
    public struct Match: Equatable { public let pid: pid_t; public let parent: pid_t; public let path: String }

    /// Running processes whose executable is one of `executables`, excluding `except`.
    /// `orphansOnly` keeps only processes reparented to launchd (parent 1), so the live
    /// workers of another running instance are never touched.
    public static func matching(executables: [URL], except: Set<pid_t> = [], orphansOnly: Bool = true) -> [Match] {
        let targets = Set(executables.compactMap(FileIdentity.init))
        guard !targets.isEmpty else { return [] }
        let me = getpid()
        return allPIDs().compactMap { pid -> Match? in
            guard pid > 0, pid != me, !except.contains(pid), let path = executablePath(pid),
                let identity = FileIdentity(URL(fileURLWithPath: path)), targets.contains(identity)
            else { return nil }
            let parent = parentPID(pid) ?? 0
            if orphansOnly && parent != 1 { return nil }
            return Match(pid: pid, parent: parent, path: path)
        }
    }

    /// SIGTERM each match, SIGKILL survivors after `grace`; logs one line per process. Returns the pids stopped.
    @discardableResult
    public static func sweep(
        executables: [URL], except: Set<pid_t> = [], orphansOnly: Bool = true,
        grace: TimeInterval = 2, log: (String) -> Void = { _ in }
    ) -> [pid_t] {
        let found = matching(executables: executables, except: except, orphansOnly: orphansOnly)
        for process in found {
            log("Stopping stray helper pid \(process.pid) (parent \(process.parent)): \(process.path)")
            kill(process.pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(grace)
        var alive = found
        while !alive.isEmpty && Date() < deadline {
            usleep(50_000)
            alive = alive.filter { isSameProcess($0) }
        }
        for process in alive where isSameProcess(process) {
            log("Stray helper pid \(process.pid) ignored SIGTERM; sending SIGKILL")
            kill(process.pid, SIGKILL)
        }
        return found.map(\.pid)
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        return Array(pids.prefix(max(0, Int(filled))))
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }

    /// Still the same executable (guards against pid reuse between SIGTERM and SIGKILL).
    static func isSameProcess(_ process: Match) -> Bool {
        kill(process.pid, 0) == 0 && executablePath(process.pid) == process.path
    }
}

/// Device + inode: equal for the same file reached through symlinks or different path casing.
struct FileIdentity: Hashable {
    let device: dev_t, inode: ino_t
    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev; inode = info.st_ino
    }
}
