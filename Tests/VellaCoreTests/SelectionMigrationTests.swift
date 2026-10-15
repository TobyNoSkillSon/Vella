import XCTest
@testable import VellaCore

/// 2.1 removes the path choice (Toby, 15 Oct: "we should just have the lightning option"). A 2.0 config.json keeps
/// decoding; every saved Standard choice (selections, the launch set, worker status) becomes the optimized request at
/// the same precision and switch position; the file stays readable by 2.0.
final class SelectionMigrationTests: XCTestCase {
    /// A config.json as Vella 2.0.1 wrote it: Standard and Optimized selections and a launch set with a Standard ref.
    static let config20 = #"""
        {"model":"/models/parakeet-v3-ultra-bf16","mode":"dictation","streamingModel":"/models/nemotron-8bit",
         "preferredMicrophone":"","fallbackMicrophone":"",
         "lastLoaded":{"parakeet-v3-ultra":"BF16","nemotron-3.5-streaming-0.6b":"8b","whisper-large-v3-turbo":"FP16"},
         "selections":{
           "parakeet-v3-ultra":{"tier":"16","path":"standard","mode":"exact"},
           "nemotron-3.5-streaming-0.6b":{"tier":"8","path":"standard","mode":"fast"},
           "whisper-large-v3-turbo":{"tier":"16","path":"optimized","mode":"exact"},
           "qwen3-asr-0.6b":{"tier":"4","mode":"fast"}},
         "residency":{"manualIdleMinutes":0,"onDemandIdleMinutes":15,"allowSwap":false,"launchSet":[
           {"id":"parakeet-v3-ultra","precision":"BF16","path":"/models/parakeet-v3-ultra-bf16","mode":"dictation",
            "selection":{"tier":"16","path":"standard","mode":"exact"}},
           {"id":"nemotron-3.5-streaming-0.6b","precision":"8b","path":"/models/nemotron-8bit","mode":"streaming",
            "selection":{"tier":"8","path":"optimized","mode":"fast"}}]}}
        """#

    func testA20ConfigDecodesWithEveryStandardChoiceAsTheOptimizedRequest() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(Self.config20.utf8))
        XCTAssertEqual(config.model, "/models/parakeet-v3-ultra-bf16")
        XCTAssertEqual(config.lastLoaded["nemotron-3.5-streaming-0.6b"], "8b")
        XCTAssertEqual(config.selections["parakeet-v3-ultra"], ModelSelection(tier: .t16, mode: .exact), "Standard 16 Exact → 16 Exact")
        XCTAssertEqual(config.selections["nemotron-3.5-streaming-0.6b"], ModelSelection(tier: .t8, mode: .fast), "Standard 8 Fast → 8 Fast")
        XCTAssertEqual(config.selections["whisper-large-v3-turbo"], ModelSelection(tier: .t16, mode: .exact), "Optimized stays as it was")
        XCTAssertEqual(config.selections["qwen3-asr-0.6b"], ModelSelection(tier: .t4, mode: .fast), "a missing path decodes too")
        XCTAssertTrue(config.selections.values.allSatisfy { $0.path == .optimized })
        let launch = config.residency.launchSet
        XCTAssertEqual(launch.count, 2)
        XCTAssertEqual(launch[0].selection, ModelSelection(tier: .t16, mode: .exact))
        // The worker recipe of every migrated entry: never `standard`; the Exact recipe (and its gate verdict keys) as before.
        XCTAssertEqual(launch[0].recipe, .optimized_exact)
        XCTAssertEqual(launch[1].recipe, .optimized_fast)
        XCTAssertEqual(workerRecipe(config.selections["nemotron-3.5-streaming-0.6b"]), .optimized_fast)
        XCTAssertEqual(recordedSelection(config: config, family: "parakeet-v3-ultra", precision: "8b"), ModelSelection(tier: .t8, mode: .exact))
    }

    func testWritingKeepsThePathKeySoTheRollbackVersionStillReadsIt() throws {
        var config = try JSONDecoder().decode(Configuration.self, from: Data(Self.config20.utf8))
        config.recordLoad(path: "/models/x", mode: .dictation, family: "whisper-large-v3", precision: "FP16", selection: ModelSelection(tier: .t16, path: .standard, mode: .fast))
        XCTAssertEqual(config.selections["whisper-large-v3"], ModelSelection(tier: .t16, mode: .fast), "a load records the request")
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selections = try XCTUnwrap(object["selections"] as? [String: [String: String]])
        for (id, selection) in selections {
            XCTAssertEqual(selection["path"], "optimized", "\(id): 2.0's decoder requires `path`")
            XCTAssertNotNil(selection["tier"]); XCTAssertNotNil(selection["mode"])
        }
        // 2.0's synthesized decoder (all three keys required, path standard|optimized) reads it back.
        struct Selection20: Decodable {
            enum Path: String, Decodable { case standard, optimized }
            var tier: String; var path: Path; var mode: String
        }
        let back = try JSONDecoder().decode([String: Selection20].self, from: JSONSerialization.data(withJSONObject: selections))
        XCTAssertEqual(back["parakeet-v3-ultra"]?.path, .optimized)
        XCTAssertEqual(back["parakeet-v3-ultra"]?.mode, "exact")
        // Round trip in 2.1: identical.
        let again = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(again.selections, config.selections)
        XCTAssertEqual(again.residency.launchSet, config.residency.launchSet)
    }

    func testWorkerStatusSelectionIsTheRequestAndTheEffectivePathStaysTruthful() throws {
        let json = #"{"mode":"dictation","precision":"BF16","engine":"mlx","selection":{"tier":"16","path":"standard","mode":"fast"}}"#
        let status = try JSONDecoder().decode(WorkerModelStatus.self, from: Data(json.utf8))
        let requested = try XCTUnwrap(status.selection)
        XCTAssertEqual(requested, ModelSelection(tier: .t16, mode: .fast))
        // Agent-facing reports still say what runs: stock MLX after a fallback.
        XCTAssertEqual(effectiveSelection(requested, engine: status.engine).path, .standard)
        XCTAssertEqual(recipeLabel(effectiveSelection(requested, engine: status.engine)), "Standard")
        XCTAssertEqual(effectiveSelection(requested, engine: "optimized"), requested)
        XCTAssertEqual(ModelSelection(tier: .t8, path: .standard, mode: .exact).request, ModelSelection(tier: .t8, mode: .exact))
    }
}
