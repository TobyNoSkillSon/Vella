import Foundation
import Darwin

/// Heimdall's transcription socket (docs/HEIMDALL.md) for tests: one request per connection, a JSON header line, raw
/// f32le audio, then the configured reply. No model: `ok` answers fixed text.
public final class FakeHeimdallServer: @unchecked Sendable {
    public enum Reply: Sendable {
        case ok(String)
        /// `{"v":1,"ok":false,"error":CODE}`
        case error(String)
        /// A line that is not JSON.
        case garbage
        /// Read the request, then never answer (the client times out).
        case silence
        /// Read the request, then close without a reply (Heimdall quit mid-request).
        case close
    }
    public struct Request: Sendable {
        public var header: [String: String]
        public var samples: Int
        public var bytes: Int
        public var firstSample: Float?
    }
    public let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var reply: Reply
    private var received: [Request] = []
    private var stopped = false

    public init(reply: Reply, path fixed: String? = nil) throws {
        self.reply = reply
        // A client that hangs up early must not kill the test process when this server answers.
        signal(SIGPIPE, SIG_IGN)
        path = fixed ?? "/tmp/vh-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, b) in path.utf8.enumerated() { raw[i] = b } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { close(listener); throw NSError(domain: "FakeHeimdallServer", code: Int(errno)) }
        chmod(path, 0o600)
        let thread = Thread { [weak self] in self?.serve() }
        thread.start()
    }
    public func setReply(_ reply: Reply) { lock.lock(); self.reply = reply; lock.unlock() }
    public var requests: [Request] { lock.lock(); defer { lock.unlock() }; return received }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func stop() {
        lock.lock(); let was = stopped; stopped = true; lock.unlock()
        guard !was else { return }
        unlink(path)
    }
    deinit { stop() }

    private func serve() {
        while !isStopped {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            handle(client)
            close(client)
        }
        close(listener)
    }
    private func readByte(_ fd: Int32) -> UInt8? {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) == 1 ? byte : nil
    }
    private func handle(_ fd: Int32) {
        var line = Data()
        while let byte = readByte(fd), byte != 10 { line.append(byte) }
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        guard !line.isEmpty else { return } // the client left before sending (e.g. a peer check failed)
        let samples = (object["samples"] as? NSNumber)?.intValue ?? 0
        var body = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while body.count < samples * 4 {
            let n = recv(fd, &chunk, min(chunk.count, samples * 4 - body.count), 0)
            guard n > 0 else { break }
            body.append(contentsOf: chunk[0..<n])
        }
        let first: Float? = body.count >= 4 ? body.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) } : nil
        lock.lock()
        received.append(Request(header: object.mapValues { "\($0)" }, samples: samples, bytes: body.count, firstSample: first))
        let reply = self.reply
        lock.unlock()
        func send(_ text: String) {
            let data = Array((text + "\n").utf8)
            _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, data.count, 0) }
        }
        switch reply {
        case .ok(let text):
            let escaped = String(decoding: (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data(), as: UTF8.self).dropFirst().dropLast()
            if object["op"] as? String == "status" { send(#"{"v":1,"ok":true}"#) } else {
                send(#"{"v":1,"ok":true,"text":\#(escaped),"queue_ms":1,"decode_ms":2,"audio_ms":\#(samples / 16)}"#)
            }
        case .error(let code): send(#"{"v":1,"ok":false,"error":"\#(code)"}"#)
        case .garbage: send("this is not json")
        case .silence:
            // Hold the connection until the client gives up and closes it (or the server stops).
            while !isStopped {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 50) > 0 { if readByte(fd) == nil { return } }
            }
        case .close: return
        }
    }
}
