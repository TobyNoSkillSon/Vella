import XCTest
import AppKit
import AVFoundation
import CryptoKit
@testable import Vella
@testable import VellaCore

/// Pipeline QA scenarios simulated through the app's own seams: no microphone, no global shortcut, no real TCC change,
/// no system sleep, no key events and a private pasteboard. Each test names the seam it drives.
@MainActor final class PipelineScenarioQATests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// A finished recording of `seconds` of a 440 Hz tone (speech-level RMS), as the Recorder leaves it.
    private func recording(seconds: Double, model: String = "/qa/model", userStopped: Bool = true) throws -> RecordingSession {
        let session = try RecordingSession(root: root.appendingPathComponent("Recordings"), config: Configuration(model: model))
        let writer = try SegmentedPCMWriter(session: session)
        let samples = (0..<Int(seconds * 16_000)).map { Float(0.1 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish(userStopped: userStopped)
        return session
    }
    private func model(
        trusted: @escaping () -> Bool = { true }, request: SessionTranscriber.Request? = nil,
        destination: (() -> DictationController.DestinationCheck)? = nil, pasteboard: NSPasteboard? = nil
    ) throws -> DictationController {
        let permission = InsertionPermission(isTrusted: trusted, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        return DictationController(
            insertionPermission: permission, pasteboard: pasteboard ?? NSPasteboard(name: .init("vella-qa-\(UUID().uuidString)")),
            stopCapture: { _ in }, transcriptionRequest: request, configurationURL: root.appendingPathComponent("config.json"),
            captureDestination: destination ?? { { "QA: no destination" } }, backend: Backend(runtime: try Runtime.isolated(root)))
    }
    private func settle(_ model: DictationController, until done: (DictationController) -> Bool) async throws {
        for _ in 0..<500 where !done(model) { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    /// The status-item menu the app would show now (real AppDelegate.rebuildMenu, no status item installed).
    private func menu(for model: DictationController) -> (header: String, titles: [String], delegate: AppDelegate) {
        let delegate = AppDelegate(
            model: model,
            shortcutManager: ShortcutManager(
                engine: ShortcutEngine(configuration: .default, sinks: .init(start: {}, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false })), store: ShortcutStore(),
                registrar: QARegistrar()))
        delegate.pendingModelRow = { model.pendingModelRequest.map { ($0.title, $0.help) } }
        delegate.rebuildMenu()
        let titles = delegate.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        return (titles.first ?? "", titles, delegate)
    }

    // MARK: Microphone switch mid-recording (seams: CaptureSink.consume with a new device format; recordingTick(error:))

    /// A device change hands the sink buffers in another format (a Bluetooth headset at 16 kHz after the built-in mic at
    /// 48 kHz stereo, then a USB mic at 44.1 kHz): the converter is rebuilt and every second is kept.
    func testMicrophoneFormatChangeMidRecordingKeepsTheAudio() throws {
        let session = try RecordingSession(root: root, config: Configuration(model: "/qa/model"))
        let sink = try CaptureSink(session: session)
        let formats: [(Double, AVAudioChannelCount, Bool)] = [(48_000, 2, true), (16_000, 1, true), (44_100, 1, false), (48_000, 2, true)]
        for (rate, channels, interleaved) in formats {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
            let chunk = Int(rate / 50)
            for i in 0..<100 { // 2 s in 20 ms device buffers
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
                buffer.frameLength = AVAudioFrameCount(chunk)
                let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for b in list {
                    let p = b.mData!.assumingMemoryBound(to: Float.self)
                    let n = Int(b.mDataByteSize) / 4
                    for k in 0..<n { p[k] = Float(0.1 * sin(Double(i * chunk + k / Int(interleaved ? channels : 1)) * 2 * .pi * 300 / rate)) }
                }
                sink.consume(try LongRecordingTests.sample(buffer))
            }
        }
        sink.finish(userStopped: true)
        XCTAssertNil(sink.error)
        XCTAssertEqual(session.seconds, 8.0, accuracy: 0.05, "four 2 s stretches in four device formats, nothing dropped")
        let recovered = try RecordingSession(directory: session.directory)
        XCTAssertEqual(recovered.seconds, session.seconds, accuracy: 0.001)
    }

    /// The device disappears (AVCaptureSession stops or delivers nothing for 3 s): the next tick stops the recording with
    /// the audio kept, offers Retry, and the Microphone menu stays locked while recording.
    func testUnpluggedMicrophoneStopsWithTheAudioKeptAndRetry() async throws {
        let model = try model(request: { _, _ in "unplugged text" })
        model.recorder.adoptForTesting(try recording(seconds: 6, userStopped: false))
        model.phase = .recording
        let recordingMenu = menu(for: model)
        let microphones = recordingMenu.delegate.menu.item(withTitle: "Microphone")?.submenu?.items.filter { $0.action != nil } ?? []
        XCTAssertTrue(microphones.allSatisfy { !$0.isEnabled }, "no microphone switch while recording")
        model.recordingTick(error: "The microphone stopped delivering audio. Check its connection and start again.")
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(
            model.message, "The microphone stopped delivering audio. Check its connection and start again. Saved audio is retained; Retry processes it without automatic insertion."
        )
        let failed = menu(for: model)
        XCTAssertEqual(failed.header, "Dictation: needs attention…")
        XCTAssertTrue(failed.titles.contains("Retry Saved Recording"))
        model.retry()
        try await settle(model) { $0.phase == .success }
        XCTAssertEqual(model.lastText, "unplugged text")
        XCTAssertTrue(model.message.hasPrefix("Copied to clipboard."), "a recovered recording is clipboard-only: \(model.message)")
    }

    // MARK: Sleep / wake (seam: NSWorkspace.willSleepNotification posted in-process to the manager's observers)

    func testSleepDuringRecordingCancelsOnlyAHeldCaptureAndKeepsItsAudio() async throws {
        for behavior in [ShortcutBehavior.toggle, .holdToTalk] {
            let model = try model()
            var started = 0
            let engine = ShortcutEngine(
                configuration: .init(trigger: ShortcutConfiguration.default.trigger, behavior: behavior),
                sinks: .init(
                    start: { [unowned self] in
                        started += 1
                        model.recorder.adoptForTesting(try! self.recording(seconds: 3, userStopped: false)); model.phase = .recording
                    },
                    finish: { model.finish() }, cancel: { model.cancel() },
                    isRecording: { model.phase == .recording }, isBusy: { model.busy }, currentOperation: { model.captureGeneration }))
            let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: QARegistrar())
            manager.beginObservingSystemInterruptions()
            manager.handlePress()
            if behavior == .toggle { manager.handleRelease() }
            XCTAssertEqual(model.phase, .recording)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
            try await Task.sleep(nanoseconds: 100_000_000)
            if behavior == .toggle {
                XCTAssertEqual(model.phase, .recording, "a toggle recording is not cancelled by sleep (it resumes or stalls after wake)")
            } else {
                XCTAssertEqual(model.phase, .idle, "a held capture is cancelled by sleep, nothing inserted")
                XCTAssertEqual(model.message, "Stopped. Audio and completed text remain in Saved Recordings; nothing was pasted.")
                let directory = try XCTUnwrap(model.savedSession?.directory)
                XCTAssertEqual(try RecordingSession(directory: directory).seconds, 3, accuracy: 0.001, "its audio is kept")
            }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(started, 1)
            model.cancel()
        }
    }

    // MARK: Double shortcut press (seam: ShortcutManager.handlePress, the registrar's callback)

    func testDoubleShortcutPressStartsOneRecording() throws {
        var starts = 0, finishes = 0, phase = DictationController.Phase.idle
        let engine = ShortcutEngine(
            configuration: .default,
            sinks: .init(
                start: {
                    starts += 1; phase = .preparing
                }, finish: { finishes += 1 }, cancel: {},
                isRecording: { phase == .recording }, isBusy: { phase == .preparing }))
        let manager = ShortcutManager(engine: engine, store: ShortcutStore(), registrar: QARegistrar())
        manager.handlePress(); manager.handlePress() // second press before the first release (key bounce)
        manager.handleRelease()
        manager.handlePress(isRepeat: true) // auto-repeat
        manager.handlePress(); manager.handleRelease() // pressed again while still preparing
        XCTAssertEqual(starts, 1); XCTAssertEqual(finishes, 0)
        phase = .recording
        manager.handlePress(); manager.handlePress(); manager.handleRelease()
        XCTAssertEqual(finishes, 1, "the double press finishes once")
    }

    // MARK: Recording with no model (seam: Finish on an adopted recording whose config has no model)

    func testRecordingWithNoModelIsKeptAndOffersGet() async throws {
        let model = try model()
        model.offerModel = { mode in .init(id: "parakeet-ultra-mlx-bf16", name: "Parakeet v3 Ultra", downloadBytes: 1_254_840_214, mode: mode) }
        model.recorder.adoptForTesting(try recording(seconds: 4, model: ""))
        model.phase = .recording
        model.finish()
        try await settle(model) { $0.phase == .failed }
        XCTAssertEqual(model.message, "Recording saved. No dictation model is installed yet. Choose Get Parakeet v3 Ultra (1.3 GB) in the menu to transcribe it.")
        let shown = menu(for: model)
        XCTAssertEqual(shown.header, "Dictation: recording kept, needs a model")
        XCTAssertTrue(shown.titles.contains("Get Parakeet v3 Ultra (1.3 GB)"))
        let saved = try RecordingSession(directory: XCTUnwrap(model.savedSession?.directory))
        XCTAssertEqual(saved.manifest.failureCode, "no_model"); XCTAssertEqual(saved.seconds, 4, accuracy: 0.001)
        // Without the one-click fetch wired, Get explains itself instead of failing silently.
        model.getRecommendedModel()
        XCTAssertEqual(model.message, "Model downloads are unavailable. Get a model in Models…, then Retry.")
    }

    // MARK: Accessibility revoked mid-session (seams: InsertionPermission.isTrusted, the Finish-time destination check)

    func testAccessibilityRevokedMidSessionCopiesAndBlocksTheNextStart() async throws {
        var trusted = true
        let pasteboard = NSPasteboard(name: .init("vella-qa-\(UUID().uuidString)"))
        // The production check starts with AXIsProcessTrusted(); the seam reads the simulated trust instead.
        let model = try model(
            trusted: { trusted }, request: { _, _ in "revoked mid session" },
            destination: { { trusted ? "QA: never paste" : "Enable Accessibility for Vella to insert automatically." } }, pasteboard: pasteboard)
        XCTAssertTrue(model.ensureAutomaticInsertion())
        model.recorder.adoptForTesting(try recording(seconds: 3))
        model.phase = .recording
        trusted = false // revoked while recording
        model.finish()
        try await settle(model) { $0.phase == .success }
        XCTAssertEqual(model.message, "Copied to clipboard. Paste with ⌘V. Enable Accessibility for Vella to insert automatically.")
        XCTAssertEqual(pasteboard.string(forType: .string), "revoked mid session")
        XCTAssertFalse(model.insertionWasAutomatic)
        XCTAssertEqual(menu(for: model).header, "Dictation: copied—press ⌘V")
        try await settle(model) { $0.phase == .idle }
        XCTAssertEqual(menu(for: model).header, "Dictation: Accessibility required")
        // The next start is refused before the microphone opens; the shortcut path goes through the same check.
        XCTAssertFalse(model.ensureAutomaticInsertion())
        XCTAssertEqual(
            model.message, "macOS has not granted this running Vella build Accessibility access. Click “Accessibility required” in Vella’s menu. Recording has not started.")
        var starts = 0
        let manager = ShortcutManager(
            engine: ShortcutEngine(configuration: .default, sinks: .init(start: { starts += 1 }, finish: {}, cancel: {}, isRecording: { false }, isBusy: { false })),
            store: ShortcutStore(), registrar: QARegistrar())
        manager.permissionCheck = { model.ensureAutomaticInsertion() }
        manager.handlePress(); manager.handleRelease()
        XCTAssertEqual(starts, 0)
    }

    // MARK: Worker killed twice mid-segment (seam: the transcription request throws WorkerExited)

    func testWorkerKilledTwiceShowsOneClearFailureAndRetryFinishes() async throws {
        var calls = 0, failing = true
        let model = try model(request: { _, _ in
            calls += 1
            if failing { throw WorkerExited() }
            return "segment"
        })
        model.recorder.adoptForTesting(try recording(seconds: 12))
        model.phase = .recording
        model.finish()
        try await settle(model) { $0.phase == .failed }
        XCTAssertEqual(calls, 2, "one automatic retry, then the manual Retry")
        XCTAssertEqual(
            model.message,
            "Vella's inference worker exited. Saved audio is retained. Audio and completed segments are saved. Retry resumes unfinished segments; recovery copies only.")
        XCTAssertTrue(menu(for: model).titles.contains("Retry Saved Recording"))
        failing = false
        model.retry()
        try await settle(model) { $0.phase == .success }
        XCTAssertFalse(model.lastText.isEmpty)
    }

    // MARK: Download failing midway (seam: ModelLibrary.downloadConfiguration with a URLProtocol stub)

    func testDownloadFailingMidwayReportsTheReasonAndRemovesItsPartialFiles() async throws {
        let (library, model) = try QAHub.library(root: root, weights: Data(repeating: 7, count: 4 << 20))
        QAHub.failAfter = 1 << 20
        XCTAssertTrue(library.download(approval: confirmed(model.id)))
        for _ in 0..<500 where library.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        print("QA mid-download failure message: \(library.downloadError ?? "nil")")
        XCTAssertTrue(library.downloadError?.hasSuffix("download failed: The network connection was lost. Partial files removed.") == true, library.downloadError ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.modelsDirectory.appendingPathComponent(model.id).path))
        XCTAssertTrue(library.installed.isEmpty)
        QAHub.failAfter = nil // the next Get starts over and installs
        XCTAssertTrue(library.download(approval: confirmed(model.id)))
        for _ in 0..<500 where library.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(library.downloadError); XCTAssertNotNil(library.installed[model.id])
    }

    /// Disk full during a download: `VELLA_QA_DISK` names a small mounted disk image (hdiutil create -size 200m); the
    /// stub serves a 300 MB weights file into its Models folder.
    func testDiskFullDuringDownloadSaysSoAndFreesTheDisk() async throws {
        guard let disk = ProcessInfo.processInfo.environment["VELLA_QA_DISK"] else { throw XCTSkip("Opt-in: VELLA_QA_DISK=<mounted small disk image>") }
        let mount = URL(fileURLWithPath: disk).appendingPathComponent("qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        let before = try XCTUnwrap(freeDiskBytes(at: mount))
        let (library, model) = try QAHub.library(root: mount, weights: Data(repeating: 9, count: 300 << 20))
        XCTAssertTrue(library.download(approval: confirmed(model.id)))
        for _ in 0..<3000 where library.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        let message = library.downloadError ?? ""
        print("QA disk-full download message: \(message)")
        XCTAssertEqual(message, "Fixture 4-bit download failed: the disk is full. Free some space, then try again. Partial files removed.", "the footer names the full disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.modelsDirectory.appendingPathComponent(model.id).path))
        let after = try XCTUnwrap(freeDiskBytes(at: mount))
        XCTAssertGreaterThan(after, before - (8 << 20), "partial files removed: the disk is free again")
    }
}

extension PipelineScenarioQATests {
    /// A write that fails for lack of space is reported as a full disk (the task it cancels would say "cancelled").
    func testDownloadWriteFailureOnAFullDiskIsNamed() {
        for error in [
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        ] {
            XCTAssertEqual(NativeModelDownload.writeError(error).localizedDescription, "the disk is full. Free some space, then try again", "\(error)")
        }
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertEqual((NativeModelDownload.writeError(other) as NSError).code, NSFileWriteNoPermissionError)
    }

    /// The headless QA seam never applies to the user's own support folder.
    func testHeadlessSeamNeedsAnIsolatedSupportDirectory() {
        XCTAssertTrue(AppDelegate.qaHeadless(["VELLA_QA_HEADLESS": "1", "VELLA_SUPPORT_DIR": "/tmp/vella-qa/support"]))
        XCTAssertFalse(AppDelegate.qaHeadless(["VELLA_QA_HEADLESS": "1"]))
        XCTAssertFalse(AppDelegate.qaHeadless(["VELLA_QA_HEADLESS": "1", "VELLA_SUPPORT_DIR": "relative"]))
        XCTAssertFalse(AppDelegate.qaHeadless(["VELLA_SUPPORT_DIR": "/tmp/vella-qa/support"]))
    }
}

private final class QARegistrar: ShortcutRegistrar {
    var registered: ShortcutConfiguration?
    func register(_ config: ShortcutConfiguration, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws { registered = config }
    func unregister() { registered = nil }
}

/// A Hugging Face stand-in: pinned metadata, then the files; `failAfter` drops the connection after that many bytes of
/// the weights. Serves in 1 MB chunks so a large file streams.
final class QAHub: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var revision = String(repeating: "b", count: 40)
    nonisolated(unsafe) static var failAfter: Int?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path.contains("/api/models/") {
            let siblings: [[String: Any]] = Self.files.map { name, data in
                ["rfilename": name, "size": data.count, "lfs": ["sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]]
            }
            respond(200, try! JSONSerialization.data(withJSONObject: ["sha": Self.revision, "siblings": siblings]))
            return
        }
        guard let data = Self.files[url.lastPathComponent] else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < data.count {
            if let limit = Self.failAfter, url.lastPathComponent == "model.safetensors", offset >= limit {
                // As URLSession reports it (a bare URLError has no localized description).
                let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
                client?.urlProtocol(self, didFailWithError: lost); return
            }
            let end = min(offset + (1 << 20), data.count)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end)); offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    private func respond(_ code: Int, _ body: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    @MainActor static func library(root: URL, weights: Data) throws -> (ModelLibrary, ModelRecommendation) {
        let model = ModelRecommendation(
            id: "fixture", name: "Fixture", quantization: "4-bit", repository: "org/repo", revision: revision, downloadBytes: Int64(weights.count),
            architecture: "parakeet", license: "test", recommendation: "test")
        let family = ModelFamily(
            id: "fixture", name: model.name, mode: .dictation, languages: ["en"], params: "0.6B", license: model.license, native: "4b",
            variants: [
                "4b": CatalogVariant(id: model.id, repository: model.repository, revision: model.revision, downloadBytes: model.downloadBytes, architecture: model.architecture)
            ],
            notes: model.recommendation)
        try JSONEncoder().encode(ModelCatalog(schema: 2, families: [family])).write(to: root.appendingPathComponent("models.json"))
        files = [
            "config.json": Data(#"{"target":"nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel","quantization":{"bits":4}}"#.utf8),
            "model.safetensors": weights
        ]
        failAfter = nil
        let library = ModelLibrary(resources: root, registryURL: root.appendingPathComponent("registry.json"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [QAHub.self]
        library.downloadConfiguration = configuration; library.selectedID = model.id
        return (library, model)
    }
}
