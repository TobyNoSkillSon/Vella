import Foundation
import Testing
@testable import VellaStreamingWorker

extension WorkerTests {
    /// The streaming worker's request validation, fused-layer tolerance judge and replay boundary (CPU only).
    @Suite struct StreamingWorker {
        @Test func identifiers() {
            let id = "6f1c2a4e-8d3b-4c1a-9e7f-2b5d8c0a1e34"
            #expect(streamingIdentifier(id) == id)
            #expect(streamingIdentifier("{\(id)}") == "{\(id)}")
            #expect(streamingIdentifier("urn:uuid:\(id)") == "urn:uuid:\(id)")
            #expect(streamingIdentifier("g1") == nil)
            #expect(streamingIdentifier(7) == nil)
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
