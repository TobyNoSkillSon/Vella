import AppKit
import SwiftUI
import AVFoundation
import Carbon
import ApplicationServices
import QuartzCore
import VellaCore

final class GlobalShortcut {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.action?() }
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return false }
        return RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | cmdKey), EventHotKeyID(signature: 0x56454C41, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }
    deinit { if let ref { UnregisterEventHotKey(ref) }; if let handler { RemoveEventHandler(handler) } }
}

@MainActor final class Model: ObservableObject {
    enum Phase { case idle, preparing, recording, transcribing, success, failed }
    @Published var phase = Phase.idle
    @Published private(set) var mode: RecognitionMode = .dictation
    @Published var message = "Your voice, right where you need it."
    @Published var microphone = "Shure → MacBook"
    @Published var elapsed = 0
    @Published var audioLevel = 0.0
    @Published var hudVisible = false
    @Published var lastText = ""
    @Published var lastTranscriptIncomplete = false
    @Published var processingProgress = ""
    private(set) var savedSession: RecordingSession?
    private var progressTimer: Timer?
    var referenceSpeed: ((String) -> Double?)?
    private var targetElement: AXUIElement?
    private var targetWindow: AXUIElement?
    private var allowAutomaticInsertion = false
    @Published var insertionWasAutomatic = false
    @Published var backendStatus = "Local MLX Audio"
    let insertionPermission: InsertionPermission
    private let pasteboard: NSPasteboard
    private let stopCapture: (Recorder) async throws -> Void
    private let transcriptionRequest: SessionTranscriber.Request?
    private var finishingCapture = false
    private var captureDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let configurationURL: URL
    let streamingBackend: StreamingBackend
    private var streamingBuffer: StreamingPCMBuffer?
    private var streamingTask: Task<String, Error>?
    private var streamingJournal: StreamingJournal?
    private var liveInsertion: LiveInsertion?
    var captureIsFinalizing: Bool { finishingCapture }
    init(insertionPermission: InsertionPermission? = nil, pasteboard: NSPasteboard = .general,
         stopCapture: ((Recorder) async throws -> Void)? = nil,
         transcriptionRequest: SessionTranscriber.Request? = nil, configurationURL: URL? = nil,
         streamingBackend: StreamingBackend? = nil) {
        self.streamingBackend = streamingBackend ?? StreamingBackend()
        self.configurationURL = configurationURL ?? Backend.configURL
        self.insertionPermission = insertionPermission ?? InsertionPermission()
        self.pasteboard = pasteboard
        self.stopCapture = stopCapture ?? { recorder in _ = try await recorder.stopAsync(userStopped: true) }
        self.transcriptionRequest = transcriptionRequest
        if let data = try? Data(contentsOf: self.configurationURL), let saved = try? JSONDecoder().decode(Configuration.self, from: data) { mode = saved.mode }
    }
    func selectMode(_ mode: RecognitionMode) throws {
        guard !busy, phase != .recording else { throw VellaError.message("Finish or stop recording before switching modes.") }
        var config = FileManager.default.fileExists(atPath: configurationURL.path)
            ? try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationURL))
            : Configuration(executable: configurationURL.deletingLastPathComponent().appendingPathComponent("runtime/bin/python").path, model: "")
        config.mode = mode
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: configurationURL, options: .atomic)
        stopWorkers(); self.mode = mode
        update(.idle, "\(mode.title) selected. Press ⌃⌘N to start; press it again to finish.")
    }
    func stopWorkers() {
        liveInsertion?.cancel(); streamingTask?.cancel(); streamingBuffer?.abort(); backend.stop(); streamingBackend.stop()
        streamingBackend.onEvent = nil; streamingJournal?.close(); streamingJournal = nil
    }
    func releaseWorkers() async throws {
        try await CalibrationStore.shared.cancelAndWait()
        try await backend.releaseAndWait(); try await streamingBackend.releaseAndWait()
    }
    @discardableResult func ensureAutomaticInsertion() -> Bool {
        guard insertionPermission.ensure() else {
            if phase != .recording && !busy {
                update(.idle, "macOS has not granted this running Vella build Accessibility access. Use Enable Automatic Insertion in the menu. Recording has not started.")
            }
            return false
        }
        return true
    }
    let backend = Backend()
    let recorder = Recorder()
    private let recordingPower = RecordingPower()
    var onChange: (() -> Void)?
    private var target: NSRunningApplication?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var task: Task<Void, Never>?
    private var successTask: Task<Void, Never>?
    private(set) var failureStartedAt = Date()
    private var config: Configuration?
    private var operation = UUID()
    var busy: Bool { finishingCapture || phase == .preparing || phase == .transcribing }
    var title: String {
        switch phase {
        case .idle: return "Ready to listen"
        case .preparing: return "Getting ready"
        case .recording: return "Listening · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
        case .transcribing: return "Transcribing locally"
        case .success: return insertionWasAutomatic ? "Paste sent" : "Copied—paste with ⌘V"
        case .failed: return "Needs attention"
        }
    }
    var icon: String {
        switch phase {
        case .recording: return "waveform"
        case .preparing, .transcribing: return "ellipsis"
        case .success: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "waveform"
        }
    }
    func update(_ phase: Phase, _ message: String) {
        successTask?.cancel(); successTask = nil
        if phase == .failed { failureStartedAt = Date() }
        self.phase = phase; self.message = message
        if phase == .idle { hudVisible = false }
        if phase == .success {
            // Every success path, including copy-only recovery, must settle back to idle.
            successTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
                guard let self, self.phase == .success else { return }
                self.update(.idle, "Your voice, right where you need it.")
            }
        }
        if phase == .recording { recordingPower.begin() } else { recordingPower.end() }
        if phase != .recording { meterTimer?.invalidate(); meterTimer = nil; audioLevel = 0 }
        let status: [String: Any] = ["phase": String(describing: phase),
            "error": phase == .failed ? message : "", "microphone": microphone,
            "checkedAt": ISO8601DateFormatter().string(from: Date())]
        if Bundle.main.bundleIdentifier == "dev.vella.dictation",
           let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: Backend.support.appendingPathComponent("dictation-status.json"), options: .atomic)
        }
        onChange?()
    }
    func toggle() {
        if phase == .recording { finish(); return }
        guard !busy else { NSSound.beep(); return }
        guard ensureAutomaticInsertion() else { return }
        if CalibrationStore.shared.isRunning { CalibrationStore.shared.cancel() }
        task?.cancel(); operation = UUID()
        liveInsertion?.cancel(); liveInsertion = nil
        let operation = self.operation
        recorder.discard()
        savedSession = nil
        // Dictation owns an original target. Streaming deliberately follows the
        // system keyboard focus and does not take a field/window snapshot.
        target = mode == .dictation ? NSWorkspace.shared.frontmostApplication : nil
        if mode == .dictation { captureTargetFocus() }
        else { targetElement = nil; targetWindow = nil }
        allowAutomaticInsertion = false
        update(.preparing, "Checking microphone permission…")
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard allowed else { throw VellaError.message("Allow Vella under System Settings → Privacy & Security → Microphone.") }
                let config = try backend.configuration().forRecording(); self.config = config; mode = config.mode
                try await CalibrationStore.shared.cancelAndWait()
                try await streamingBackend.releaseAndWait()
                try Task.checkCancellation()
                guard self.operation == operation else { return }
                streamingTask = nil; streamingBuffer = nil
                streamingBackend.resetTranscript()
                let pcm = config.mode == .streaming ? StreamingPCMBuffer() : nil
                streamingBuffer = pcm
                self.microphone = try recorder.start(config: config, onPCM: pcm.map { buffer in { buffer.append($0) } })
                if config.mode == .streaming { prepareLiveInsertion() }
                if let pcm, let session = recorder.recordingSession { beginStreaming(session, config: config, pcm: pcm, operation: operation) }
                elapsed = 0
                update(.recording, "\(microphone) · ⌃⌘N to finish")
                meterTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        let level = self.recorder.level()
                        // Fast attack and gentle release, driven by actual microphone RMS.
                        self.audioLevel += (level - self.audioLevel) * (level > self.audioLevel ? 0.55 : 0.18)
                    }
                }
                RunLoop.main.add(meterTimer!, forMode: .common)
                timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        self.recorder.writeDiagnostics()
                        self.recordingTick(error: self.recorder.captureFailure())
                    }
                }
                RunLoop.main.add(timer!, forMode: .common)
            } catch is CancellationError { }
            catch { if self.operation == operation { update(.failed, error.localizedDescription) } }
        }
    }
    func recordingTick(error: String?) {
        guard phase == .recording else { return }
        elapsed += 1
        // No duration cutoff. A hardware/storage failure preserves already captured audio.
        if let error {
            liveInsertion?.pause("Microphone capture stopped.")
            streamingTask?.cancel(); streamingBuffer?.abort(); streamingBackend.stop()
            timer?.invalidate(); timer = nil
            _ = try? recorder.stop(userStopped: false)
            savedSession = recorder.recordingSession; allowAutomaticInsertion = false
            update(.failed, error + " Saved audio is retained; Retry processes it without automatic insertion.")
        }
    }
    func finish() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        finishingCapture = true
        processingProgress = ""
        allowAutomaticInsertion = false
        // Acknowledge the shortcut before draining capture or synchronizing files.
        update(.transcribing, "Finishing capture and preparing local transcription…")
        let operation = self.operation
        task = Task {
            defer {
                let waiters = captureDrainWaiters; captureDrainWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            do {
                try await stopCapture(recorder)
                finishingCapture = false
                savedSession = recorder.recordingSession
                guard self.operation == operation, !Task.isCancelled else { cancel(); return }
                guard let session = savedSession else { throw VellaError.message("Missing recording journal. Open Vella Files to recover audio.") }
                streamingBuffer?.close()
                allowAutomaticInsertion = true
                runTranscription(session, liveStream: true)
            } catch {
                streamingTask?.cancel(); streamingBuffer?.abort(); streamingBackend.stop()
                finishingCapture = false
                savedSession = recorder.recordingSession; allowAutomaticInsertion = false
                guard self.operation == operation, !Task.isCancelled else { cancel(); return }
                update(.failed, error.localizedDescription + " Saved audio was kept.")
            }
        }
    }
    private func observeStreaming(_ session: RecordingSession, operation: UUID) throws {
        streamingJournal?.close()
        let journal = try StreamingJournal(directory: session.directory)
        streamingJournal = journal
        streamingBackend.onUpdate = nil
        streamingBackend.onEvent = { [weak self, journal] committed, partial, incomplete in
            guard let self, self.operation == operation else { return }
            // Bounded append, not a growing full-transcript rewrite; the capture
            // queue continues to own its separate PCM files and manifest.
            try journal.append(committed: committed, partial: partial, frames: self.streamingBackend.frames)
            if incomplete {
                self.liveInsertion?.pause("Some audio was not recognized. Live insertion stopped; audio is still saved.")
            } else {
                self.liveInsertion?.offer(committed: committed, partial: partial)
            }
            if self.phase == .recording {
                self.message = self.liveInsertion?.blockedReason ?? "Inserting live · ⌃⌘N to close the microphone."
            }
        }
    }
    private func beginStreaming(_ session: RecordingSession, config: Configuration, pcm: StreamingPCMBuffer, operation: UUID) {
        streamingTask = Task {
            do {
                try observeStreaming(session, operation: operation)
                try await backend.releaseAndWait()
                try Task.checkCancellation()
                guard self.operation == operation else { throw CancellationError() }
                try await streamingBackend.start(config: config)
                while !pcm.isDrained {
                    try Task.checkCancellation()
                    if let data = try pcm.take() { try await streamingBackend.feed(data) }
                    else { try await Task.sleep(nanoseconds: 20_000_000) }
                }
                return try await streamingBackend.finish(expectedFrames: pcm.totalFrames)
            } catch {
                pcm.abort()
                if self.operation == operation {
                    liveInsertion?.pause("Streaming recognition stopped. Audio is still saved.")
                    streamingBackend.stop()
                    try? session.saveStreamingPartial(streamingBackend.text)
                    if phase == .recording {
                        message = "Streaming stopped; the microphone is still saving audio. Finish, then retry the saved recording."
                        onChange?()
                    }
                }
                throw error
            }
        }
    }
    private func runStreamingTranscription(_ session: RecordingSession, live: Bool) {
        let operation = self.operation
        update(.transcribing, live ? "Finalizing streaming transcription…" : "Replaying saved audio through the streaming model. Recovery copies only.")
        task = Task {
            do {
                session.manifest.failureCode = nil; try session.save()
                let text: String
                if live {
                    guard let streamingTask, let pcm = streamingBuffer,
                          pcm.totalFrames == session.manifest.segments.reduce(0, { $0 + $1.frames - $1.overlapFrames }) else {
                        throw VellaError.message("Streaming audio accounting failed. Saved audio is retained; automatic replay is disabled.")
                    }
                    text = try await streamingTask.value
                } else {
                    streamingBackend.onEvent = nil; streamingJournal?.close(); streamingJournal = nil
                    // Keep earlier incomplete recognition instead of overwriting its only copy.
                    try session.preserveStreamingCheckpoint()
                    try await releaseWorkers()
                    try Task.checkCancellation()
                    guard self.operation == operation else { throw CancellationError() }
                    try observeStreaming(session, operation: operation)
                    try await streamingBackend.start(config: session.manifest.config.forRecording())
                    var frames = 0
                    for segment in session.manifest.segments {
                        try Task.checkCancellation()
                        let file = try FileHandle(forReadingFrom: session.directory.appendingPathComponent(segment.filename))
                        defer { try? file.close() }
                        try file.seek(toOffset: UInt64(segment.overlapFrames * 4))
                        var remaining = (segment.frames - segment.overlapFrames) * 4
                        while remaining > 0 {
                            try Task.checkCancellation()
                            let count = min(6400, remaining)
                            guard let data = try file.read(upToCount: count), data.count == count else {
                                throw VellaError.message("Saved streaming audio ended unexpectedly. Files were retained.")
                            }
                            try await streamingBackend.feed(data); remaining -= count; frames += count / 4
                        }
                    }
                    text = try await streamingBackend.finish(expectedFrames: frames)
                }
                try Task.checkCancellation()
                guard self.operation == operation else { return }
                streamingBackend.onEvent = nil; streamingJournal?.close(); streamingJournal = nil
                _ = try session.finalizeTranscript(text)
                lastText = text; lastTranscriptIncomplete = false
                backendStatus = "Vella streaming worker unloaded"
                streamingTask = nil; streamingBuffer = nil
                if live, let insertion = liveInsertion {
                    await insertion.finishStream()
                    try Task.checkCancellation()
                    guard self.operation == operation else { return }
                    insertionWasAutomatic = insertion.didSend
                    if let reason = insertion.blockedReason {
                        insertionWasAutomatic = false
                        copyLast()
                        update(.success, "Live insertion stopped. \(reason) Full transcript copied; previously sent text was not inserted again.")
                    } else {
                        update(.success, "Streaming text sent as you spoke. Full transcript saved; no duplicate final paste and no Enter or Send.")
                    }
                } else { insert(text) }
            } catch {
                guard self.operation == operation else { return }
                streamingBackend.onEvent = nil; streamingJournal?.close(); streamingJournal = nil
                liveInsertion?.pause("Streaming did not finish successfully.")
                streamingBackend.stop(); streamingBuffer?.abort(); streamingTask = nil
                session.manifest.state = "interrupted"
                if error is CancellationError { session.manifest.failureCode = "cancelled" }
                else if case VellaError.noSpeech = error { session.manifest.failureCode = "no_speech" }
                else if case VellaError.unrecognizedAudio = error { session.manifest.failureCode = "unrecognized_audio" }
                else if (error as? URLError)?.code == .timedOut { session.manifest.failureCode = "timeout" }
                else { session.manifest.failureCode = "local_failure" }
                try? session.saveStreamingPartial(streamingBackend.text); try? session.save()
                if let partial = try? session.savePartialTranscript() { lastText = partial; lastTranscriptIncomplete = true }
                allowAutomaticInsertion = false
                let reason: String
                if case VellaError.unrecognizedAudio = error {
                    reason = "Some non-quiet audio returned no words. The transcript is marked incomplete."
                } else { reason = error is CancellationError ? "Streaming stopped before completion." : error.localizedDescription }
                update(.failed, reason + " Audio is saved. Text already sent stays in the target; it will not be replayed automatically. Retry copies only.")
            }
        }
    }
    private func runTranscription(_ session: RecordingSession, liveStream: Bool = false) {
        if session.manifest.config.mode == .streaming { runStreamingTranscription(session, live: liveStream); return }
        let operation = self.operation
        processingProgress = ""
        update(.transcribing, "Transcribing saved segments locally. Estimates exclude unknown model-loading and queue delays.")
        task = Task {
            do {
                let runner = SessionTranscriber(request: transcriptionRequest ?? { [backend] url, config in try await backend.transcribe(url, config: config) })
                try await streamingBackend.releaseAndWait()
                try Task.checkCancellation()
                guard self.operation == operation else { return }
                let speed = CalibrationStore.speed(modelPath: session.manifest.config.model)
                    ?? referenceSpeed?(session.manifest.config.model)
                let pendingAudio = session.manifest.segments.filter { $0.text == nil }.reduce(0.0) { $0 + $1.seconds }
                let showEstimate = TranscriptionEstimate.shouldDisplay(pendingAudioSeconds: pendingAudio, speed: speed)
                runner.onChunk = { [weak self] completed, current, index, count in
                    guard let self, self.operation == operation else { return }
                    self.progressTimer?.invalidate(); self.progressTimer = nil
                    guard showEstimate else { self.processingProgress = ""; return }
                    let start = ProcessInfo.processInfo.systemUptime
                    let refresh = { [weak self] in
                        guard let self, self.operation == operation, self.phase == .transcribing else { return }
                        let estimate = TranscriptionEstimate(totalSeconds: session.seconds, completedSeconds: completed,
                            currentSeconds: current, currentElapsed: ProcessInfo.processInfo.systemUptime - start, speed: speed ?? 0)
                        let remaining = Int(ceil(estimate.remainingSeconds))
                        if let speed {
                            let overdue = ProcessInfo.processInfo.systemUptime - start > max(2, current / speed * 2)
                            self.processingProgress = "≈\(Int(estimate.fraction * 100))% · " + (overdue ? "working…" : "~\(remaining)s")
                        } else {
                            self.processingProgress = "\(Int(estimate.fraction * 100))% · \(index)/\(count)"
                        }
                        self.message = "Segment \(index)/\(count). Estimated, not measured completion. Model loading or a busy server can take longer. Audio and completed text are saved."
                    }
                    refresh()
                    let timer = Timer(timeInterval: 0.2, repeats: true) { _ in Task { @MainActor in refresh() } }
                    self.progressTimer = timer; RunLoop.main.add(timer, forMode: .common)
                }
                var observedAudio = 0.0, observedProcessing = 0.0
                runner.onObservation = { _, audio, processing in
                    observedAudio += audio; observedProcessing += processing
                }
                let text = try await runner.run(session)
                if observedAudio > 0 {
                    CalibrationStore.observe(modelPath: session.manifest.config.model, audioSeconds: observedAudio, processingSeconds: observedProcessing)
                }
                try Task.checkCancellation()
                guard self.operation == operation else { return }
                progressTimer?.invalidate(); progressTimer = nil; processingProgress = showEstimate ? "100%" : ""
                lastText = text; lastTranscriptIncomplete = false; backendStatus = backend.ownership
                // Audio and transcript are durable BEFORE attempting insertion; retained until explicit deletion.
                insert(text)
                let quiet = session.manifest.segments.reduce(0) { $0 + ($1.quietSlices ?? 0) }
                if quiet > 0 { message += " \(quiet) very quiet interval(s) returned no recognized speech; original audio remains saved." }
            } catch {
                guard self.operation == operation else { return }
                progressTimer?.invalidate(); progressTimer = nil
                processingProgress = ""
                session.manifest.state = "interrupted"
                if error is CancellationError { session.manifest.failureCode = "cancelled" }
                else if case VellaError.noSpeech = error { session.manifest.failureCode = "no_speech" }
                else if case VellaError.unrecognizedAudio = error { session.manifest.failureCode = "unrecognized_audio" }
                else if (error as? URLError)?.code == .timedOut { session.manifest.failureCode = "timeout" }
                else { session.manifest.failureCode = "local_failure" }
                try? session.save()
                if let partial = try? session.savePartialTranscript() { lastText = partial; lastTranscriptIncomplete = true }
                allowAutomaticInsertion = false
                let reason = error is CancellationError ? "Local transcription stopped before completion." : error.localizedDescription
                update(.failed, reason + " Audio and completed segments are saved. Retry resumes unfinished segments; recovery copies only.")
            }
        }
    }
    func retry() {
        guard phase == .failed, let savedSession else { return }
        recover(savedSession.directory)
    }
    func recover(_ directory: URL) {
        guard !busy, phase != .recording else { return }
        liveInsertion?.cancel(); liveInsertion = nil
        operation = UUID(); let operation = self.operation
        target = nil; allowAutomaticInsertion = false
        update(.preparing, "Checking saved audio integrity…")
        task = Task {
            do {
                let recovered = try await RecordingSession.recover(directory)
                try Task.checkCancellation()
                guard self.operation == operation else { return }
                savedSession = recovered
                runTranscription(recovered)
            } catch is CancellationError { }
            catch { if self.operation == operation { update(.failed, error.localizedDescription) } }
        }
    }
    func cancel() {
        let liveTextWasSent = liveInsertion?.didSend == true
        operation = UUID(); task?.cancel(); task = nil; stopWorkers(); timer?.invalidate(); timer = nil
        progressTimer?.invalidate(); progressTimer = nil; allowAutomaticInsertion = false
        if finishingCapture {
            // The capture queue still owns the journal. Settle cancellation only
            // after its drain finishes; don't race a manifest write or new capture.
            update(.transcribing, "Stopping capture and keeping saved audio…")
            return
        }
        if phase == .recording {
            _ = try? recorder.stop(userStopped: false); savedSession = recorder.recordingSession
        }
        if let savedSession, savedSession.manifest.state != "transcribed" {
            savedSession.manifest.state = "interrupted"; try? savedSession.save()
            if let partial = try? savedSession.savePartialTranscript() { lastText = partial; lastTranscriptIncomplete = true }
        }
        update(.idle, liveTextWasSent
            ? "Stopped. Previously streamed text stays in the target; audio and checkpoints are saved."
            : "Stopped. Audio and completed text remain in Saved Recordings; nothing was pasted.")
    }
    func deleteSavedRecording() throws {
        guard !busy, phase != .recording, let savedSession else { return }
        try FileManager.default.removeItem(at: savedSession.directory)
        self.savedSession = nil; recorder.discard(); lastText = ""
        update(.idle, "Saved recording deleted.")
    }
    private func focused(_ attribute: CFString) -> AXUIElement? {
        guard let target else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(target.processIdentifier), attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func captureTargetFocus() {
        AccessibilityFocus.prepare(target)
        targetElement = focused(kAXFocusedUIElementAttribute as CFString)
        targetWindow = focused(kAXFocusedWindowAttribute as CFString)
        if let element = targetElement {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if !AccessibilityFocus.isFieldRole(role as? String) { targetElement = nil }
        }
    }
    private var targetFocusBlockReason: String? {
        guard let targetElement, let targetWindow else {
            return "The original text field wasn't available through accessibility. Focus the field, wait a moment, then start a new recording."
        }
        guard let element = focused(kAXFocusedUIElementAttribute as CFString),
              let window = focused(kAXFocusedWindowAttribute as CFString) else {
            return "The target application isn't exposing its focused text field."
        }
        guard CFEqual(targetWindow, window) else { return "The original window is no longer focused." }
        guard CFEqual(targetElement, element) else { return "The original text field changed or is no longer focused." }
        return nil
    }
    func preparePasteCheck(to target: NSRunningApplication) {
        self.target = target; captureTargetFocus(); allowAutomaticInsertion = true
    }
    func finishPasteCheck() { insert("Vella paste verification.") }
    func checkPaste(to target: NSRunningApplication) { preparePasteCheck(to: target); finishPasteCheck() }
    static let clipboardRestoreLimit = 64 * 1024
    static func clipboardTextToRestore(_ pasteboard: NSPasteboard, eligible: Bool) -> String? {
        // Never request image/file/rich-text representations or read the clipboard for
        // copy-only insertion. Restore only one small, exclusively plain-text item.
        // AppKit offers no byte-count preflight; a text provider may transiently return
        // more than the limit, but oversized data is never decoded or retained.
        guard eligible, let items = pasteboard.pasteboardItems, items.count == 1,
              items[0].types == [.string], let data = items[0].data(forType: .string),
              data.count <= clipboardRestoreLimit else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func restoreClipboardText(_ text: String, to pasteboard: NSPasteboard, changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    private var automaticInsertionBlockReason: String? {
        guard allowAutomaticInsertion else { return "Recovered or cancelled recordings are clipboard-only." }
        return currentTargetBlockReason
    }
    private var currentTargetBlockReason: String? {
        guard AXIsProcessTrusted() else { return "Enable Accessibility for Vella to insert automatically." }
        guard let target, !target.isTerminated, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "The original application is unavailable."
        }
        guard target.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return "The original application is no longer in front."
        }
        return targetFocusBlockReason
    }
    private func prepareLiveInsertion() {
        let insertion = LiveInsertion(targetIsCurrent: { [weak self] in
            guard let self, self.phase == .recording || self.phase == .transcribing else { return false }
            // Explicit roaming mode: the OS routes text to current keyboard focus.
            // Delayed words may cross fields; the user controls speech/navigation.
            return AXIsProcessTrusted()
        }, send: LiveInsertion.nativeSend, monitorUserInput: false)
        insertion.onBlocked = { [weak self] reason in
            guard let self, self.phase == .recording else { return }
            self.message = "Live insertion paused: \(reason) Microphone capture continues."
            self.onChange?()
        }
        liveInsertion = insertion
    }
    private func insert(_ text: String) {
        insertionWasAutomatic = false
        // A fully resolved quiet recording is a normal no-op, not a failed
        // transcription or an empty paste that erases the user's selection.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update(.idle, "No speech recognized. Audio remains saved.")
            return
        }
        let pasteboard = self.pasteboard
        let initialBlockReason = automaticInsertionBlockReason
        let eligible = initialBlockReason == nil
        let down = eligible ? CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) : nil
        let up = eligible ? CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) : nil
        let original = Self.clipboardTextToRestore(pasteboard, eligible: eligible && down != nil && up != nil)
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let count = pasteboard.changeCount
        // A lazy text provider can take time: recheck focus before posting any key.
        let finalBlockReason = automaticInsertionBlockReason
        guard eligible && finalBlockReason == nil else {
            update(.success, "Copied to clipboard. Paste with ⌘V. " + (initialBlockReason ?? finalBlockReason ?? "Automatic insertion is unavailable."))
            return
        }
        // Never send Return. Do not switch focus back if the user moved elsewhere.
        guard let down, let up else {
            update(.success, "Copied to clipboard. Paste with ⌘V."); return
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        insertionWasAutomatic = true
        update(.success, "Paste sent. No Enter or Send. Last transcript remains available in the menu.")
        if let original {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Self.restoreClipboardText(original, to: pasteboard, changeCount: count)
            }
        }
    }
    func copyLast() { pasteboard.clearContents(); pasteboard.setString(lastText, forType: .string) }
    func accessibility() { insertionPermission.openSettings() }
    func chooseMicrophone(_ name: String) {
        do {
            var config = try backend.configuration(requiresModel: false); config.preferredMicrophone = name
            try JSONEncoder().encode(config).write(to: Backend.configURL, options: .atomic)
            microphone = name + " → MacBook fallback"
        } catch { update(.failed, error.localizedDescription) }
    }
    func shutdown() { cancel(); backend.shutdown(); streamingBackend.shutdown() }
    func shutdownAfterCaptureDrain() async {
        cancel()
        if finishingCapture {
            await withCheckedContinuation { captureDrainWaiters.append($0) }
        }
        backend.shutdown()
        streamingBackend.shutdown()
    }
}

@main struct VellaMain {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--check-live-insertion-fixture"), CommandLine.arguments.count > index + 1 {
            let model = CommandLine.arguments.firstIndex(of: "--fixture-model").flatMap { i in
                CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            }
            LiveInsertionProbe.run(project: URL(fileURLWithPath: CommandLine.arguments[index + 1]), modelPath: model); return
        }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--session-crash-fixture"), CommandLine.arguments.count > index + 1 {
            do {
                let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let session = try RecordingSession(root: root, config: Configuration(executable: "/qa/unused", model: "/qa/unused"))
                let writer = try SegmentedPCMWriter(session: session)
                let samples = [Float](repeating: 0.1, count: 34_000)
                try samples.withUnsafeBufferPointer { try writer.append($0) }
                _exit(37) // Deliberate process death: no finish, deinit or WAV-header finalization.
            } catch { _exit(38) }
        }
        #endif
        let application = NSApplication.shared
        #if DEBUG
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-model-table" {
            application.setActivationPolicy(.prohibited)
            let host = NSHostingView(rootView: ModelTable(library: ModelLibrary()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 368), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 640, height: 368)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                    }
                }
                application.terminate(nil)
            }
            withExtendedLifetime(window) { application.run() }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-preview" {
            application.setActivationPolicy(.accessory)
            let model = Model()
            model.phase = .recording; model.audioLevel = 0.65
            let renderer = ImageRenderer(content: HUDView(model: model, previewTime: 1.2, previewEntryAge: 2))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--check-browser-accessibility") || CommandLine.arguments.contains("--check-browser-paste") {
            application.setActivationPolicy(.accessory)
            Task { await BrowserPasteProbe.run() }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--check-paste") {
            application.setActivationPolicy(.accessory)
            Task { await PasteProbe.run() }
            application.run()
            return
        }
        // Bounded native capture QA in this same signed app; no transcription or insertion.
        if CommandLine.arguments.contains("--check-capture") {
            application.setActivationPolicy(.accessory)
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                print("Capture check requires existing microphone approval; no permission prompt was issued."); return
            }
            let recorder = Recorder()
            DispatchQueue.main.async {
                do {
                    var config = try Backend().configuration()
                    if CommandLine.arguments.contains("--check-fallback") { config.preferredMicrophone = "Unavailable QA microphone" }
                    let device = try recorder.start(config: config, recordingsRoot: Backend.support.appendingPathComponent("QARecordings"))
                    print("Checking capture from \(device)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        do { _ = try recorder.stop(); print("Capture received PCM frames; speech recognition is not established by this check") }
                        catch { print("Capture check failed: \(error.localizedDescription)") }
                        if let directory = recorder.recordingSession?.directory { try? FileManager.default.removeItem(at: directory) }
                        recorder.discard(); application.terminate(nil)
                    }
                } catch { print("Capture check failed: \(error.localizedDescription)"); application.terminate(nil) }
            }
            withExtendedLifetime(recorder) { application.run() }
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
