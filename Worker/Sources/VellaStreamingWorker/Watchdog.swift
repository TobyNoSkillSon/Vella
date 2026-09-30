import Foundation
import Darwin
import VellaWorkerSupport

/// A dispatch thread, never a POSIX signal handler, owns timeout serialization.
/// Terminating a wedged native operation must release the process, not run MLX
/// teardown concurrently with the operation. The parent verifies actual exit.
final class StreamingWatchdog {
    private let lock = NSLock()
    private let output: Int32
    private var identifier: String?
    private var deadline: Double = .infinity
    private let timer: DispatchSourceTimer
    private let termination: DispatchSourceSignal
    init(output: Int32) {
        self.output = output
        let queue = DispatchQueue(label: "VellaStreamingWatchdog")
        timer = DispatchSource.makeTimerSource(queue: queue)
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        timer.setEventHandler { [weak self] in self?.check() }
        termination.setEventHandler { [weak self] in self?.expire() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.resume(); termination.resume()
    }
    func arm() { lock.lock(); identifier = nil; deadline = ProcessInfo.processInfo.systemUptime + 120; lock.unlock() }
    func identify(_ value: String?) { lock.lock(); identifier = value; lock.unlock() }
    func disarm() { lock.lock(); deadline = .infinity; lock.unlock() }
    private func check() {
        lock.lock(); let expired = ProcessInfo.processInfo.systemUptime >= deadline; lock.unlock()
        if expired { expire() }
    }
    private func expire() {
        lock.lock()
        writeStreamingResponse(["id": identifier as Any? ?? NSNull(), "error": "Local streaming transcription failed."], to: output)
        _exit(0)
    }
    func write(_ reply: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        writeStreamingResponse(reply, to: output)
    }
    deinit { timer.cancel(); termination.cancel() }
}
/// One reply line (no JSON fragments); a failed write ends the process.
func writeStreamingResponse(_ response: [String: Any], to output: Int32) {
    guard let data = try? asciiJSONLine(response, fragmentsAllowed: false), writeAll(output, data) else { _exit(1) }
}
