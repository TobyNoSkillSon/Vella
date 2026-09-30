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
        let file = #"{"status":"fast","workerVersion":"native-kernels-10","gpuFamily":"apple9","osBuild":"25G72","date":"2026-09-29T20:14:03Z","model":"parakeet-ultra-bf16","reason":"optimized without nax_gemm (word edits 3 > 1)","disabled.nax_gemm":"word edits 3 > 1"}"#
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
}
