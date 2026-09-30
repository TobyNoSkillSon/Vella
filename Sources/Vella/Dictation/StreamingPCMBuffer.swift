import Foundation
import Darwin
import VellaCore

/// Capture never waits for inference. Overflow is an explicit recoverable failure,
/// not a dropped frame: the independent PCM journal remains authoritative.
final class StreamingPCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var closed = false
    private var failed = false
    private var frames = 0
    let capacity: Int
    init(capacity: Int = 2 * 1024 * 1024) { self.capacity = capacity }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !failed else { return }
        guard data.count % 4 == 0, bytes.count + data.count <= capacity else {
            failed = true; bytes.removeAll(); return
        }
        frames += data.count / 4; bytes.append(data)
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func abort() { lock.lock(); closed = true; failed = true; bytes.removeAll(); lock.unlock() }
    var totalFrames: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var isDrained: Bool { lock.lock(); defer { lock.unlock() }; return closed && bytes.isEmpty && !failed }
    func take() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw VellaError.message("Streaming could not keep up. Saved audio is retained; retry it after finishing.") }
        guard bytes.count >= 6400 || (closed && !bytes.isEmpty) else { return nil }
        let count = min(6400, bytes.count), result = Data(bytes.prefix(min(6400, bytes.count)))
        bytes.removeFirst(count); return result
    }
}
