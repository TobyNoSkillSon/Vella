import Foundation
import Darwin

/// Single-owner append-only checkpoints. Never retains or reconstructs transcript history
/// on append. Close before archiving; existing journals must be recovered/archived, not reused.
final class StreamingJournal {
    static let filename = "streaming-events.jsonl"
    static let maximumLineBytes = 65_536 // Includes the commit newline.
    static let incompletePrefix = "[Incomplete streaming transcript — retry saved audio]\n"
    enum Failure: Error { case system(Int32), invalidEvent, oversizedEvent, closed }
    private struct Event: Codable {
        let committed: String
        let partial: String
        let frames: Int
    }
    private var fd: Int32 = -1
    private var lastFrames = 0

    init(directory: URL) throws {
        let path = directory.appendingPathComponent(Self.filename).path
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.system(errno) }
        do { try Self.syncDirectory(directory) }
        catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    func append(committed: String, partial: String, frames: Int) throws {
        guard fd >= 0 else { throw Failure.closed }
        guard frames >= lastFrames, frames >= 0 else { throw Failure.invalidEvent }
        // Bound even the encoder allocation; escaping can expand a valid input, so
        // check the encoded record too. No truncation of recognized text is allowed.
        guard committed.utf8.count < Self.maximumLineBytes,
              partial.utf8.count < Self.maximumLineBytes else { throw Failure.oversizedEvent }
        var bytes = try JSONEncoder().encode(Event(committed: committed, partial: partial, frames: frames))
        guard bytes.count < Self.maximumLineBytes else { throw Failure.oversizedEvent }
        bytes.append(10)
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw Failure.system(n < 0 ? errno : EIO) }
                    offset += n
                }
            }
            try Self.sync(fd)
            lastFrames = frames
        } catch {
            // A failed write may have left a torn tail. Never append beyond it.
            close(); throw error
        }
    }
    static func recover(directory: URL) throws -> String? {
        let fd = Darwin.open(directory.appendingPathComponent(filename).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw Failure.system(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.system(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidEvent }
        var chunk = [UInt8](repeating: 0, count: 8192), line = Data()
        var oversized = false, previousFrames = 0, pieces: [String] = [], partial = ""
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Failure.system(errno) }
            if n == 0 { break } // Ignore ONLY the unterminated final record.
            for byte in chunk.prefix(n) {
                if byte == 10 {
                    guard !oversized else { throw Failure.oversizedEvent }
                    let event: Event
                    do { event = try JSONDecoder().decode(Event.self, from: line) }
                    catch { throw Failure.invalidEvent }
                    guard event.frames >= 0, event.frames >= previousFrames else { throw Failure.invalidEvent }
                    previousFrames = event.frames
                    let committed = event.committed.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !committed.isEmpty { pieces.append(committed) }
                    partial = event.partial.trimmingCharacters(in: .whitespacesAndNewlines)
                    line.removeAll(keepingCapacity: true)
                } else if !oversized {
                    if line.count >= maximumLineBytes - 1 { oversized = true; line.removeAll(keepingCapacity: true) }
                    else { line.append(byte) }
                }
            }
        }
        if !partial.isEmpty { pieces.append(partial) }
        return pieces.isEmpty ? nil : incompletePrefix + pieces.joined(separator: " ")
    }
    /// Same-directory atomic rename retains even a corrupt/torn journal for inspection.
    /// Caller must close the writer first. Missing current file is an idempotent no-op.
    static func archiveForRetry(directory: URL) throws {
        let source = directory.appendingPathComponent(filename).path
        let target = directory.appendingPathComponent("streaming-events-\(UUID().uuidString).jsonl").path
        if Darwin.rename(source, target) != 0 {
            if errno == ENOENT { return }
            throw Failure.system(errno)
        }
        try syncDirectory(directory)
    }
    private static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 { if errno != EINTR { throw Failure.system(errno) } }
    }
    private static func syncDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.system(errno) }
        defer { Darwin.close(fd) }
        try sync(fd)
    }
}
