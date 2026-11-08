import Foundation
import XCTest

@testable import VellaCore

/// 8 Nov 2026: going back to 2.2.0 (which did not know `dictationSource`) dropped the "from Heimdall" choice from
/// config.json. From 2.2.1 on, keys a newer Vella wrote survive this version reading and saving the file.
final class ConfigurationUnknownKeysTests: XCTestCase {
    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testANewerVersionsKeysSurviveAReadAndSave() throws {
        let written = """
            {"model":"/m/parakeet","mode":"dictation","streamingModel":"","preferredMicrophone":"Shure","fallbackMicrophone":"",
             "dictationSource":"heimdall","futureChoice":"heimdall-alpha",
             "futureNested":{"a":[1,"x",true,null],"b":{"c":2.5}},"executable":"/old/python"}
            """
        var config = try JSONDecoder().decode(Configuration.self, from: Data(written.utf8))
        XCTAssertEqual(config.dictationSource, .heimdall)
        XCTAssertEqual(config.unknownKeys["futureChoice"], .string("heimdall-alpha"))
        // A save after an ordinary change (what the app does on every selection).
        config.selectModel("/m/other", for: .dictation)
        let saved = try object(JSONEncoder().encode(config))
        XCTAssertEqual(saved["model"] as? String, "/m/other")
        XCTAssertEqual(saved["dictationSource"] as? String, "heimdall")
        XCTAssertEqual(saved["futureChoice"] as? String, "heimdall-alpha")
        let original = try object(Data(written.utf8))
        XCTAssertEqual(saved["futureNested"] as? NSDictionary, original["futureNested"] as? NSDictionary)
        // The 0.8 Python runtime path stays dropped.
        XCTAssertNil(saved["executable"])
    }

    /// Review of 2.2.1: a value this version cannot read (a newer mode) resets that field only; before, the whole
    /// decode failed and the next save wrote a blank configuration.
    func testAnUnreadableValueResetsOnlyThatField() throws {
        let written = """
            {"model":"/m/parakeet","mode":"meeting","preferredMicrophone":"Shure","dictationSource":"heimdall",
             "selections":{"parakeet-v3-ultra":{"mode":"fast","tier":"16","path":"optimized"}}}
            """
        let config = try JSONDecoder().decode(Configuration.self, from: Data(written.utf8))
        XCTAssertEqual(config.mode, .dictation)
        XCTAssertEqual(config.model, "/m/parakeet")
        XCTAssertEqual(config.preferredMicrophone, "Shure")
        XCTAssertEqual(config.dictationSource, .heimdall)
        XCTAssertEqual(config.selections.count, 1)
    }

    func testAConfigWithoutUnknownKeysSavesTheSameKeysAsBefore() throws {
        var config = Configuration(model: "/m/parakeet", preferredMicrophone: "Shure")
        config.dictationSource = .own
        let saved = try object(JSONEncoder().encode(config))
        XCTAssertEqual(
            Set(saved.allKeys.compactMap { $0 as? String }),
            [
                "model", "mode", "streamingModel", "preferredMicrophone", "fallbackMicrophone", "residency", "lastLoaded", "selections",
                "clearedSelectionReasons", "dictationSource",
            ])
        let again = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.dictationSource, .own)
        XCTAssertTrue(again.unknownKeys.isEmpty)
        // Never chosen: no key at all, as before.
        XCTAssertNil(try object(JSONEncoder().encode(Configuration(model: "")))["dictationSource"])
    }
}
