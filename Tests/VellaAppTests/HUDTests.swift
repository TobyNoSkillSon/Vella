import XCTest
import AppKit
import SwiftUI
import VellaCore
@testable import Vella

final class HUDTests: XCTestCase {
    @MainActor func testFailureCategoriesPersistAndSuccessfulRecoveryClearsThem() async throws {
        let cases: [(Float, Error, String)] = [
            (0, VellaError.noSpeech, "no_speech"),
            (0.1, VellaError.noSpeech, "unrecognized_audio"),
            (0.1, URLError(.timedOut), "timeout"),
            (0.1, VellaError.message("Fixture failure"), "local_failure")]
        for (level, error, code) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-failure-fixture-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try RecordingSession(root: root, config: Configuration(executable: "/unused", model: "/fixture"))
            let writer = try SegmentedPCMWriter(session: session)
            try [Float](repeating: level, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
            try writer.finish(userStopped: true)
            let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
            let failed = expectation(description: code)
            var shouldFail = true
            let model = Model(pasteboard: clipboard, transcriptionRequest: { _, _ in
                if shouldFail { throw error }; return "Recovered fixture speech."
            })
            model.onChange = { if model.phase == .failed { failed.fulfill() } }
            model.recover(session.directory)
            await fulfillment(of: [failed], timeout: 2)
            model.onChange = nil
            XCTAssertEqual(try RecordingSession(directory: session.directory).manifest.failureCode, code)
            XCTAssertNil(clipboard.string(forType: .string))
            // Silence remains silence; never turn it into invented text on Retry.
            if level == 0 { continue }
            shouldFail = false
            let recovered = expectation(description: "Recovery clears failure category")
            model.onChange = { if model.phase == .success { recovered.fulfill() } }
            model.retry()
            await fulfillment(of: [recovered], timeout: 2)
            model.onChange = nil
            XCTAssertNil(try RecordingSession(directory: session.directory).manifest.failureCode)
            XCTAssertFalse(model.insertionWasAutomatic)
            XCTAssertEqual(clipboard.string(forType: .string), "Recovered fixture speech.")
        }
    }
    @MainActor func testBackendOriginatedCancellationSettlesWithoutPasting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-cancel-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, config: Configuration(executable: "/unused", model: "/fixture"))
        let writer = try SegmentedPCMWriter(session: session)
        try [Float](repeating: 0.1, count: 1600).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: true)
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        let settled = expectation(description: "Backend cancellation exits busy state")
        let model = Model(pasteboard: clipboard, transcriptionRequest: { _, _ in throw CancellationError() })
        model.referenceSpeed = { _ in 0.001 } // Exercise the progress-timer path.
        model.onChange = { if model.phase == .failed { settled.fulfill() } }
        model.recover(session.directory)
        await fulfillment(of: [settled], timeout: 2)
        model.onChange = nil
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.processingProgress.isEmpty)
        XCTAssertTrue(model.message.contains("stopped before completion"))
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertNil(clipboard.string(forType: .string))
        let saved = try RecordingSession(directory: session.directory)
        XCTAssertEqual(saved.manifest.failureCode, "cancelled")
        XCTAssertNil(saved.manifest.segments.first?.text)
    }
    @MainActor private func privateClipboard() -> NSPasteboard {
        NSPasteboard(name: .init("vella-hud-test-\(UUID())"))
    }

    @MainActor func testCopyOnlySuccessSettlesAndOldCleanupCannotResetANewPhase() async throws {
        let clipboard = privateClipboard(), otherClipboard = privateClipboard()
        defer { clipboard.releaseGlobally(); otherClipboard.releaseGlobally() }
        let provider = ClipboardReadProbe()
        let item = NSPasteboardItem(); item.setDataProvider(provider, forTypes: [.string])
        clipboard.writeObjects([item])
        let model = Model(pasteboard: clipboard), next = Model(pasteboard: otherClipboard)
        model.hudVisible = true
        model.finishPasteCheck() // No target: recovery/copy-only path, no keyboard event.
        next.finishPasteCheck()
        next.update(.preparing, "A newer operation")
        XCTAssertEqual(model.phase, .success)
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertEqual(provider.reads, 0, "Copy-only insertion must not snapshot the old clipboard")
        XCTAssertEqual(clipboard.string(forType: .string), "Vella paste verification.")
        let settled = expectation(description: "Copy-only success returns to idle")
        model.onChange = { if model.phase == .idle { settled.fulfill() } }
        await fulfillment(of: [settled], timeout: 4)
        model.onChange = nil
        XCTAssertFalse(model.hudVisible)
        XCTAssertEqual(next.phase, .preparing)
        XCTAssertEqual(clipboard.string(forType: .string), "Vella paste verification.", "Copy-only text must remain available")
        next.update(.idle, "Done")
    }

    func testHiddenHUDNeverSchedulesAnimation() {
        for phase in [Model.Phase.idle, .preparing, .recording, .transcribing, .success, .failed] {
            XCTAssertTrue(HUDView.animationPaused(phase: phase, visible: false, reduced: false))
            XCTAssertTrue(HUDView.animationPaused(phase: phase, visible: true, reduced: true))
        }
        XCTAssertTrue(HUDView.animationPaused(phase: .idle, visible: true, reduced: false))
        XCTAssertFalse(HUDView.animationPaused(phase: .failed, visible: true, reduced: false))
        XCTAssertFalse(HUDView.animationPaused(phase: .recording, visible: true, reduced: false))
        XCTAssertFalse(HUDView.animationPaused(phase: .success, visible: true, reduced: false))
    }

    func testBrowserContainerCannotStandInForTheOriginalTextField() {
        for role: String? in [nil, "AXApplication", "AXWindow", "AXWebArea", "AXGroup", "AXScrollArea", "AXToolbar", "AXButton", "AXStaticText"] {
            XCTAssertFalse(AccessibilityFocus.isFieldRole(role))
        }
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            XCTAssertTrue(AccessibilityFocus.isFieldRole(role))
        }
    }

    func testWarningWigglesThenUsesTheExistingCollapse() {
        XCTAssertLessThan(HUDView.failureDwell, 0.7)
        XCTAssertNotEqual(WaveformMotion.warning(age: 0.05, reduced: false),
                          WaveformMotion.warning(age: 0.12, reduced: false))
        XCTAssertEqual(WaveformMotion.warning(age: 0.50, reduced: false),
                       WaveformMotion.sample(entryAge: 2, finishAge: 0.50 - WaveformMotion.warningWiggleDuration, reduced: false))
        XCTAssertEqual(WaveformMotion.warning(age: HUDView.failureDwell, reduced: false).opacity, 0)
        for age in [0.0, 0.1, 0.5] {
            XCTAssertEqual(WaveformMotion.warning(age: age, reduced: true), WaveformMotion())
        }
    }

    @MainActor func testWarningHUDRendersOrangeWaveAndDisappears() throws {
        _ = NSApplication.shared
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        let model = Model(pasteboard: clipboard); model.phase = .failed
        var frames: [Data] = []
        for (name, age) in [("warning-a", 0.05), ("warning-b", 0.13), ("warning-collapse", 0.50), ("warning-gone", HUDView.failureDwell)] {
            let renderer = ImageRenderer(content: HUDView(model: model, previewTime: 1,
                previewEntryAge: 2, previewFinishAge: age))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var colored = 0, visible = 0
            for y in 0..<image.height { for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                visible += 1
                if color.redComponent > color.blueComponent + 0.08 { colored += 1 }
            } }
            if name == "warning-gone" { XCTAssertEqual(visible, 0) }
            else { XCTAssertGreaterThan(colored, 30) }
            frames.append(try XCTUnwrap(image.dataProvider?.data as Data?))
            if let output = ProcessInfo.processInfo.environment["VELLA_HUD_QA_DIR"] {
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            }
        }
        XCTAssertNotEqual(frames[0], frames[1])
        XCTAssertEqual(model.phase, .failed, "Hiding feedback must not clear the recoverable error")
        XCTAssertNil(clipboard.string(forType: .string))
    }

    @MainActor func testFinishAcknowledgesBeforeCaptureDrainAndKeepsMainActorResponsive() async {
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        var drain: CheckedContinuation<Void, Error>?
        let started = expectation(description: "Capture drain started")
        let failed = expectation(description: "Missing fixture journal is reported without insertion")
        let model = Model(pasteboard: clipboard, stopCapture: { _ in
            try await withCheckedThrowingContinuation { continuation in
                drain = continuation; started.fulfill()
            }
        })
        model.update(.recording, "Fixture; no microphone")
        model.audioLevel = 0.7
        model.finish()
        XCTAssertEqual(model.phase, .transcribing, "Shortcut must acknowledge synchronously")
        XCTAssertEqual(model.audioLevel, 0)
        XCTAssertTrue(model.busy)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.phase, .transcribing, "UI can run while capture is still draining")
        model.onChange = { if model.phase == .failed { failed.fulfill() } }
        drain?.resume()
        await fulfillment(of: [failed], timeout: 2)
        model.onChange = nil
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertNil(clipboard.string(forType: .string))
    }

    @MainActor func testCancelDuringDrainWaitsBeforeAllowingNewCapture() async {
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        var drain: CheckedContinuation<Void, Error>?
        let started = expectation(description: "Capture drain started")
        let settled = expectation(description: "Cancellation settles after drain")
        let model = Model(pasteboard: clipboard, stopCapture: { _ in
            try await withCheckedThrowingContinuation { continuation in
                drain = continuation; started.fulfill()
            }
        })
        model.update(.recording, "Fixture; no microphone"); model.finish()
        await fulfillment(of: [started], timeout: 2)
        model.cancel()
        XCTAssertTrue(model.busy, "Don't race a second capture against unfinished journal writes")
        XCTAssertEqual(model.phase, .transcribing)
        model.onChange = { if model.phase == .idle { settled.fulfill() } }
        drain?.resume()
        await fulfillment(of: [settled], timeout: 2)
        model.onChange = nil
        XCTAssertFalse(model.busy)
        XCTAssertNil(clipboard.string(forType: .string))
    }

    @MainActor func testShutdownWaitsForDrainEvenWhenCancelledDrainFails() async {
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        var drain: CheckedContinuation<Void, Error>?
        let started = expectation(description: "Drain started")
        let finished = expectation(description: "Orderly shutdown after drain")
        let model = Model(pasteboard: clipboard, stopCapture: { _ in
            try await withCheckedThrowingContinuation { continuation in
                drain = continuation; started.fulfill()
            }
        })
        model.update(.recording, "Fixture; no microphone"); model.finish()
        await fulfillment(of: [started], timeout: 2)
        var shutdownReturned = false
        Task { await model.shutdownAfterCaptureDrain(); shutdownReturned = true; finished.fulfill() }
        await Task.yield()
        XCTAssertFalse(shutdownReturned)
        XCTAssertTrue(model.captureIsFinalizing)
        drain?.resume(throwing: NSError(domain: "VellaFixture", code: 1))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(clipboard.string(forType: .string))
    }

    @MainActor func testPermissionPollingStopsAtDeadlineAndOnGrant() {
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        var trusted = false, checks = 0
        let history = PermissionPromptHistory(read: { true }, write: {})
        let permission = InsertionPermission(isTrusted: { checks += 1; return trusted }, prompt: {}, history: history)
        let delegate = AppDelegate(model: Model(insertionPermission: permission, pasteboard: clipboard))
        XCTAssertNil(delegate.permissionTimer, "No recurring timer before an explicit polling window")
        delegate.beginPermissionPolling(now: 100)
        let first = delegate.permissionTimer
        XCTAssertEqual(first?.isValid, true)
        delegate.pollPermission(now: 159)
        let beforeExpiry = checks
        delegate.pollPermission(now: 160)
        XCTAssertNil(delegate.permissionTimer); XCTAssertEqual(first?.isValid, false)
        delegate.pollPermission(now: 161)
        XCTAssertEqual(checks, beforeExpiry, "Expired and queued callbacks must not keep probing")
        delegate.beginPermissionPolling(now: 200)
        let second = delegate.permissionTimer
        trusted = true
        delegate.pollPermission(now: 201)
        XCTAssertNil(delegate.permissionTimer); XCTAssertEqual(second?.isValid, false)
        delegate.beginPermissionPolling(now: 300)
        XCTAssertNil(delegate.permissionTimer, "An existing grant never needs idle polling")
    }

    @MainActor func testClipboardSnapshotRejectsIneligibleAndNonPlainTextWithoutReadingProviders() {
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        for types: [NSPasteboard.PasteboardType] in [[.string], [.tiff], [.fileURL], [.string, .tiff]] {
            let provider = ClipboardReadProbe()
            let item = NSPasteboardItem(); item.setDataProvider(provider, forTypes: types)
            clipboard.clearContents(); clipboard.writeObjects([item])
            XCTAssertNil(Model.clipboardTextToRestore(clipboard, eligible: false))
            if types != [.string] { XCTAssertNil(Model.clipboardTextToRestore(clipboard, eligible: true)) }
            XCTAssertEqual(provider.reads, 0)
        }
    }

    @MainActor func testClipboardRestoresOnlyBoundedTextAndNeverOverwritesANewerCopy() throws {
        let clipboard = privateClipboard(); defer { clipboard.releaseGlobally() }
        let text = String(repeating: "x", count: Model.clipboardRestoreLimit)
        clipboard.setString(text, forType: .string)
        let snapshot = try XCTUnwrap(Model.clipboardTextToRestore(clipboard, eligible: true))
        clipboard.clearContents(); clipboard.setString("Dictation", forType: .string)
        Model.restoreClipboardText(snapshot, to: clipboard, changeCount: clipboard.changeCount)
        XCTAssertEqual(clipboard.string(forType: .string), text)
        let staleCount = clipboard.changeCount
        clipboard.clearContents(); clipboard.setString("Newer user copy", forType: .string)
        Model.restoreClipboardText(snapshot, to: clipboard, changeCount: staleCount)
        XCTAssertEqual(clipboard.string(forType: .string), "Newer user copy")
        clipboard.clearContents(); clipboard.setString(text + "x", forType: .string)
        XCTAssertNil(Model.clipboardTextToRestore(clipboard, eligible: true))
        clipboard.clearContents()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("One", forType: .string); second.setString("Two", forType: .string)
        clipboard.writeObjects([first, second])
        XCTAssertNil(Model.clipboardTextToRestore(clipboard, eligible: true))
    }

    func testEstimateVisibilityUsesPredictedWorkNotRecordingLength() {
        XCTAssertFalse(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: 120, speed: 200))
        XCTAssertFalse(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: 1000, speed: 200))
        XCTAssertTrue(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: 1001, speed: 200))
        XCTAssertTrue(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: 30, speed: 2))
        for speed: Double? in [nil, 0, -1, .nan, .infinity] {
            XCTAssertFalse(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: 3600, speed: speed))
        }
        XCTAssertFalse(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: 0, speed: 200))
        XCTAssertFalse(TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: .infinity, speed: 200))
    }

    func testRiseDetachesSettlesAndCollapseStaysInPlace() {
        XCTAssertEqual(182 * WaveformField.visibleDomain, 145.6, accuracy: 0.001)
        XCTAssertGreaterThan(WaveformMotion.sample(entryAge: 0.05, finishAge: nil, reduced: false).attachment, 0)
        XCTAssertEqual(WaveformMotion.sample(entryAge: 0.4, finishAge: nil, reduced: false).attachment, 0)
        XCTAssertLessThan(WaveformMotion.sample(entryAge: 0.55 / WaveformMotion.entranceSpeed, finishAge: nil, reduced: false).offsetY, 0)
        XCTAssertEqual(WaveformMotion.sample(entryAge: 1.5, finishAge: nil, reduced: false).offsetY, 0, accuracy: 0.01)
        let finish = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5].map { WaveformMotion.sample(entryAge: 2, finishAge: $0, reduced: false) }
        XCTAssertEqual(finish.map(\.width), finish.map(\.width).sorted(by: >))
        XCTAssertTrue(finish.allSatisfy { $0.offsetY == 0 })
        XCTAssertEqual(finish.last?.opacity, 0)
        XCTAssertEqual(WaveformMotion.sample(entryAge: 0.35, finishAge: nil, reduced: false).offsetY, 0)
        XCTAssertEqual(WaveformMotion.sample(entryAge: 2, finishAge: 0.17, reduced: false).opacity, 0)
        XCTAssertLessThan(HUDView.successDwell, 0.2)
        XCTAssertEqual(WaveformMotion.sample(entryAge: 0, finishAge: nil, reduced: true), WaveformMotion())
        XCTAssertEqual(WaveformMotion.sample(entryAge: 0, finishAge: 0, reduced: true).opacity, 0)
    }

    @MainActor func testProceduralReferenceStatesRenderWithoutGlass() throws {
        _ = NSApplication.shared
        let cases: [(String, Double, Double, Double?)] = [
            ("emerge", 0.4, 0.08, nil), ("lift", 0.4, 0.22, nil),
            ("listening", 0, 2, nil), ("low", 0.2, 2, nil),
            ("medium", 0.6, 2, nil), ("high", 1, 2, nil),
            ("finish", 0.6, 2, 0.045), ("collapse", 0.6, 2, 0.27),
            ("point", 0.6, 2, 0.43), ("vanish", 0.6, 2, 0.5)]
        var images: [String: CGImage] = [:]
        for (name, level, entry, finish) in cases {
            let motion = WaveformMotion.sample(entryAge: entry / WaveformMotion.entranceSpeed, finishAge: finish.map { $0 / WaveformMotion.completionSpeed }, reduced: false)
            let renderer = ImageRenderer(content: WaveformField(level: level, time: 1.2, motion: motion).frame(width: HUDView.panelSize.width, height: HUDView.panelSize.height))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 440); XCTAssertEqual(image.height, 248)
            images[name] = image
            if let output = ProcessInfo.processInfo.environment["VELLA_HUD_QA_DIR"] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("wave-\(name).png"))
            }
        }
        let renderer = ImageRenderer(content: WaveformField(level: 0, time: 8.9, motion: WaveformMotion()).frame(width: 220, height: 124))
        renderer.scale = 2
        let still = try XCTUnwrap(renderer.cgImage)
        if let output = ProcessInfo.processInfo.environment["VELLA_HUD_QA_DIR"] {
            for (name, image) in [("silence-a", images["listening"]!), ("silence-b", still)] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            }
        }
        let a = try XCTUnwrap(images["listening"]?.dataProvider?.data as Data?)
        let b = try XCTUnwrap(still.dataProvider?.data as Data?)
        XCTAssertEqual(a.count, b.count)
        // CoreGraphics can round antialiased 8-bit edge channels by one LSB
        // across contexts. This tolerance permits rounding, not moving geometry.
        XCTAssertLessThanOrEqual(zip(a,b).map { abs(Int($0)-Int($1)) }.max() ?? 0, 1,
                                 "Silence must remain visually still")
    }
}

private final class ClipboardReadProbe: NSObject, NSPasteboardItemDataProvider {
    var reads = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setData(Data("Lazy fixture".utf8), forType: type)
    }
}
