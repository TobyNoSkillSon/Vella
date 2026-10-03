import XCTest
@testable import VellaCore
final class CoreTests: XCTestCase {
    let mac = Microphone(id: 1, name: "MacBook Pro Microphone")
    let shure = Microphone(id: 2, name: "Shure MV7i")
    func testPreferred() { XCTAssertEqual(selectMicrophone([mac, shure], preferred: shure.name, fallback: mac.name), shure) }
    func testFallback() { XCTAssertEqual(selectMicrophone([mac], preferred: shure.name, fallback: mac.name), mac) }
    func testAnyAvailableInputIsTheLastFallback() {
        let input = Microphone(id: 3, name: "USB input")
        XCTAssertEqual(selectMicrophone([input], preferred: shure.name, fallback: mac.name), input)
    }
    func testFreshDesktopPrefersSystemInputWithoutAssumingMacBook() {
        let usb = Microphone(id: 3, name: "USB input"), display = Microphone(id: 4, name: "Display input")
        XCTAssertEqual(Configuration(model: "").preferredMicrophone, "")
        XCTAssertEqual(selectMicrophone([usb, display], preferred: "", fallback: "", systemDefaultID: 4), display)
        XCTAssertEqual(selectMicrophone([usb], preferred: "", fallback: "", systemDefaultID: 4), usb)
        XCTAssertNil(selectMicrophone([], preferred: "", fallback: "", systemDefaultID: 4))
    }
    func testModelValidation() { XCTAssertThrowsError(try Configuration(model: "").validate()); XCTAssertNoThrow(try Configuration(model: "").validate(requiresModel: false)) }
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
