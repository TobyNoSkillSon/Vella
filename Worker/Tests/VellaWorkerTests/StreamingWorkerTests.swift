import Foundation
import Testing
@testable import VellaWorker
import VellaWorkerSupport

extension WorkerTests {
    /// The streaming worker's request validation, fused-layer tolerance judge and replay boundary (CPU only).
    @Suite struct StreamingWorker {
        /// The streaming helper's line policy: at most 10,000 bytes, an overlong line returned undrained (refused).
        @Test func overlongLinesAreNotDrained() throws {
            let s = try Scratch("vella-stream-line")
            let url = s.url.appendingPathComponent("stdin")
            try Data((String(repeating: "x", count: 10_005) + "\nnext\n").utf8).write(to: url)
            let file = try #require(fopen(url.path, "r")); defer { fclose(file) }
            let first = try #require(readProtocolLine(file, limit: 10000, drainOverlong: false))
            #expect(first.count == 10_001)
            #expect(readProtocolLine(file, limit: 10000, drainOverlong: false)?.count == 5) // the rest of that line
            #expect(readProtocolLine(file, limit: 10000, drainOverlong: false) == Data("next\n".utf8))
            #expect(readProtocolLine(file, limit: 10000, drainOverlong: false) == nil)
        }
        @Test func replyLinesAreASCIIWithoutFragments() throws {
            #expect(
                String(decoding: try asciiJSONLine(["id": NSNull(), "error": "é/"], fragmentsAllowed: false), as: UTF8.self)
                    == #"{"error":"\u00e9/","id":null}"# + "\n")
        }
        @Test func identifiers() {
            let id = "6f1c2a4e-8d3b-4c1a-9e7f-2b5d8c0a1e34"
            #expect(requestIdentifier(id) == id)
            #expect(requestIdentifier("{\(id)}") == "{\(id)}")
            #expect(requestIdentifier("urn:uuid:\(id)") == "urn:uuid:\(id)")
            #expect(requestIdentifier("g1") == nil)
            #expect(requestIdentifier(7) == nil)
        }

        @Test func pcmBounds() throws {
            let samples: [Float] = [0.5, -0.25, 16, -16]
            #expect(try streamingPCM(samples.withUnsafeBytes { Data($0) }.base64EncodedString()) == samples)
            for bad in [[Float(16.5)].withUnsafeBytes { Data($0) }, [Float.nan].withUnsafeBytes { Data($0) }, Data([1, 2, 3]), Data(count: 6404)] {
                #expect(throws: (any Error).self) { try streamingPCM(bad.base64EncodedString()) }
            }
            #expect(throws: (any Error).self) { try streamingPCM("") }
        }

        func replies(_ committed: [String], partial: [String]? = nil) -> [[String: Any]] {
            committed.enumerated().map { i, c in ["committed": c, "partial": partial?[i] ?? "", "frames": 4, "done": false] }
        }

        @Test func fusedToleranceJudge() {
            let stock = replies(["", "hello world", "", "again"])
            #expect(FusedTolerance.judge(stock: stock, fast: stock, rms: 0).accepted)
            // One word edit and a commit one packet later are tolerated; the RMS bound is not.
            let verdict = FusedTolerance.judge(stock: stock, fast: replies(["", "", "hello word", "again"]), rms: 5e-3)
            #expect(verdict.accepted, "\(verdict.summary)")
            #expect(verdict.wordEdits == 1); #expect(verdict.commitShift == 1)
            #expect(!FusedTolerance.judge(stock: stock, fast: stock, rms: 2e-2).accepted)
            #expect(!FusedTolerance.judge(stock: stock, fast: replies(["", "hullo word", "", "again"]), rms: 0).accepted)
            #expect(!FusedTolerance.judge(stock: stock, fast: replies(["", "", "", "hello world again"]), rms: 0).accepted)
            // Shape: frames/done must match reply for reply.
            var reshaped = stock; reshaped[0]["frames"] = 5
            #expect(!FusedTolerance.judge(stock: stock, fast: reshaped, rms: 0).shape)
            // Partials may differ on at most two replies.
            let partials = replies(["", "hello world", "", "again"], partial: ["a", "b", "c", ""])
            #expect(FusedTolerance.judge(stock: stock, fast: partials, rms: 0).partialDifferences == 3)
            #expect(!FusedTolerance.judge(stock: stock, fast: partials, rms: 0).accepted)
            // An empty stock stream proves nothing.
            #expect(!FusedTolerance.judge(stock: replies(["", ""]), fast: replies(["", ""]), rms: 0).accepted)
            #expect(FusedTolerance.maxFusedDeviation == 1e-2)
            #expect(FusedTolerance.wordEdits(["a", "b"], ["a", "c", "b"]) == 1)
        }

        @Test func replayBoundary() {
            #expect(ReplayBoundary.unconsumed(consumed: Array("hello ".utf8), replayed: "hello world") == "world")
            #expect(ReplayBoundary.unconsumed(consumed: [], replayed: "hi") == "hi")
            #expect(ReplayBoundary.unconsumed(consumed: Array("help".utf8), replayed: "hello") == nil)
            #expect(ReplayBoundary.unconsumed(consumed: Array("hello world!".utf8), replayed: "hello") == nil)
            #expect(ReplayBoundary.unconsumed(consumed: Array("é".utf8), replayed: "éa") == "a")
        }
    }
}
