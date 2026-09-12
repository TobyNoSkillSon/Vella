import XCTest
import AVFoundation
import CryptoKit
import VellaCore
@testable import Vella

final class CaptureRegressionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-regression-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sample(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var value: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription, sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &value), noErr)
        let result = try XCTUnwrap(value)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        return result
    }
    private func bytes(_ pcm: AVAudioPCMBuffer) -> Data {
        Data(bytes: pcm.floatChannelData![0], count: Int(pcm.frameLength) * 4)
    }
    private func saved(_ record: RecordingSession) throws -> Data {
        let restored = try RecordingSession(directory: record.directory)
        var data = Data()
        for segment in restored.manifest.segments {
            data.append(try Data(contentsOf: restored.directory.appendingPathComponent(segment.filename)).dropFirst(segment.overlapFrames * 4))
        }
        return data
    }
    func testNativeMonoFloatCaptureIsSampleExactAcrossVariableBuffers() throws {
        let record = try RecordingSession(root: root(), config: Configuration(executable: "/unused", model: "/unused"))
        let sink = try CaptureSink(session: record)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        var expected = Data()
        for count in [4096, 4096, 17, 8000, 333, 4096] {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { pcm.floatChannelData![0][i] = Float(sin(Double(expected.count / 4 + i) * 0.071) * 0.2) }
            expected.append(bytes(pcm))
            sink.consume(try sample(pcm))
        }
        sink.finish()
        XCTAssertNil(sink.error)
        let actual = try saved(record)
        print("Native capture: expected \(expected.count / 4), actual \(actual.count / 4) frames")
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(SHA256.hash(data: actual), SHA256.hash(data: expected))
    }
    func testCorpusReplayAcrossSegmentBoundaryPreservesEveryFloatSample() throws {
        struct Manifest: Decodable { struct Clip: Decodable { let file: String }; let clips: [Clip] }
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Benchmarks/english-formatted-20m-v1")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
        let record = try RecordingSession(root: root(), config: Configuration(executable: "/unused", model: "/unused"))
        let sink = try CaptureSink(session: record)
        var expected = Data()
        // Replay three short clips twice (32.61 seconds), crossing a real writer cut.
        let clips = Array(manifest.clips.prefix(3))
        for clip in clips + clips {
            let file = try AVAudioFile(forReading: resources.appendingPathComponent(clip.file))
            XCTAssertEqual(file.processingFormat.sampleRate, 16000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            let start = expected.count / 4, actualStart = sink.frames
            while file.framePosition < file.length {
                try file.read(into: pcm, frameCount: 4096)
                guard pcm.frameLength > 0 else { break }
                let value = try sample(pcm)
                // Independently validate the same CMSampleBuffer fixture construction as the hour test.
                let copied = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(value)!), frameCapacity: pcm.frameLength))
                copied.frameLength = pcm.frameLength
                XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(value, at: 0, frameCount: Int32(pcm.frameLength), into: copied.mutableAudioBufferList), noErr)
                XCTAssertEqual(bytes(copied), bytes(pcm), "Fixture must carry the original PCM bytes")
                expected.append(bytes(pcm)); sink.consume(value)
            }
            print("Corpus capture \(clip.file): source \(expected.count / 4 - start), captured \(sink.frames - actualStart)")
            let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000))
            silence.frameLength = 8000; silence.floatChannelData![0].update(repeating: 0, count: 8000)
            expected.append(bytes(silence)); sink.consume(try sample(silence))
        }
        sink.finish()
        XCTAssertNil(sink.error)
        let actual = try saved(record)
        XCTAssertGreaterThanOrEqual(record.manifest.segments.filter { $0.frames > $0.overlapFrames }.count, 2)
        let first = try XCTUnwrap(record.manifest.segments.first)
        let wav = try AVAudioFile(forReading: record.wav(for: first))
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: 4096))
        var decodedBytes = Data()
        while wav.framePosition < wav.length {
            try wav.read(into: decoded, frameCount: 4096)
            guard decoded.frameLength > 0 else { break }
            decodedBytes.append(bytes(decoded))
        }
        print("Request WAV decoded \(decodedBytes.count / 4) frames, declared \(wav.length), PCM \(first.frames)")
        let raw = try Data(contentsOf: record.directory.appendingPathComponent(first.filename))
        XCTAssertEqual(decodedBytes.count, raw.count)
        let maximumError = raw.withUnsafeBytes { original in decodedBytes.withUnsafeBytes { decoded in
            (0..<(raw.count / 4)).reduce(Float(0)) { max($0, abs(original.loadUnaligned(fromByteOffset: $1 * 4, as: Float.self) - decoded.loadUnaligned(fromByteOffset: $1 * 4, as: Float.self))) }
        } }
        XCTAssertLessThanOrEqual(maximumError, 2 / 32768, "Only bounded PCM16 transport quantization; the saved Float32 archive remains byte-exact")
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(SHA256.hash(data: actual), SHA256.hash(data: expected))
    }
    func testResamplingIsIndependentOfInputBufferPartitioning() throws {
        for rate in [8000.0, 44100.0, 48000.0, 96000.0] {
            for interleaved in [false, true] {
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: interleaved))
                let total = Int(rate * 0.7) + 37
                func capture(partitions: [Int]) throws -> Data {
                    let url = try root().appendingPathComponent("capture.wav")
                    let sink = try CaptureSink(url: url)
                    var offset = 0, partition = 0
                    while offset < total {
                        let count = min(partitions[partition % partitions.count], total - offset)
                        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                        pcm.frameLength = AVAudioFrameCount(count)
                        for i in 0..<count {
                            for channel in 0..<2 {
                                let value = channel == 0 ? Float(0) : Float(sin(Double(offset + i) * 2 * .pi * 440 / rate) * 0.2)
                                if interleaved { pcm.floatChannelData![0][i * 2 + channel] = value }
                                else { pcm.floatChannelData![channel][i] = value }
                            }
                        }
                        sink.consume(try sample(pcm)); offset += count; partition += 1
                    }
                    sink.finish(); XCTAssertNil(sink.error)
                    let file = try AVAudioFile(forReading: url)
                    XCTAssertEqual(Double(file.length), Double(total) * 16000 / rate, accuracy: 2)
                    let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                    try file.read(into: output)
                    return bytes(output)
                }
                let whole = try capture(partitions: [total])
                let fragmented = try capture(partitions: [17, 4096, 333, 8000, 61])
                XCTAssertEqual(SHA256.hash(data: whole), SHA256.hash(data: fragmented), "Partition-dependent conversion at \(rate), interleaved=\(interleaved)")
            }
        }
    }
    func testDrainFailureStillFinalizesPendingPCMAndPreservesFirstError() throws {
        enum Failure: Error { case drain, priorCapture }
        for priorFailure in [false, true] {
            let record = try RecordingSession(root: root(), config: Configuration(executable: "/unused", model: "/unused"))
            let sink = try CaptureSink(session: record)
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 17))
            pcm.frameLength = 17; pcm.floatChannelData![0].update(repeating: 0.2, count: 17)
            sink.consume(try sample(pcm))
            if priorFailure { sink.error = Failure.priorCapture }
            var drained = false
            sink.finishAfterDraining(userStopped: true) { drained = true; throw Failure.drain }
            XCTAssertEqual(drained, !priorFailure)
            XCTAssertEqual(sink.error as? Failure, priorFailure ? .priorCapture : .drain)
            XCTAssertEqual(try saved(record), bytes(pcm), "Converted pending audio must survive a drain failure")
            XCTAssertEqual(record.manifest.state, "interrupted")
            XCTAssertFalse(record.manifest.userStopped)
        }
    }
    func testFinalizationFailureDoesNotReplaceDrainError() throws {
        enum Failure: Error { case drain }
        let record = try RecordingSession(root: root(), config: Configuration(executable: "/unused", model: "/unused"))
        let sink = try CaptureSink(session: record)
        // Remove only this empty synthetic fixture, so journal finalization also fails.
        try FileManager.default.removeItem(at: record.directory)
        sink.finishAfterDraining(userStopped: true) { throw Failure.drain }
        XCTAssertEqual(sink.error as? Failure, .drain)
    }

}
