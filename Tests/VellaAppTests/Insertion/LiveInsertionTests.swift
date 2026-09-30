import XCTest
import AppKit
@testable import Vella

final class LiveInsertionTests: XCTestCase {
    @MainActor
    func testCancelFencesPendingTask() async throws {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.offer(committed: "stale", partial: "")
        controller.cancel()
        controller.offer(committed: "more", partial: "")
        await controller.finishStream()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(output, "")
    }

    @MainActor
    func testFocusCheckedEveryBatchAndLatched() async {
        var current = true
        var output = ""
        let controller = LiveInsertion(
            targetIsCurrent: { current },
            send: {
                output += $0
                current = false
            })
        controller.offer(committed: String(repeating: "a", count: 45), partial: "")
        await controller.finishStream()
        XCTAssertEqual(output.count, 20)
        XCTAssertNotNil(controller.blockedReason)
        current = true
        controller.offer(committed: String(repeating: "a", count: 5), partial: "")
        await controller.finishStream()
        XCTAssertEqual(output.count, 20)
    }

    @MainActor
    func testUnicodeAndControlSanitization() async throws {
        var batches: [String] = []
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { batches.append($0) })
        let text = "A\r\n\t\u{0008}\u{001B}\u{0085}\u{2028}\u{2029}" + String(repeating: "👨‍👩‍👧‍👦é", count: 4)
        controller.offer(committed: text, partial: "")
        await controller.finishStream()
        XCTAssertEqual(batches.joined(), LiveInsertion.sanitize(text))
        XCTAssertTrue(batches.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertTrue(batches.joined().hasPrefix("A 👨‍👩‍👧‍👦"))
        XCTAssertEqual(try LiveInsertion.unicodeChunks("1234567890123456789😀"), ["1234567890123456789", "😀"])
        XCTAssertThrowsError(try LiveInsertion.unicodeChunks("a" + String(repeating: "\u{0301}", count: 21)))
        XCTAssertEqual(LiveInsertion.sanitize("word   "), "word ")
        XCTAssertEqual(LiveInsertion.sanitize("a\u{00A0}\u{00A0}b"), "a\u{00A0}\u{00A0}b")
    }

    @MainActor
    func testNativeEventMarkerAndKeyboardShapeWithoutPosting() throws {
        let (down, up) = try LiveInsertion.nativeEvents(for: "Hi 😀")
        XCTAssertEqual(down.type, .keyDown)
        XCTAssertEqual(up.type, .keyUp)
        for event in [down, up] {
            XCTAssertEqual(event.flags, [])
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
            let marker = event.getIntegerValueField(.eventSourceUserData)
            XCTAssertEqual(marker, LiveInsertion.eventMarker)
            XCTAssertNotEqual(marker, 0)
            var units = [UniChar](repeating: 0, count: 20)
            var count = 0
            event.keyboardGetUnicodeString(
                maxStringLength: units.count,
                actualStringLength: &count, unicodeString: &units)
            XCTAssertEqual(String(decoding: units.prefix(count), as: UTF16.self), "Hi 😀")
        }
    }

    @MainActor
    func testIncrementalDrainsEndpointsAndUnicode() async {
        var output = ""
        let c = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        c.offer(committed: "", partial: "Hello 👨‍👩‍👧‍👦")
        c.flush()
        c.offer(committed: "Hello 👨‍👩‍👧‍👦 é", partial: "next")
        c.flush()
        c.offer(committed: "next piece second drain", partial: "last")
        c.offer(committed: "last", partial: "")
        c.flush()
        c.offer(committed: "", partial: "new utterance")
        c.offer(committed: "new utterance", partial: "")
        await c.finishStream()
        await c.finishStream()
        XCTAssertEqual(output, "Hello 👨‍👩‍👧‍👦 é next piece second drain last new utterance")
        XCTAssertEqual(c.sentText, output)
        XCTAssertNil(c.blockedReason)
        XCTAssertEqual(c.pendingUTF8Count, 0)
        XCTAssertEqual(c.tailUTF8Count, 0)
    }

    @MainActor
    func testIncrementalRevisionOverflowAndUncertainSendLatch() async {
        for revised in ["different", ""] {
            let c = LiveInsertion(targetIsCurrent: { true }, send: { _ in XCTFail("Should not send") })
            c.offer(committed: "", partial: "word")
            c.offer(committed: "", partial: revised)
            await c.finishStream()
            XCTAssertNotNil(c.blockedReason)
        }
        let overflow = LiveInsertion(targetIsCurrent: { true }, send: { _ in XCTFail("Should not send") })
        for _ in 0..<10 { overflow.offer(committed: String(repeating: "a ", count: 1024), partial: "") }
        XCTAssertNotNil(overflow.blockedReason)
        XCTAssertLessThanOrEqual(overflow.pendingUTF8Count, LiveInsertion.maximumPendingUTF8)
        await overflow.finishStream()
        let oversized = LiveInsertion(targetIsCurrent: { true }, send: { _ in XCTFail("Should not send") })
        oversized.offer(committed: "", partial: String(repeating: "😀", count: 8192))
        XCTAssertNotNil(oversized.blockedReason)
        var attempts = 0
        let uncertain = LiveInsertion(
            targetIsCurrent: { true },
            send: { _ in
                attempts += 1
                throw LiveInsertion.DeliveryError.eventCreation
            })
        uncertain.offer(committed: "word", partial: "")
        uncertain.flush()
        uncertain.offer(committed: "more", partial: "")
        await uncertain.finishStream()
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testIncrementalGraphemeExtensionAndRoamingGuard() async {
        var output = ""
        let c = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        c.offer(committed: "", partial: "e")
        c.flush()
        c.offer(committed: "", partial: "e\u{0301}")
        await c.finishStream()
        XCTAssertEqual(output, "e")
        XCTAssertNotNil(c.blockedReason)
        // An unsent grapheme may still grow safely.
        var unsent = ""
        let d = LiveInsertion(targetIsCurrent: { true }, send: { unsent += $0 })
        d.offer(committed: "", partial: "e")
        d.offer(committed: "e\u{0301}", partial: "")
        await d.finishStream()
        XCTAssertEqual(unsent, "e\u{0301}")
        XCTAssertNil(d.blockedReason)
    }

    @MainActor
    func testTwentyFourHourEquivalentBoundedIncrementalDelivery() async {
        // 24h at 150 words/minute = 216,000 words. Injected sender only.
        let unit = "alpha bravo café 👨‍👩‍👧‍👦 é delta echo foxtrot golf hotel"
        var output = ""
        let c = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        var peakPending = 0
        var peakTail = 0
        let start = Date()
        for _ in 0..<21_600 {
            c.offer(committed: "", partial: "alpha bravo")
            c.offer(committed: "", partial: unit)
            peakPending = max(peakPending, c.pendingUTF8Count)
            peakTail = max(peakTail, c.tailUTF8Count)
            c.flush()
            c.offer(committed: unit, partial: "")
            XCTAssertNil(c.blockedReason)
        }
        await c.finishStream()
        let expected = Array(repeating: unit, count: 21_600).joined(separator: " ")
        XCTAssertEqual(output, expected)
        XCTAssertEqual(c.sentText, expected)
        XCTAssertLessThanOrEqual(peakPending, LiveInsertion.maximumPendingUTF8)
        XCTAssertLessThanOrEqual(peakTail, LiveInsertion.maximumTailUTF8)
        XCTAssertEqual(c.tailUTF8Count, 0)
        XCTAssertEqual(c.pendingUTF8Count, 0)
        print(
            "24h-equivalent words=216000 offers=64800 sent_utf8=\(c.sentText.utf8.count) peak_pending_utf8=\(peakPending) peak_tail_utf8=\(peakTail) seconds=\(Date().timeIntervalSince(start))"
        )
    }

    @MainActor
    func testMultiple2048SizedPrefixDrainsInOneEvent() async {
        var output = ""
        let c = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        let piece = String(repeating: "word ", count: 409).trimmingCharacters(in: .whitespaces)
        c.offer(committed: "", partial: piece)
        c.flush()
        let three = [piece, piece, piece].joined(separator: " ")
        c.offer(committed: three, partial: "tail")
        XCTAssertLessThanOrEqual(c.pendingUTF8Count, LiveInsertion.maximumPendingUTF8)
        XCTAssertEqual(c.tailUTF8Count, 5)
        c.flush()
        c.offer(committed: "tail", partial: "")
        c.offer(committed: piece, partial: "")
        await c.finishStream()
        XCTAssertEqual(output, three + " tail " + piece)
        XCTAssertNil(c.blockedReason)
    }
}
