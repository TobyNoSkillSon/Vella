import AppKit
import AVFoundation
import VellaCore

/// Lab-only measurement of a finished dictation through each path (docs/HEIMDALL.md): Vella's own model or Heimdall's
/// over its socket. Runs only in a QA-headless instance (`VELLA_QA_HEADLESS=1` with an absolute `VELLA_SUPPORT_DIR`),
/// which has no status item, shortcut or microphone, posts no dictation state, and inserts nothing (its pasteboard is
/// private).
///
///     --lab-dictate FILE.wav    audio to transcribe (any format AVAudioFile reads; converted to 16 kHz mono)
///     --lab-via own,heimdall    paths, interleaved each round: own, heimdall, or auto (the app's own choice)
///     --lab-rounds N            rounds (default 3; the first own round includes loading the model)
///     --lab-hold S              stay up S seconds after the last round (memory sampling), then quit
///     --lab-out FILE.jsonl      also append each result line here
///     --lab-socket PATH         treat PATH as Heimdall's ready socket (local only; nothing is broadcast), instead of
///                               waiting for Heimdall's own announcement
///
/// Each result is one JSON line on stdout: the path asked, the path that served, milliseconds from the end of the audio
/// (the saved recording handed to transcription, as Finish does) to the final text, the audio length and the text.
@MainActor enum LabDictation {
    static func requested(_ arguments: [String] = CommandLine.arguments) -> Bool { arguments.contains("--lab-dictate") }
    static func value(_ flag: String, _ arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.count > i + 1 else { return nil }
        return arguments[i + 1]
    }
    static func startIfRequested(delegate: AppDelegate, arguments: [String] = CommandLine.arguments) {
        guard requested(arguments), AppDelegate.qaHeadless() else { return }
        Task { @MainActor in
            await run(delegate: delegate, arguments: arguments)
            NSApp.terminate(nil)
        }
    }
    static func emit(_ object: [String: Any], to out: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let line = String(decoding: data, as: UTF8.self) + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        if let out {
            if let handle = FileHandle(forWritingAtPath: out) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
            } else {
                try? Data(line.utf8).write(to: URL(fileURLWithPath: out))
            }
        }
    }
    /// 16 kHz mono Float32.
    nonisolated static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw VellaError.message("Cannot read \(url.lastPathComponent).") }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw VellaError.message("Audio too long.") }
        var fed = false, failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let failure { throw failure }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func run(delegate: AppDelegate, arguments: [String]) async {
        let out = value("--lab-out", arguments)
        let vias = (value("--lab-via", arguments) ?? "own,heimdall").split(separator: ",").map { String($0) }
        let rounds = max(1, Int(value("--lab-rounds", arguments) ?? "3") ?? 3)
        let hold = Double(value("--lab-hold", arguments) ?? "0") ?? 0
        let model = delegate.model
        guard let path = value("--lab-dictate", arguments), let link = delegate.heimdall else {
            emit(["error": "usage: --lab-dictate FILE.wav (QA headless only)"], to: out); return
        }
        if let socket = value("--lab-socket", arguments) {
            link.receive(HeimdallAnnouncement(state: .ready, socket: socket, model: HeimdallNames.sharedModel))
        }
        do {
            let audio = try samples(URL(fileURLWithPath: path))
            // Let the runtime start and Heimdall answer the launch query.
            let until = ProcessInfo.processInfo.systemUptime + 3
            while link.borrow.ready == nil, vias.contains(where: { $0 != "own" }), ProcessInfo.processInfo.systemUptime < until {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            emit(
                [
                    "event": "lab_start", "audio_s": Double(audio.count) / 16_000, "heimdall": link.borrow.label,
                    "socket": link.borrow.ready?.socket ?? "", "vias": vias, "rounds": rounds, "pid": Int(getpid())
                ], to: out)
            var config = try model.backend.configuration(requiresModel: false)
            config.mode = .dictation
            let root = Backend.support.appendingPathComponent("LabRecordings", isDirectory: true)
            for round in 1...rounds {
                for via in vias {
                    link.labRoute = via == "auto" ? nil : HeimdallLink.Route(rawValue: via)
                    defer { link.labRoute = nil }
                    let session = try RecordingSession(root: root, config: config.model.isEmpty ? config : config.forRecording())
                    defer { try? FileManager.default.removeItem(at: session.directory) }
                    let writer = try SegmentedPCMWriter(session: session)
                    try audio.withUnsafeBufferPointer { try writer.append($0) }
                    try writer.finish(userStopped: true)
                    // Wait for the previous run's success flash to settle (it never blocks a new transcription).
                    let start = ProcessInfo.processInfo.systemUptime
                    guard model.labTranscribe(session) else {
                        emit(["round": round, "via": via, "error": "Vella was busy; round skipped"], to: out); continue
                    }
                    while model.phase == .transcribing || model.phase == .preparing { try await Task.sleep(nanoseconds: 1_000_000) }
                    let done = ProcessInfo.processInfo.systemUptime
                    let ms = (done - start) * 1000
                    let succeeded = model.phase == .success || model.phase == .idle
                    var line: [String: Any] = [
                        "round": round, "via": via, "served": model.lastRoute?.path ?? "none", "ms": NSDecimalNumber(string: String(format: "%.1f", ms)),
                        "audio_s": Double(audio.count) / 16_000, "phase": String(describing: model.phase), "text": succeeded ? model.lastText : ""
                    ]
                    if let fallback = model.lastRoute?.fallback { line["fallback"] = fallback }
                    line["requests"] = model.lastRoute?.requests ?? 0
                    if via != "own", let exchange = link.lastExchange {
                        line["exchange_ms"] = NSDecimalNumber(string: String(format: "%.1f", exchange.ms))
                        if let decode = exchange.decodeMs { line["heimdall_decode_ms"] = decode }
                        if let queue = exchange.queueMs { line["heimdall_queue_ms"] = queue }
                        // Vella's own work around the request: before it (reading the saved audio) and after (journal,
                        // transcript, insertion).
                        line["before_ms"] = NSDecimalNumber(string: String(format: "%.1f", (exchange.start - start) * 1000))
                        line["after_ms"] = NSDecimalNumber(string: String(format: "%.1f", (done - exchange.end) * 1000))
                    }
                    if model.phase == .failed { line["error"] = model.message }
                    emit(line, to: out)
                }
            }
        } catch {
            emit(["error": error.localizedDescription], to: out)
        }
        if hold > 0 {
            emit(["event": "holding", "seconds": hold, "pid": Int(getpid())], to: out)
            try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
        }
    }
}
