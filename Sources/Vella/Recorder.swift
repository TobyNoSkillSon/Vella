import AVFoundation
import AudioToolbox
import CoreAudio
import VellaCore

// Capture callbacks own the file/converter on one serial queue, never the main actor.
final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let lock = NSLock()
    var frames: UInt64 = 0
    var level = 0.0
    var peakLevel = 0.0
    var peakRMS = 0.0
    var lastFramesAt = ProcessInfo.processInfo.systemUptime
    var error: Error?
    private var file: AVAudioFile?
    private var segmented: SegmentedPCMWriter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    // The converter may retain input pointers between output calls. Keep its most
    // recently supplied packet alive until it requests another one (or is released).
    private var converterInput: AVAudioPCMBuffer?
    init(url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }
    init(session: RecordingSession) throws {
        segmented = try SegmentedPCMWriter(session: session)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        consume(sampleBuffer)
    }
    func consume(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); let failed = error != nil; lock.unlock()
        guard !failed else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  stream.pointee.mSampleRate.isFinite, stream.pointee.mSampleRate > 0,
                  stream.pointee.mChannelsPerFrame > 0, stream.pointee.mFormatID == kAudioFormatLinearPCM else {
                throw VellaError.message("Microphone supplied an invalid or unsupported audio format.")
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            guard count > 0 else { return }
            guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw VellaError.message("Unsupported microphone PCM layout.") }
            source.frameLength = AVAudioFrameCount(count)
            let copy = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: source.mutableAudioBufferList)
            guard copy == noErr else { throw VellaError.message("Microphone sample copy failed (\(copy)).") }
            if converter?.inputFormat != format {
                try drainConverter()
                converter = AVAudioConverter(from: format, to: outputFormat)
                // Default conversion silently selects channel zero. Include all
                // input channels when reducing stereo/multichannel microphones to mono.
                converter?.downmix = true
            }
            guard let converter else { throw VellaError.message("Microphone audio conversion is unavailable.") }
            // A converter can satisfy a call entirely from buffered input, without
            // invoking its input block. Pump output until inputRanDry; never discard
            // this callback's source merely because the converter hasn't asked yet.
            let outputCapacity: AVAudioFrameCount = 4096
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { throw VellaError.message("Could not allocate converted microphone audio.") }
            var offset = 0
            let expectedOutput = ceil(Double(count) * 16_000 / format.sampleRate)
            guard expectedOutput.isFinite, expectedOutput <= Double(Int32.max) else { throw VellaError.message("Microphone audio buffer exceeds the conversion safety limit.") }
            let maximumCalls = Int(ceil(expectedOutput / Double(outputCapacity))) + 32
            var exhausted = false
            var inputPacket = converterInput
            for _ in 0..<maximumCalls {
                var conversionError: NSError?
                var inputError: Error?
                let status = converter.convert(to: converted, error: &conversionError) { requested, inputStatus in
                    guard offset < count else { inputStatus.pointee = .noDataNow; return nil }
                    let frames = min(Int(requested), min(4096, count - offset))
                    guard frames > 0,
                          let packet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                        inputError = VellaError.message("Could not allocate microphone conversion input.")
                        inputStatus.pointee = .noDataNow; return nil
                    }
                    packet.frameLength = AVAudioFrameCount(frames)
                    let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
                    let to = UnsafeMutableAudioBufferListPointer(packet.mutableAudioBufferList)
                    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                    for index in from.indices {
                        guard let sourceBytes = from[index].mData, let targetBytes = to[index].mData,
                              (offset + frames) * bytesPerFrame <= Int(from[index].mDataByteSize) else {
                            inputError = VellaError.message("Microphone conversion input has an invalid PCM layout.")
                            inputStatus.pointee = .noDataNow; return nil
                        }
                        targetBytes.copyMemory(from: sourceBytes.advanced(by: offset * bytesPerFrame), byteCount: frames * bytesPerFrame)
                    }
                    offset += frames
                    inputPacket = packet
                    inputStatus.pointee = .haveData; return packet
                }
                converterInput = inputPacket
                if let inputError { throw inputError }
                if let conversionError { throw conversionError }
                guard status != .error else { throw VellaError.message("Microphone audio conversion failed.") }
                try append(converted)
                if status == .inputRanDry || status == .endOfStream {
                    guard offset == count else { throw VellaError.message("Microphone converter left input unconsumed.") }
                    exhausted = true; break
                }
            }
            guard exhausted else { throw VellaError.message("Microphone converter did not consume its input within the safety limit.") }
        } catch { lock.lock(); self.error = error; lock.unlock() }
    }
    private func append(_ converted: AVAudioPCMBuffer) throws {
        guard converted.frameLength > 0 else { return }
        if let segmented, let samples = converted.floatChannelData?[0] {
            try segmented.append(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        } else if let file { try file.write(from: converted) }
        else { throw VellaError.message("Audio recording is already closed.") }
        var sum = 0.0
        if let samples = converted.floatChannelData?[0] {
            for i in 0..<Int(converted.frameLength) { let x = Double(samples[i]); sum += x*x }
        }
        let rms = sqrt(sum / Double(converted.frameLength))
        let measured = visualLevel(rms: rms)
        lock.lock(); frames += UInt64(converted.frameLength); level = measured; peakLevel = max(peakLevel, measured)
        peakRMS = max(peakRMS, rms); lastFramesAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    private func drainConverter() throws {
        guard let converter else { return }
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { throw VellaError.message("Could not finish audio conversion.") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if let error { throw error }
            guard status != .error else { throw VellaError.message("Could not finish audio conversion.") }
            try append(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        throw VellaError.message("Audio converter did not finish within its safety limit.")
    }
    func finish(userStopped: Bool = true) {
        finishAfterDraining(userStopped: userStopped) { try drainConverter() }
    }
    // Separate drain and journal finalization so a converter error cannot drop PCM
    // already accepted by the writer. Internal seam also permits isolated fault tests.
    func finishAfterDraining(userStopped: Bool, drain: () throws -> Void) {
        lock.lock(); var failure = error; lock.unlock()
        if failure == nil {
            do { try drain() } catch { failure = error }
        }
        do { try segmented?.finish(userStopped: userStopped && failure == nil) }
        catch { if failure == nil { failure = error } }
        lock.lock(); error = failure; lock.unlock()
        converter = nil; converterInput = nil; file = nil
    }
}

/// One-shot exclusive handoff: session configuration is frozen; sink access stays
/// on its capture queue. Recorder cannot start/discard/stop again until completion.
private struct CaptureDrain: @unchecked Sendable {
    let capture: AVCaptureSession?
    let sink: CaptureSink?
    let queue: DispatchQueue
    let userStopped: Bool
    func run() {
        capture?.stopRunning()
        queue.sync { sink?.finish(userStopped: userStopped) }
    }
}

@MainActor final class Recorder {
    private var isStopping = false
    private var session: AVCaptureSession?
    private var sink: CaptureSink?
    private let queue = DispatchQueue(label: "dev.vella.capture")
    private var captureDevice = ""
    private(set) var url: URL?
    private(set) var recordingSession: RecordingSession?
    func level() -> Double {
        guard let sink else { return 0 }
        sink.lock.lock(); defer { sink.lock.unlock() }; return sink.level
    }
    func captureFailure() -> String? {
        guard let session, let sink else { return "Microphone capture is not active." }
        sink.lock.lock(); let error = sink.error; let last = sink.lastFramesAt; sink.lock.unlock()
        if let error { return error.localizedDescription }
        if !session.isRunning { return "Microphone capture stopped. Check the connection and start again." }
        if ProcessInfo.processInfo.systemUptime - last > 3 { return "The microphone stopped delivering audio. Check its connection and start again." }
        return nil
    }
    func writeDiagnostics() {
        guard let sink else { return }
        sink.lock.lock()
        let state: [String: Any] = ["device": captureDevice, "frames": sink.frames,
            "seconds": Double(sink.frames) / 16_000, "level": sink.level, "peakLevel": sink.peakLevel, "peakRMS": sink.peakRMS,
            "error": sink.error?.localizedDescription ?? "", "engineRunning": session?.isRunning ?? false,
            "captureBackend": "AVCaptureSession", "checkedAt": ISO8601DateFormatter().string(from: Date())]
        sink.lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: Backend.support.appendingPathComponent("capture-status.json"), options: .atomic)
        }
    }
    static func devices() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout.size(ofValue: name))
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let name else { return nil }
            return Microphone(id: id, name: name.takeUnretainedValue() as String)
        }
    }
    func start(config: Configuration, recordingsRoot: URL? = nil) throws -> String {
        guard !isStopping else { throw VellaError.message("Capture is still being saved.") }
        discard()
        guard let chosen = selectMicrophone(Self.devices(), preferred: config.preferredMicrophone, fallback: config.fallbackMicrophone) else {
            throw VellaError.message("Neither the preferred microphone nor a MacBook microphone is available.")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        guard AudioObjectGetPropertyData(chosen.id, &address, 0, nil, &size, &uid) == noErr,
              let uid, let device = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == uid.takeUnretainedValue() as String }) else {
            throw VellaError.message("Could not open \(chosen.name) for audio capture.")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard let native = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription),
              native.pointee.mSampleRate.isFinite, native.pointee.mSampleRate > 0, native.pointee.mChannelsPerFrame > 0 else {
            throw VellaError.message("The microphone did not provide a valid sample rate and channel count.")
        }
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: native.pointee.mSampleRate, AVNumberOfChannelsKey: Int(native.pointee.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        let recording = try RecordingSession(root: recordingsRoot ?? RecordingSession.root, config: config)
        recordingSession = recording
        let sink = try CaptureSink(session: recording)
        self.url = recording.directory
        guard session.canAddInput(input), session.canAddOutput(output) else {
            discard(); throw VellaError.message("Could not configure \(chosen.name) for recording.")
        }
        session.beginConfiguration(); session.addInput(input); session.addOutput(output); session.commitConfiguration()
        output.setSampleBufferDelegate(sink, queue: queue)
        self.sink = sink; self.session = session; captureDevice = chosen.name
        session.startRunning()
        guard session.isRunning else { discard(); throw VellaError.message("Microphone capture did not start.") }
        return chosen.name
    }
    /// Caller retains exclusive ownership until completion (including cancellation).
    /// AVCaptureSession.stopRunning and disk flushes must not freeze the HUD.
    func stopAsync(userStopped: Bool = true) async throws -> URL {
        guard !isStopping else { throw VellaError.message("Capture is still being saved.") }
        isStopping = true
        defer { isStopping = false }
        let drain = CaptureDrain(capture: session, sink: sink, queue: queue, userStopped: userStopped)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                drain.run()
                continuation.resume()
            }
        }
        return try completeStop()
    }
    func stop(userStopped: Bool = true) throws -> URL {
        guard !isStopping else { throw VellaError.message("Capture is still being saved.") }
        session?.stopRunning()
        queue.sync { sink?.finish(userStopped: userStopped) } // Drain callbacks and the resampler tail, then close the WAV.
        return try completeStop()
    }
    private func completeStop() throws -> URL {
        writeDiagnostics()
        let frames = sink?.frames ?? 0
        let error = sink?.error
        session = nil; sink = nil
        if let error { throw error }
        guard frames > 0, let url else { throw VellaError.message("The microphone produced no audio. Check the selected microphone and its connection.") }
        return url
    }
    func discard() {
        guard !isStopping else { return } // The in-flight drain still owns these objects.
        session?.stopRunning(); queue.sync {}; session = nil; sink = nil
        // Session audio is never removed here: new recording, failure and quit are not deletion consent.
        url = nil; recordingSession = nil
    }
}
