import Foundation
import Darwin

/// Channel 2 of the Heimdall integration (docs/HEIMDALL.md): when Vella's dictation model is Parakeet v3 Ultra and
/// Heimdall holds the same model, a finished dictation's audio goes to Heimdall over a Unix socket instead of to a
/// copy of the model Vella would load itself. Anything that goes wrong falls back to Vella's own model.

/// `dev.heimdall.asr` userInfo.
public struct HeimdallAnnouncement: Equatable, Sendable {
    public enum State: String, Sendable { case ready, gone }
    public var state: State
    public var socket: String
    public var model: String
    public var pid: Int?
    public var sent: Double?
    /// The announcing edition's app ID (`HeimdallApp`).
    public var app: String?
    public init(state: State, socket: String, model: String, pid: Int? = nil, sent: Double? = nil, app: String? = HeimdallApp.personal) {
        self.state = state; self.socket = socket; self.model = model; self.pid = pid; self.sent = sent; self.app = app
    }
    /// Nil for another protocol version, an unknown state, or a `ready` without an absolute socket path.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo, (info["v"] as? NSNumber)?.intValue == HeimdallNames.protocolVersion,
            let raw = info["state"] as? String, let state = State(rawValue: raw)
        else { return nil }
        let socket = info["socket"] as? String ?? ""
        if state == .ready, !socket.hasPrefix("/") || socket.utf8.count >= 104 || (info["pid"] as? NSNumber) == nil { return nil }
        self.state = state; self.socket = socket
        model = info["model"] as? String ?? ""
        pid = (info["pid"] as? NSNumber)?.intValue
        sent = (info["sent"] as? NSNumber)?.doubleValue
        app = info["app"] as? String
        // A `ready` must name a known edition (its socket path and signing identity follow from it).
        if state == .ready, !HeimdallApp.bundleIdentifiers.contains(app ?? "") { return nil }
    }
}

/// Whether a dictation borrows Heimdall's model. Pure state; the app feeds it announcements and failures.
public struct HeimdallBorrowState: Equatable, Sendable {
    /// Each edition's last `ready` (a Mac can run the personal build and the public alpha side by side).
    public private(set) var readies: [String: HeimdallAnnouncement] = [:]
    /// The `ready` Vella uses: the personal edition's when both are ready, else the one that is (nil: absent, or gone).
    public var ready: HeimdallAnnouncement? { readies[HeimdallApp.personal] ?? readies[HeimdallApp.publicAlpha] }
    /// A request failed since that `ready`: Vella's own model serves until the next one.
    public private(set) var unavailable = false
    public private(set) var lastFailure: String?
    public init() {}
    public mutating func receive(_ announcement: HeimdallAnnouncement) {
        let app = announcement.app ?? HeimdallApp.personal
        let before = ready
        switch announcement.state {
        case .ready:
            readies[app] = announcement
        case .gone:
            // A `gone` from another Heimdall process must not end a newer one's readiness.
            if let pid = announcement.pid, let readyPid = readies[app]?.pid, pid != readyPid { return }
            readies[app] = nil
        }
        // A failure belongs to the Heimdall in use: a new `ready` from it, or a change to another one, clears it; the
        // other edition announcing leaves it standing.
        if (announcement.state == .ready && ready?.app == app) || before?.app != ready?.app || before?.pid != ready?.pid {
            unavailable = false
            if announcement.state == .ready { lastFailure = nil }
        }
    }
    /// A request to `announcement`'s Heimdall failed. A failure from an earlier Heimdall (it restarted and announced
    /// again while the request ran), or from the other edition, leaves the one in use available.
    public mutating func failed(_ reason: String, for announcement: HeimdallAnnouncement? = nil) {
        // Same Heimdall process and socket; a re-announcement (`sent` differs, e.g. a reply to a query) is the same one.
        if let announcement, announcement.pid != ready?.pid || announcement.socket != ready?.socket { return }
        if ready != nil { unavailable = true }
        lastFailure = reason
    }
    /// The socket to use for a dictation of `family`, or nil when Vella's own model serves it.
    public func socket(for family: String?) -> String? {
        guard let ready, !unavailable, family == HeimdallNames.sharedModel, ready.model == HeimdallNames.sharedModel else { return nil }
        return ready.socket
    }
    /// "ready", "unavailable" (failed since its last ready) or "absent".
    public var label: String { ready == nil ? "absent" : unavailable ? "unavailable" : "ready" }
}

/// A transcription Heimdall returned.
public struct HeimdallTranscript: Equatable, Sendable {
    public var text: String
    public var queueMs: Double?
    public var decodeMs: Double?
    public var audioMs: Double?
    public init(text: String, queueMs: Double? = nil, decodeMs: Double? = nil, audioMs: Double? = nil) {
        self.text = text; self.queueMs = queueMs; self.decodeMs = decodeMs; self.audioMs = audioMs
    }
}

/// Why a request to Heimdall did not produce text. Every case falls back to Vella's own model.
public enum HeimdallASRError: Error, Equatable, LocalizedError {
    case connect(String)
    case timeout
    case rejected(String)
    case invalidReply
    case cancelled
    public var errorDescription: String? { "Heimdall: " + code }
    /// Short machine form for status (`connect`, `timeout`, `busy`, `invalid_reply`…).
    public var code: String {
        switch self {
        case .connect: return "connect"
        case .timeout: return "timeout"
        case .rejected(let code): return code
        case .invalidReply: return "invalid_reply"
        case .cancelled: return "cancelled"
        }
    }
}

public enum HeimdallASRWire {
    /// The spec's reply deadline: 5 s plus a tenth of the audio length.
    public static func timeout(audioSeconds: Double) -> Double { 5 + max(0, audioSeconds) / 10 }
    /// Heimdall refuses more than this per request.
    public static let maxSeconds = 600.0
    public static func header(samples: Int, model: String = HeimdallNames.sharedModel) -> Data {
        let object: [String: Any] = ["v": 1, "op": "transcribe", "model": model, "rate": 16_000, "samples": samples, "format": "f32le"]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(10)
        return data
    }
    public static let statusRequest = Data("{\"op\":\"status\",\"v\":1}\n".utf8)
    /// f32le: one copy on a little-endian Mac (Apple silicon), a per-sample swap only on a big-endian one.
    public static func body(_ samples: [Float]) -> Data {
        if 1.littleEndian == 1 { return samples.withUnsafeBufferPointer { Data(buffer: $0) } }
        return Data(samples.flatMap { sample -> [UInt8] in withUnsafeBytes(of: sample.bitPattern.littleEndian) { Array($0) } })
    }
    /// The reply line (without its newline).
    public static func parse(_ line: Data) -> Result<HeimdallTranscript, HeimdallASRError> {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            (object["v"] as? NSNumber)?.intValue == HeimdallNames.protocolVersion, let ok = object["ok"] as? Bool
        else { return .failure(.invalidReply) }
        guard ok else {
            let code = object["error"] as? String ?? ""
            return .failure(.rejected(code.isEmpty ? "unavailable" : String(code.prefix(40))))
        }
        guard let text = object["text"] as? String else { return .failure(.invalidReply) }
        func ms(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        return .success(HeimdallTranscript(text: text, queueMs: ms("queue_ms"), decodeMs: ms("decode_ms"), audioMs: ms("audio_ms")))
    }
}

/// Mono 16 kHz samples from the canonical PCM16 or float32 WAV Vella writes for each recognition request.
public func heimdallWAVSamples(_ data: Data) throws -> [Float] {
    func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) } }
    func u16(_ at: Int) -> UInt16 { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self)) } }
    func tag(_ at: Int) -> String { String(decoding: data[data.startIndex + at..<data.startIndex + at + 4], as: UTF8.self) }
    let bad = VellaError.message("The recognition request is not a mono 16 kHz WAV.")
    guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw bad }
    var offset = 12, format: UInt16 = 0, channels: UInt16 = 0, rate: UInt32 = 0, bits: UInt16 = 0
    while offset + 8 <= data.count {
        let id = tag(offset), size = Int(u32(offset + 4)), body = offset + 8
        guard body + size <= data.count else { throw bad }
        if id == "fmt ", size >= 16 {
            format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
        } else if id == "data" {
            guard channels == 1, rate == 16_000 else { throw bad }
            let samples = data.withUnsafeBytes { raw -> [Float]? in
                if format == 1, bits == 16 {
                    return (0..<size / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: body + $0 * 2, as: Int16.self))) / 32768 }
                }
                if format == 3, bits == 32 {
                    return (0..<size / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: body + $0 * 4, as: UInt32.self))) }
                }
                return nil
            }
            guard let samples else { throw bad } // another sample format
            return samples
        }
        offset = body + size + (size & 1)
    }
    throw bad
}

/// One request per connection, as the spec says: the JSON header line, the raw audio, then one reply line. Blocking
/// POSIX I/O on a background thread with one overall deadline; cancellation is checked every 50 ms.
public enum HeimdallASRClient {
    /// `peer`: Heimdall's announced pid; the connected socket's peer must be that process.
    public static func transcribe(socket path: String, samples: [Float], timeout: Double? = nil, peer: Int32? = nil) async throws -> HeimdallTranscript {
        let seconds = Double(samples.count) / 16_000
        guard seconds <= HeimdallASRWire.maxSeconds else { throw HeimdallASRError.rejected("too_long") }
        var request = HeimdallASRWire.header(samples: samples.count)
        request.append(HeimdallASRWire.body(samples))
        let line = try await exchange(socket: path, request: request, timeout: timeout ?? HeimdallASRWire.timeout(audioSeconds: seconds), peer: peer)
        return try HeimdallASRWire.parse(line).get()
    }
    /// `{"op":"status"}`: whether Heimdall answers ok, within `timeout`.
    public static func status(socket path: String, timeout: Double = 1) async -> Bool {
        guard let line = try? await exchange(socket: path, request: HeimdallASRWire.statusRequest, timeout: timeout),
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return false }
        return object["ok"] as? Bool == true
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    public static func exchange(socket path: String, request: Data, timeout: Double, peer: Int32? = nil) async throws -> Data {
        let cancelled = Flag()
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let deadline = Date().timeIntervalSince1970 + timeout
                        continuation.resume(with: Result(catching: { try blockingExchange(path, request, deadline: deadline, peer: peer, cancelled: cancelled) }))
                    }
                }
            }, onCancel: { cancelled.set() })
    }

    private static func blockingExchange(_ path: String, _ request: Data, deadline: Double, peer: Int32?, cancelled: Flag) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HeimdallASRError.connect("socket") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw HeimdallASRError.connect("path") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw HeimdallASRError.connect(String(cString: strerror(errno))) }
            try wait(fd, POLLOUT, deadline: deadline, cancelled: cancelled)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { throw HeimdallASRError.connect(String(cString: strerror(error))) }
        }
        // The other end must run as this user.
        var credentials = xucred(), credentialsLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsLength) == 0, credentials.cr_uid == geteuid() else {
            throw HeimdallASRError.connect("peer")
        }
        if let peer {
            var pid: pid_t = 0, length = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid == peer else { throw HeimdallASRError.connect("peer") }
        }
        var sent = 0
        while sent < request.count {
            let n = request.withUnsafeBytes { send(fd, $0.baseAddress! + sent, request.count - sent, 0) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EAGAIN || errno == EINTR { try wait(fd, POLLOUT, deadline: deadline, cancelled: cancelled); continue }
            // Heimdall may refuse early (busy, too_long) and close: its reply can still be read below.
            break
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = reply.firstIndex(of: 10) { return reply.prefix(upTo: newline) }
            guard reply.count <= 1_000_000 else { throw HeimdallASRError.invalidReply }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
            if n > 0 { reply.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 {
                guard !reply.isEmpty else { throw sent < request.count ? HeimdallASRError.connect("closed") : HeimdallASRError.invalidReply }
                return reply // a reply without its newline, then close
            }
            guard errno == EAGAIN || errno == EINTR else { throw HeimdallASRError.connect(String(cString: strerror(errno))) }
            try wait(fd, POLLIN, deadline: deadline, cancelled: cancelled)
        }
    }
    private static func wait(_ fd: Int32, _ events: Int32, deadline: Double, cancelled: Flag) throws {
        while true {
            if cancelled.isSet { throw HeimdallASRError.cancelled }
            let remaining = deadline - Date().timeIntervalSince1970
            guard remaining > 0 else { throw HeimdallASRError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(50, max(1, remaining * 1000))))
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw HeimdallASRError.connect("poll") }
        }
    }
}

/// A `ready` socket Vella will send audio to: the spec's path, a Unix socket owned by this user and closed to others.
/// Anything else (another process announcing its own socket) is ignored.
public func heimdallSocketAcceptable(_ path: String, expected: String) -> Bool {
    guard path == expected else { return false }
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid() && info.st_mode & 0o077 == 0
}

// MARK: - Status

/// `heimdall` in worker-status.json and /status: what Vella knows about Heimdall's model.
public struct HeimdallStatus: Codable, Equatable, Sendable {
    /// "ready", "unavailable" (a request failed since its last ready) or "absent".
    public var state: String
    public var socket: String?
    public var model: String?
    public var pid: Int?
    /// The next dictation goes to Heimdall (its model is Vella's selected one and it is ready).
    public var borrowing: Bool
    /// Why the last request fell back (connect, timeout, busy, invalid_reply…).
    public var last_failure: String?
    /// The edition in use (`dev.heimdall.app`, or `com.tobynoskillson.heimdall` for Heimdall Alpha).
    public var app: String?
    public init(state: String, socket: String? = nil, model: String? = nil, pid: Int? = nil, borrowing: Bool, last_failure: String? = nil, app: String? = nil) {
        self.state = state; self.socket = socket; self.model = model; self.pid = pid; self.borrowing = borrowing; self.last_failure = last_failure; self.app = app
    }
}

/// `last_dictation`: which path served the latest finished dictation.
public struct LastDictationStatus: Codable, Equatable, Sendable {
    /// "heimdall", "vella", or "mixed" (some segments each, after a fallback).
    public var path: String
    public var model: String?
    public var at: Double
    /// Seconds from the end of recording to the final text.
    public var seconds: Double?
    public var audio_seconds: Double?
    /// Why Heimdall did not serve it all, when it was asked.
    public var fallback: String?
    public init(path: String, model: String? = nil, at: Double, seconds: Double? = nil, audio_seconds: Double? = nil, fallback: String? = nil) {
        self.path = path; self.model = model; self.at = at; self.seconds = seconds; self.audio_seconds = audio_seconds; self.fallback = fallback
    }
}
