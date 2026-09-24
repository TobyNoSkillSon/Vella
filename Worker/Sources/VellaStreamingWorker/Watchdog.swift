import Foundation
import Darwin

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
func writeStreamingResponse(_ response: [String: Any], to output: Int32) {
    guard let json = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]),
          let string = String(data: json, encoding: .utf8) else { _exit(1) }
    var ascii = ""
    for unit in string.utf16 {
        if unit < 128 { ascii.append(Character(UnicodeScalar(unit)!)) }
        else { ascii += String(format: "\\u%04x", unit) }
    }
    let data = Data((ascii + "\n").utf8)
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n <= 0 { _exit(1) }; offset += n
        }
    }
}
