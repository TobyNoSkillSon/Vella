import XCTest
import AppKit
@testable import Vella

final class LiveInsertionTests: XCTestCase {
    @MainActor
    func testLiveBeforeFinishAndFinalSuffixOnce() async throws {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.offer("Hello")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while output != "Hello", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(output, "Hello")
        controller.offer("Hello world")
        await controller.finish("Hello world!")
        await controller.finish("Hello world!")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(output, "Hello world!")
        XCTAssertEqual(controller.sentText, output)
        XCTAssertTrue(controller.didSend)
    }

    @MainActor
    func testCancelFencesPendingTask() async throws {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.offer("stale")
        controller.cancel()
        controller.offer("stale more")
        await controller.finish("stale more")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(output, "")
    }

    @MainActor
    func testFocusCheckedEveryBatchAndLatched() async {
        var current = true
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { current }, send: {
            output += $0
            current = false
        })
        await controller.finish(String(repeating: "a", count: 45))
        XCTAssertEqual(output.count, 20)
        XCTAssertNotNil(controller.blockedReason)
        current = true
        await controller.finish(String(repeating: "a", count: 50))
        XCTAssertEqual(output.count, 20)
    }

    @MainActor
    func testRetractionIncludingWhitespaceBlocks() async {
        for changed in ["other", "word"] {
            var output = ""
            let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
            controller.offer("word ")
            controller.offer(changed)
            await controller.finish("word more")
            XCTAssertEqual(output, "")
            XCTAssertNotNil(controller.blockedReason)
        }
    }

    @MainActor
    func testUserInputPolicy() async {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.observeUserInput(type: .keyDown, marker: LiveInsertion.eventMarker)
        controller.observeUserInput(type: .mouseMoved)
        controller.observeUserInput(type: .keyDown, keyCode: 45, modifiers: [.command, .control])
        XCTAssertNil(controller.blockedReason)
        controller.observeUserInput(type: .leftMouseDown)
        await controller.finish("no")
        XCTAssertEqual(output, "")
        XCTAssertNotNil(controller.blockedReason)
        let typing = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        typing.observeUserInput(type: .keyDown, keyCode: 0)
        XCTAssertNotNil(typing.blockedReason)
    }

    @MainActor
    func testUnicodeAndControlSanitization() async throws {
        var batches: [String] = []
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { batches.append($0) })
        let text = "A\r\n\t\u{0008}\u{001B}\u{0085}\u{2028}\u{2029}" + String(repeating: "👨‍👩‍👧‍👦é", count: 4)
        await controller.finish(text)
        XCTAssertEqual(batches.joined(), LiveInsertion.sanitize(text))
        XCTAssertTrue(batches.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertTrue(batches.joined().hasPrefix("A 👨‍👩‍👧‍👦"))
        XCTAssertEqual(try LiveInsertion.unicodeChunks("1234567890123456789😀"), ["1234567890123456789", "😀"])
        XCTAssertThrowsError(try LiveInsertion.unicodeChunks("a" + String(repeating: "\u{0301}", count: 21)))
    }

    @MainActor
    func testExtendingSentGraphemeBlocksRatherThanSplits() async throws {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.offer("e")
        // This tests revision of an already sent grapheme, not timer latency.
        controller.flush()
        XCTAssertEqual(output, "e")
        await controller.finish("e\u{0301}")
        XCTAssertEqual(output, "e")
        XCTAssertNotNil(controller.blockedReason)
    }

    @MainActor
    func testShortcutReleaseAfterModifiersDoesNotBlock() async {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.observeUserInput(type: .keyDown, keyCode: 45, modifiers: [.control, .command])
        controller.observeUserInput(type: .flagsChanged)
        controller.observeUserInput(type: .keyUp, keyCode: 45, modifiers: [])
        controller.observeUserInput(type: .keyUp, keyCode: 45, modifiers: [.command])
        XCTAssertNil(controller.blockedReason)
        await controller.finish("first word")
        XCTAssertEqual(output, "first word")
    }

    @MainActor
    func testNativeEventMarkerAndKeyboardShapeWithoutPosting() throws {
        let (down, up) = try LiveInsertion.nativeEvents(for: "Hi 😀")
        XCTAssertEqual(down.type, .keyDown)
        XCTAssertEqual(up.type, .keyUp)
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { _ in })
        for event in [down, up] {
            XCTAssertEqual(event.flags, [])
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
            let marker = event.getIntegerValueField(.eventSourceUserData)
            XCTAssertEqual(marker, LiveInsertion.eventMarker)
            XCTAssertNotEqual(marker, 0)
            var units = [UniChar](repeating: 0, count: 20)
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count,
                actualStringLength: &count, unicodeString: &units)
            XCTAssertEqual(String(decoding: units.prefix(count), as: UTF16.self), "Hi 😀")
            controller.observeUserInput(type: event.type == .keyDown ? .keyDown : .keyUp,
                marker: marker)
        }
        XCTAssertNil(controller.blockedReason)
        controller.observeUserInput(type: .keyDown, marker: 123)
        XCTAssertNotNil(controller.blockedReason)
    }

    @MainActor
    func testWorkerDrainSpaceNormalizationRemainsAppendOnly() async throws {
        var output = ""
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 })
        controller.offer("hello  world")
        controller.flush()
        XCTAssertEqual(output, "hello world")
        controller.offer("hello world again")
        await controller.finish("hello   world  again  ")
        XCTAssertEqual(output, "hello world again ")
        XCTAssertNil(controller.blockedReason)
        XCTAssertEqual(LiveInsertion.sanitize("word   "), "word ")
        XCTAssertEqual(LiveInsertion.sanitize("a\u{00A0}\u{00A0}b"), "a\u{00A0}\u{00A0}b")
    }

    @MainActor
    func testUncertainSendNeverRetried() async {
        var attempts = 0
        let controller = LiveInsertion(targetIsCurrent: { true }, send: { _ in
            attempts += 1
            throw LiveInsertion.DeliveryError.eventCreation
        })
        await controller.finish("hello")
        await controller.finish("hello again")
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(controller.blockedReason)
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
        let uncertain = LiveInsertion(targetIsCurrent: { true }, send: { _ in
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
        let c = LiveInsertion(targetIsCurrent: { true }, send: { output += $0 }, monitorUserInput: false)
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
        print("24h-equivalent words=216000 offers=64800 sent_utf8=\(c.sentText.utf8.count) peak_pending_utf8=\(peakPending) peak_tail_utf8=\(peakTail) seconds=\(Date().timeIntervalSince(start))")
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
