import XCTest
import AVFoundation
@testable import Vella

final class CaptureTests: XCTestCase {
    func testConvertsRepeatedStereoCaptureBuffersAndUpdatesMeter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try CaptureSink(url: url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        pcm.frameLength = 4800
        for c in 0..<2 { for i in 0..<4800 { pcm.floatChannelData![c][i] = Float(sin(Double(i) * .pi / 24) * 0.1) } }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: 4800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let buffer = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        for _ in 0..<5 { sink.consume(buffer) }
        XCTAssertNil(sink.error)
        XCTAssertGreaterThan(sink.frames, 7500)
        XCTAssertGreaterThan(sink.peakLevel, 0.5)
        XCTAssertGreaterThan(sink.level, 0.5)
    }
    func testShureHighAligned24BitStereoAmplitude() throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 24, mReserved: 0)
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        for channel in [0, 1] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-shure-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let sink = try CaptureSink(url: url)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            pcm.frameLength = 4800
            let samples = try XCTUnwrap(pcm.mutableAudioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Int32.self)
            for i in 0..<4800 { for c in 0..<2 { samples[i*2+c] = c == channel ? (Int32(sin(Double(i) * .pi / 24)*0.1*8388607) << 8) : 0 } }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: 4800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let buffer = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
            sink.consume(buffer)
            XCTAssertNil(sink.error)
            XCTAssertGreaterThan(sink.level, 0.45, "Channel \(channel) must survive mono conversion at usable amplitude")
        }
    }
    @MainActor func testRightChannelSpeechThroughCaptureWAVAndBackend() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELLA_TEST_CAPTURE_AUDIO"] else { throw XCTSkip("Opt-in synthetic speech through capture and local backend") }
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(input.processingFormat.sampleRate, 48000)
        let speech = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: speech)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-pipeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend()
        defer { backend.shutdown() }
        let session = try RecordingSession(root: root, config: backend.configuration())
        var sink: CaptureSink? = try CaptureSink(session: session)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 24, mReserved: 0)
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        for start in stride(from: 0, to: Int(speech.frameLength), by: 4096) {
            let count = min(4096, Int(speech.frameLength) - start)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = AVAudioFrameCount(count)
            let samples = pcm.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Int32.self)
            for i in 0..<count { samples[i*2] = 0; samples[i*2+1] = Int32(max(-1, min(1, speech.floatChannelData![0][start+i])) * 8388607) << 8 }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(start), timescale: 48000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let buffer = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
            sink?.consume(buffer)
        }
        XCTAssertNil(sink?.error)
        XCTAssertGreaterThan(sink?.peakLevel ?? 0, 0.4)
        sink?.finish()
        sink = nil
        // Use the production journal → bounded PCM16 WAV export, not the old
        // Float32 direct-file transport that predates the private worker.
        let url = try session.wav(for: XCTUnwrap(session.manifest.segments.first))
        let recorded = try AVAudioFile(forReading: url)
        XCTAssertEqual(recorded.processingFormat.sampleRate, 16000)
        XCTAssertEqual(recorded.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(recorded.length), Double(speech.frameLength)/3, accuracy: 40)
        let transcriber = SessionTranscriber { file, config in try await backend.transcribe(file, config: config) }
        let text = try await transcriber.run(session)
        XCTAssertTrue(text.lowercased().contains("dictation"))
        XCTAssertEqual(backend.ownership, "Vella private worker")
        backend.stop()
    }
    func testRatesChannelsAndLayouts() throws {
        for rate in [8000.0, 16000.0, 44100.0, 48000.0, 96000.0] {
            for channels: AVAudioChannelCount in [1, 2, 4] {
                for interleaved in [false, true] {
                    let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Quadraphonic))
                    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout))
                    let count = Int(rate / 10)
                    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                    pcm.frameLength = AVAudioFrameCount(count)
                    for i in 0..<count { for c in 0..<Int(channels) {
                        let sample = c == Int(channels)-1 ? Float(sin(Double(i)*2 * .pi * 1000/rate)*0.3) : 0
                        if interleaved { pcm.floatChannelData![0][i*Int(channels)+c] = sample }
                        else { pcm.floatChannelData![c][i] = sample }
                    } }
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
                    let buffer = try XCTUnwrap(sample)
                    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-matrix-\(UUID()).wav")
                    defer { try? FileManager.default.removeItem(at: url) }
                    let sink = try CaptureSink(url: url); sink.consume(buffer); sink.finish()
                    XCTAssertNil(sink.error, "\(rate) Hz / \(channels) channels / interleaved=\(interleaved)")
                    XCTAssertGreaterThan(sink.peakRMS, 0.015, "Last channel lost: \(rate) Hz / \(channels) / \(interleaved)")
                    XCTAssertEqual(Double(sink.frames), 1600, accuracy: 2)
                }
            }
        }
    }
}
