import XCTest
@testable import VellaCore

final class RecognitionModeTests: XCTestCase {
    func testLegacyAndNewConfigurationsDoNotRequireRuntimePath() throws {
        let current = try JSONDecoder().decode(Configuration.self, from: Data(#"{"model":"/dictation"}"#.utf8))
        XCTAssertNoThrow(try current.validate())
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"executable":"/old/Runtimes/python","model":"/dictation"}"#.utf8))
        XCTAssertNoThrow(try old.validate())
        XCTAssertEqual(old.model, "/dictation")
        // The retired key is not written back.
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(written["executable"])
    }
    func testOldConfigurationDefaultsToDictation() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(#"{"executable":"/python","model":"/dictation"}"#.utf8))
        XCTAssertEqual(config.mode, .dictation)
        XCTAssertEqual(config.streamingModel, "")
        XCTAssertEqual(config.selectedModel, "/dictation")
        XCTAssertEqual(config.preferredMicrophone, "")
        XCTAssertNoThrow(try config.validate())
    }
    func testSlotsStayIndependentAndSnapshotDoesNotMutateSavedSelection() throws {
        var config = Configuration(model: "/dictation", mode: .streaming, streamingModel: "/stream")
        config.selectModel("/new-dictation", for: .dictation)
        XCTAssertEqual(config.mode, .streaming)
        XCTAssertEqual(config.streamingModel, "/stream")
        config.selectModel("/new-stream", for: .streaming)
        XCTAssertEqual(config.model, "/new-dictation")
        let snapshot = try config.forRecording()
        XCTAssertEqual(snapshot.model, "/new-stream")
        XCTAssertEqual(snapshot.streamingModel, "/new-stream")
        XCTAssertEqual(snapshot.mode, .streaming)
        XCTAssertEqual(config.model, "/new-dictation")
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.selectedModel, "/new-stream")
        XCTAssertEqual(decoded.model, "/new-dictation")
    }
    func testValidationNeverFallsBackToOtherMode() throws {
        var config = Configuration(model: "/dictation", mode: .streaming)
        XCTAssertThrowsError(try config.validate())
        XCTAssertThrowsError(try config.forRecording())
        XCTAssertNoThrow(try config.validate(requiresModel: false))
        config.mode = .dictation
        XCTAssertEqual(try config.forRecording().model, "/dictation")
        XCTAssertEqual(RecognitionMode.allCases.map(\.title), ["Dictation", "Streaming"])
    }
}
