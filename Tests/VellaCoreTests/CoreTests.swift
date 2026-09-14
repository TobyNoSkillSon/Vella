import XCTest
@testable import VellaCore
final class CoreTests: XCTestCase {
    let mac = Microphone(id: 1, name: "MacBook Pro Microphone")
    let shure = Microphone(id: 2, name: "Shure MV7i")
    func testPreferred() { XCTAssertEqual(selectMicrophone([mac, shure], preferred: shure.name, fallback: mac.name), shure) }
    func testFallback() { XCTAssertEqual(selectMicrophone([mac], preferred: shure.name, fallback: mac.name), mac) }
    func testNoUnrelatedDevice() { XCTAssertNil(selectMicrophone([Microphone(id: 3, name: "iPhone Microphone")], preferred: shure.name, fallback: mac.name)) }
    func testTranscript() throws { XCTAssertEqual(try transcript(from: Data("{\"text\":\" hello \"}".utf8)), "hello") }
    func testEmptyTranscript() throws { XCTAssertEqual(try transcript(from: Data(#"{"text":" "}"#.utf8)), "") }
    func testMalformedTranscript() { XCTAssertThrowsError(try transcript(from: Data("{}".utf8))) }
    func testMultipart() {
        let body = multipart(audio: Data([0, 1, 255]), model: "local-model", boundary: "test")
        XCTAssertTrue(body.range(of: Data([0, 1, 255])) != nil)
        XCTAssertTrue(body.starts(with: Data("--test\r\n".utf8)))
        XCTAssertTrue(body.suffix(12) == Data("\r\n--test--\r\n".utf8))
    }
    func testModelValidation() { XCTAssertThrowsError(try Configuration(executable: "python", model: "").validate()); XCTAssertNoThrow(try Configuration(executable: "python", model: "").validate(requiresModel: false)) }
    func testMeterSilenceAndInvalidSamples() {
        XCTAssertEqual(visualLevel(rms: 0), 0)
        XCTAssertEqual(visualLevel(rms: .nan), 0)
        XCTAssertEqual(visualLevel(rms: .infinity), 0)
        XCTAssertEqual(visualLevel(rms: -1), 0)
    }
    func testMeterRespondsToSpeechAndClamps() {
        XCTAssertGreaterThan(visualLevel(rms: 0.1), visualLevel(rms: 0.01))
        XCTAssertEqual(visualLevel(rms: 1), 1)
        XCTAssertEqual(visualLevel(rms: 10), 1)
    }
}
