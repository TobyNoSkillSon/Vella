import Foundation
import CryptoKit
import VellaCore

/// Private, durable PCM + atomic metadata. Raw float PCM remains recoverable even
/// if the process dies before a WAV header or the current segment is finalized.
final class RecordingSession {
    struct Segment: Codable, Equatable {
        var index: Int
        var frames: Int = 0
        var overlapFrames: Int = 0
        var peakRMS: Double = 0
        var finalized = false
        var text: String?
        var sha256: String?
        var quietSlices: Int?
        var filename: String { String(format: "%06d.pcm", index) }
        var seconds: Double { Double(max(0, frames - overlapFrames)) / 16_000 }
    }
    struct Manifest: Codable {
        var version = 1
        var created = Date()
        var config: Configuration
        var state = "recording"
        var userStopped = false
        var segments: [Segment] = []
    }
    let directory: URL
    var manifest: Manifest
    static var root: URL { Backend.support.appendingPathComponent("Recordings", isDirectory: true) }
    var seconds: Double { manifest.segments.reduce(0) { $0 + $1.seconds } }
    var transcriptURL: URL { directory.appendingPathComponent("transcript.txt") }
    init(root: URL, config: Configuration) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        manifest = Manifest(config: config)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try save()
    }
    init(directory: URL) throws {
        self.directory = directory
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        guard manifest.version == 1 else { throw VellaError.message("Unsupported saved recording version. Audio has not been changed.") }
        // Trust disk length over stale counters. Recover orphaned writes too.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Keep the previous first-match behavior for duplicate metadata without an
        // O(segment count) scan for every file. Journal format remains unchanged.
        let indexed = Dictionary(manifest.segments.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var recovered: [Segment] = []
        for file in files where file.pathExtension == "pcm" {
            try Task.checkCancellation()
            guard let index = Int(file.deletingPathExtension().lastPathComponent), index >= 0,
                  file.lastPathComponent == String(format: "%06d.pcm", index) else { continue }
            var segment = indexed[index] ?? Segment(index: index, peakRMS: 1)
            let bytes = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if segment.finalized, segment.frames != bytes / 4 {
                throw VellaError.message("A finalized audio segment changed length. Files were preserved for recovery.")
            }
            if let hash = segment.sha256, Self.digest(try Data(contentsOf: file)) != hash {
                throw VellaError.message("Saved audio integrity check failed. Files were preserved for recovery.")
            }
            segment.frames = bytes / 4
            segment.overlapFrames = min(segment.overlapFrames, segment.frames)
            // An unfinished segment's metering metadata may be stale: never call it silence.
            if !segment.finalized { segment.peakRMS = Self.peakRMS(try Data(contentsOf: file), range: 0..<segment.frames) }
            if segment.sha256 == nil { segment.sha256 = Self.digest(try Data(contentsOf: file)) }
            segment.finalized = true
            if segment.frames > segment.overlapFrames { recovered.append(segment) }
        }
        guard Set(manifest.segments.filter { $0.frames > $0.overlapFrames }.map(\.index)).isSubset(of: Set(recovered.map(\.index))) else {
            throw VellaError.message("A saved audio segment is missing. Remaining files were preserved; open Vella Files to recover them.")
        }
        manifest.segments = recovered.sorted { $0.index < $1.index }
        if manifest.state == "recording" { manifest.state = "interrupted" }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try durableWrite(encoder.encode(manifest), to: directory.appendingPathComponent("session.json"))
    }
    func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
    static func peakRMS(_ raw: Data, range: Range<Int>) -> Double {
        raw.withUnsafeBytes { bytes in
            var peak = 0.0
            for start in stride(from: range.lowerBound, to: range.upperBound, by: 320) {
                let end = min(start + 320, range.upperBound)
                var sum = 0.0
                for i in start..<end {
                    let value = Double(bytes.loadUnaligned(fromByteOffset: i * 4, as: Float.self))
                    if !value.isFinite { return Double.infinity }
                    sum += value * value
                }
                peak = max(peak, sqrt(sum / Double(end - start)))
            }
            return peak
        }
    }
    static func recover(_ directory: URL) async throws -> RecordingSession {
        let worker = Task.detached(priority: .userInitiated) { try RecordingSession(directory: directory) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func assemble(_ segments: [Segment]) throws -> String {
        guard segments.allSatisfy({ $0.text != nil }) else { throw VellaError.message("Some segments still need transcription. Audio is retained.") }
        var pieces: [String] = [], tail = ""
        for segment in segments {
            try Task.checkCancellation()
            let next = trimOverlap(tail, segment.text ?? "", overlaps: segment.overlapFrames > 0)
            if !next.isEmpty { pieces.append(next); tail = String((tail + " " + next).suffix(2048)) }
        }
        let text = pieces.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VellaError.message("No speech detected. Saved audio is still available.") }
        return text
    }
    @discardableResult func savePartialTranscript() throws -> String? {
        guard manifest.segments.contains(where: { !($0.text ?? "").isEmpty }) else { return nil }
        var pieces = ["[Incomplete transcript — retry missing audio segments]"]
        for segment in manifest.segments {
            if let text = segment.text { if !text.isEmpty { pieces.append(text) } }
            else { pieces.append("[Unrecognized audio — segment \(segment.index + 1)]") }
        }
        let text = pieces.joined(separator: "\n")
        try durableWrite(Data(text.utf8), to: directory.appendingPathComponent("partial-transcript.txt"))
        return text
    }
    func finalizeTranscript(_ text: String) throws -> String {
        try durableWrite(Data(text.utf8), to: transcriptURL)
        manifest.state = "transcribed"; try save(); return text
    }
    func complete() throws -> String { try finalizeTranscript(Self.assemble(manifest.segments)) }
    static func trimOverlap(_ left: String, _ right: String, overlaps: Bool) -> String {
        guard overlaps, !left.isEmpty, !right.isEmpty else { return right }
        let a = left.suffix(2048).split(whereSeparator: \.isWhitespace).map(String.init)
        var b = right.split(whereSeparator: \.isWhitespace).map(String.init)
        func word(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let limit = min(12, min(a.count, b.count))
        guard limit > 0 else { return right }
        let matches = (1...limit).filter { n in
            a.suffix(n).map(word) == b.prefix(n).map(word) && !b.prefix(n).map(word).contains("")
        }
        // Repeated words/phrases make alignment ambiguous. Preserve them rather than
        // guessing away genuine speech; a forced boundary may then contain repetition.
        if matches.count == 1, let n = matches.first { b.removeFirst(n) }
        return b.joined(separator: " ")
    }
    static func join(_ left: String, _ right: String, overlaps: Bool) -> String {
        let next = trimOverlap(left, right, overlaps: overlaps)
        return left.isEmpty ? next : left + (next.isEmpty ? "" : " " + next)
    }
    func wav(for segment: Segment, range: Range<Int>? = nil, paddingFrames: Int = 0) throws -> URL {
        let raw = try Data(contentsOf: directory.appendingPathComponent(segment.filename))
        guard raw.count / 4 == segment.frames, raw.count < 16_000 * 4 * 31 else {
            throw VellaError.message("Saved audio segment has an unexpected size. Original audio is preserved.")
        }
        if let hash = segment.sha256, Self.digest(raw) != hash { throw VellaError.message("Audio changed before transcription. Saved files were retained.") }
        // Keep lossless Float32 on disk, but send canonical signed PCM16. This
        // matches the calibration/backend input contract and avoids decoder-dependent
        // floating-WAV conversion. Transport quantization never changes saved audio.
        let range = range ?? 0..<segment.frames
        guard range.lowerBound >= 0, range.upperBound <= segment.frames, !range.isEmpty else { throw VellaError.message("Invalid audio slice. Original audio is retained.") }
        guard (0...8000).contains(paddingFrames) else { throw VellaError.message("Invalid request padding") }
        var pcm = [Int16](repeating: 0, count: paddingFrames); pcm.reserveCapacity(range.count + paddingFrames * 2)
        raw.withUnsafeBytes { bytes in
            for i in range {
                let sample = bytes.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
                pcm.append(Int16(max(-32767, min(32767, (sample.isFinite ? sample : 0) * 32767))))
            }
        }
        pcm.append(contentsOf: repeatElement(0, count: paddingFrames))
        let bytes = pcm.withUnsafeBytes { Data($0) }
        var data = Data()
        func ascii(_ s: String) { data.append(Data(s.utf8)) }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + bytes.count)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(bytes.count)); data.append(bytes)
        let url = directory.appendingPathComponent("request.wav")
        try durableWrite(data, to: url); return url
    }
    static func discover(root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Bounded audio buffering (20 ms analysis frames + 0.5 s overlap).
/// Only compact segment metadata grows with duration, not the audio in memory.
final class SegmentedPCMWriter {
    struct Policy {
        var preferredSeconds = 5.0
        var maximumSeconds = 25.0
        var silenceSeconds = 0.4
        var silenceRMS = 0.003
        var overlapSeconds = 0.5
        var reserveBytes: Int64 = 256 * 1024 * 1024
    }
    let session: RecordingSession
    let policy: Policy
    var availableBytes: () throws -> Int64
    var writeBytes: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    private var handle: FileHandle?
    private var pending: [Float] = []
    private var tail: [Float] = []
    private var quietFrames = 0
    private var sinceSync = 0
    private(set) var totalFrames = 0
    private var stopped = false
    init(session: RecordingSession, policy: Policy = Policy(), availableBytes: (() throws -> Int64)? = nil) throws {
        self.session = session; self.policy = policy
        self.availableBytes = availableBytes ?? {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: session.directory.path)
            return (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        guard policy.preferredSeconds > 0, policy.maximumSeconds >= policy.preferredSeconds,
              policy.maximumSeconds <= 30, policy.overlapSeconds < policy.preferredSeconds else {
            throw VellaError.message("Invalid recording segment policy.")
        }
        try checkSpace(); try open(overlap: [])
    }
    private func checkSpace() throws {
        guard try availableBytes() > policy.reserveBytes else { throw VellaError.message("Disk space is low. Recording stopped; saved audio was kept. Free space before continuing.") }
    }
    private func open(overlap: [Float]) throws {
        let index = (session.manifest.segments.last?.index ?? -1) + 1
        session.manifest.segments.append(.init(index: index, overlapFrames: overlap.count))
        try session.save() // Metadata first: an interrupted creation is recoverable.
        let url = session.directory.appendingPathComponent(session.manifest.segments.last!.filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VellaError.message("Could not create the next audio segment. Existing audio is retained.")
        }
        handle = try FileHandle(forWritingTo: url)
        if !overlap.isEmpty { try write(overlap) }
        quietFrames = 0
    }
    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !stopped else { throw VellaError.message("Recording writer is stopped.") }
        // Consume promptly, keeping at most one incomplete analysis frame.
        for sample in samples {
            pending.append(sample.isFinite ? sample : 0)
            if pending.count == 320 { let block = pending; pending.removeAll(keepingCapacity: true); try process(block) }
        }
    }
    private func write(_ block: [Float]) throws {
        guard let handle else { throw VellaError.message("Audio segment is not open.") }
        try block.withUnsafeBytes { try writeBytes(handle, Data($0)) }
        let i = session.manifest.segments.count - 1
        session.manifest.segments[i].frames += block.count
        let rms = sqrt(block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, block.count)))
        session.manifest.segments[i].peakRMS = max(session.manifest.segments[i].peakRMS, rms)
    }
    private func process(_ block: [Float]) throws {
        if sinceSync >= 16_000 { try checkSpace(); try handle?.synchronize(); sinceSync = 0 }
        try write(block); totalFrames += block.count; sinceSync += block.count
        let rms = sqrt(block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, block.count)))
        quietFrames = rms <= policy.silenceRMS ? quietFrames + block.count : 0
        tail.append(contentsOf: block)
        let overlapCount = Int(policy.overlapSeconds * 16_000)
        if tail.count > overlapCount { tail.removeFirst(tail.count - overlapCount) }
        let frames = session.manifest.segments.last!.frames
        let quiet = quietFrames >= Int(policy.silenceSeconds * 16_000)
        if (frames >= Int(policy.preferredSeconds * 16_000) && quiet) || frames >= Int(policy.maximumSeconds * 16_000) {
            try close()
            try open(overlap: quiet ? [] : tail)
        }
    }
    private func close() throws {
        try handle?.synchronize(); try handle?.close(); handle = nil
        if !session.manifest.segments.isEmpty {
            let i = session.manifest.segments.count - 1
            let raw = try Data(contentsOf: session.directory.appendingPathComponent(session.manifest.segments[i].filename))
            // A failed write may still have persisted complete samples. Disk is authoritative.
            session.manifest.segments[i].frames = raw.count / 4
            session.manifest.segments[i].sha256 = RecordingSession.digest(raw)
            session.manifest.segments[i].finalized = true
        }
        try session.save()
    }
    func finish(userStopped: Bool) throws {
        guard !stopped else { return }; stopped = true
        if !pending.isEmpty { let block = pending; pending.removeAll(); try write(block); totalFrames += block.count }
        try close()
        session.manifest.userStopped = userStopped
        session.manifest.state = userStopped ? "ready" : "interrupted"
        // A cut exactly at stop may leave an overlap-only/empty tail; it holds no new audio.
        // Keep metadata for overlap-only tails so recovery knows these are duplicates.
        try session.save()
    }
    deinit { try? handle?.synchronize(); try? handle?.close() }
}
