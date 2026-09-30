import Foundation
import XCTest
@testable import VellaWire

final class VellaWireTests: XCTestCase {
    func testRawSpellings() {
        XCTAssertEqual(Architecture.allCases.map(\.rawValue), ["parakeet", "qwen3_asr", "whisper", "nemotron_asr", "stub"])
        XCTAssertEqual(Recipe.allCases.map(\.rawValue), ["standard", "optimized_exact", "optimized_fast"])
        XCTAssertEqual(Recipe.variable, "VELLA_RECIPE")
        XCTAssertEqual(Engine.allCases.map(\.rawValue), ["optimized", "mlx"])
    }

    func testGateRecordRoundTripsTheGatesFile() throws {
        let file =
            #"{"status":"fast","workerVersion":"native-kernels-10","gpuFamily":"apple9","osBuild":"25G72","date":"2026-09-29T20:14:03Z","model":"parakeet-ultra-bf16","reason":"optimized without nax_gemm (word edits 3 > 1)","disabled.nax_gemm":"word edits 3 > 1"}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
        let record = try XCTUnwrap(GateRecord(json: object))
        XCTAssertEqual(record.status, .fast)
        XCTAssertEqual(record.disabled, ["nax_gemm": "word edits 3 > 1"])
        XCTAssertEqual(record.json as NSDictionary, object as NSDictionary)
        let inconclusive = try XCTUnwrap(GateRecord(json: ["status": "inconclusive", "count": "1"]))
        XCTAssertEqual(inconclusive.count, 1)
        XCTAssertEqual(inconclusive.json, ["status": "inconclusive", "count": "1"])
        XCTAssertNil(GateRecord(json: ["status": "maybe"]))
        XCTAssertNil(GateRecord(json: ["model": "x"]))
    }

    func testWordEdits() {
        XCTAssertEqual(WordEdits.distance([String](), []), 0)
        XCTAssertEqual(WordEdits.distance([], ["a", "b"]), 2)
        XCTAssertEqual(WordEdits.distance(["a", "b", "c"], ["a", "x", "c"]), 1)
        XCTAssertEqual(WordEdits.distance(["a", "b", "c"], ["a", "c"]), 1)
        XCTAssertEqual(WordEdits.distance(["kitten"], ["sitting", "kitten"]), 1)
        XCTAssertEqual(WordEdits.distance(["x"], []), 1)
    }

    func testHelperStatusReadsAndWritesTheSameObject() throws {
        let line =
            #"{"status":{"architecture":"stub","disabled_components":{"nax_gemm":"word edits 3 > 1"},"engine":"optimized","engine_reason":null,"event":"load","gpu":{"chip":"Apple M5 Max","family":"apple9"},"load_s":0.025,"memory":{"footprint_mb":9.5,"mlx_active_mb":0,"mlx_cache_mb":0},"model":"/m/stub","optimizations":{"stub":true},"pid":4792,"recipe":"optimized_fast","test_hooks":{"VELLA_STUB_MODELS":"1"},"version":"native-kernels-10","worker":"dictation"}}"#
        let object = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["status"] as? [String: Any])
        let status = HelperStatus(json: object)
        XCTAssertEqual(status.worker, .dictation); XCTAssertEqual(status.pid, 4792); XCTAssertEqual(status.engine, "optimized")
        XCTAssertNil(status.engineReason); XCTAssertEqual(status.memory?.footprintMB, 9.5); XCTAssertEqual(status.gpu?.family, "apple9")
        XCTAssertEqual(status.testHooks, ["VELLA_STUB_MODELS": "1"]); XCTAssertEqual(status.disabledComponents, ["nax_gemm": "word edits 3 > 1"])
        XCTAssertEqual(status.jsonObject as NSDictionary, object as NSDictionary)
        // A streaming line has no architecture or GPU; empty hooks are omitted.
        let streaming = HelperStatus(
            worker: .streaming, pid: 1, version: "v", event: "unload", model: nil, engine: nil, engineReason: nil,
            optimizations: [:], loadSeconds: nil, memory: .init(footprintMB: nil, mlxActiveMB: 0, mlxCacheMB: 0), recipe: "standard")
        XCTAssertEqual(
            Set(streaming.jsonObject.keys),
            [
                "worker", "pid", "version", "event", "model", "engine", "engine_reason",
                "optimizations", "load_s", "memory", "recipe"
            ])
        XCTAssertEqual(HelperStatus(json: ["pid": "x", "engine": 3]).pid, nil, "a wrong type counts as absent")
    }

    func testStreamingReplyDecodes() throws {
        let reply = try JSONDecoder().decode(StreamingReply.self, from: Data(#"{"committed":"hi","frames":1600,"id":"6f1c2a4e-8d3b-4c1a-9e7f-2b5d8c0a1e34","partial":""}"#.utf8))
        XCTAssertEqual(reply.frames, 1600); XCTAssertEqual(reply.committed, "hi"); XCTAssertNil(reply.done)
    }
}
