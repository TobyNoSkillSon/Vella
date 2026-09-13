import AppKit
import AVFoundation
import VellaCore

/// Explicit, local QA only. Owns its disposable editor; never targets a user field.
@MainActor enum LiveInsertionProbe {
    final class Editor: NSTextView {
        var enterEvents = 0
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 { enterEvents += 1 }
            super.keyDown(with: event)
        }
    }
    static func run(project: URL, modelPath: String? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.appearance = NSAppearance(named: .darkAqua)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard AXIsProcessTrusted() else { print("Live insertion QA requires LaunchServices-granted Vella Accessibility access."); return }
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "dev.vella.dictation" && $0.processIdentifier != pid
        }) else { print("Live insertion QA requires no other running Vella instance."); return }
        let directory = project.appendingPathComponent(".build/qa/live-insertion")
        guard FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Package.swift").path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = NSWorkspace.shared.frontmostApplication
        let marker = "Vella disposable live-insertion fixture"
        let window = NSWindow(contentRect: NSRect(x: 160, y: 220, width: 620, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = marker; window.isReleasedWhenClosed = false
        let editor = Editor(frame: NSRect(x: 12, y: 12, width: 596, height: 144))
        editor.string = "Fixture: "; editor.font = .systemFont(ofSize: 17)
        editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        window.contentView?.addSubview(editor)
        let secondWindow = NSWindow(contentRect: NSRect(x: 180, y: 420, width: 620, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        secondWindow.title = marker + " · second window"; secondWindow.isReleasedWhenClosed = false
        let second = Editor(frame: editor.frame)
        second.string = "Second: "; second.font = editor.font
        second.textColor = .textColor; second.backgroundColor = .textBackgroundColor
        second.isAutomaticSpellingCorrectionEnabled = false; second.isAutomaticTextReplacementEnabled = false
        secondWindow.contentView?.addSubview(second)
        let backend = StreamingBackend()
        let insertion = LiveInsertion(targetIsCurrent: {
            // QA confines writes to its OWN two fixtures. Production roaming only
            // checks session lifetime and permission, not window/field identity.
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
                ((window.isKeyWindow && window.firstResponder === editor) ||
                 (secondWindow.isKeyWindow && secondWindow.firstResponder === second))
        }, monitorUserInput: false)
        Task {
            var report: [String: Any] = ["passed": false, "nativeTrust": AXIsProcessTrusted()]
            var journal: StreamingJournal?
            defer {
                insertion.cancel(); backend.onUpdate = nil; backend.onEvent = nil; backend.shutdown(); journal?.close()
                report["enterEvents"] = editor.enterEvents + second.enterEvents
                report["blockedReason"] = insertion.blockedReason ?? ""
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("probe.json"), options: .atomic)
                    print(String(decoding: data, as: UTF8.self))
                }
                let ownedFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                window.close(); secondWindow.close()
                if ownedFocus { previous?.activate(options: []) }
                app.terminate(nil)
            }
            do {
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                app.activate(ignoringOtherApps: true)
                try await Task.sleep(nanoseconds: 300_000_000)
                var config = try Backend().configuration(requiresModel: false); config.mode = .streaming
                if let modelPath { config.streamingModel = modelPath } // QA snapshot only; never save selections.
                let snapshot = try config.forRecording()
                let audio = try AVAudioFile(forReading: ModelLibrary.resourceDirectory().appendingPathComponent("Calibration/speech.wav"))
                guard audio.processingFormat.sampleRate == 16000, audio.processingFormat.channelCount == 1 else { throw VellaError.message("Invalid public QA fixture.") }
                let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1600)!
                let runDirectory = directory.appendingPathComponent("run-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
                let events = try StreamingJournal(directory: runDirectory); journal = events
                backend.onEvent = { committed, partial, _ in
                    try events.append(committed: committed, partial: partial, frames: backend.frames)
                    insertion.offer(committed: committed, partial: partial)
                }
                try await backend.start(config: snapshot)
                var firstVisible: Double?
                let began = ProcessInfo.processInfo.systemUptime
                var frames = 0
                var switched = false
                while audio.framePosition < audio.length {
                    try audio.read(into: pcm, frameCount: 1600)
                    try await backend.feed(Data(bytes: pcm.floatChannelData![0], count: Int(pcm.frameLength) * 4))
                    frames += Int(pcm.frameLength)
                    let due = began + Double(frames) / 16000
                    let delay = due - ProcessInfo.processInfo.systemUptime
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    if firstVisible == nil, editor.string != "Fixture: " { firstVisible = ProcessInfo.processInfo.systemUptime - began }
                    if !switched, audio.framePosition >= audio.length / 2 {
                        try await Task.sleep(nanoseconds: 200_000_000)
                        secondWindow.makeKeyAndOrderFront(nil); secondWindow.makeFirstResponder(second)
                        // Actual local mouse events, sent only to our fixture window.
                        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                            if let click = NSEvent.mouseEvent(with: type, location: NSPoint(x: 550, y: 142), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: secondWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                                app.postEvent(click, atStart: false)
                            }
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                        second.setSelectedRange(NSRange(location: (second.string as NSString).length, length: 0))
                        switched = true
                    }
                }
                report["partialBeforeFinish"] = firstVisible != nil
                report["firstVisibleSeconds"] = firstVisible ?? -1
                editor.displayIfNeeded()
                if let image = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
                    editor.cacheDisplay(in: editor.bounds, to: image)
                    try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("before-finish.png"))
                }
                let final = try await backend.finish(expectedFrames: frames)
                await insertion.finishStream()
                try await Task.sleep(nanoseconds: 300_000_000)
                let combined = String(editor.string.dropFirst("Fixture: ".count)) + String(second.string.dropFirst("Second: ".count))
                let exact = combined == LiveInsertion.sanitize(final)
                report["followedFocusToSecondWindow"] = second.string != "Second: "
                if let image = second.bitmapImageRepForCachingDisplay(in: second.bounds) {
                    second.cacheDisplay(in: second.bounds, to: image)
                    try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("second-window.png"))
                }
                report["finalTextAcceptedExactlyOnce"] = exact
                events.close()
                report["journalRecoveredFullText"] = try StreamingJournal.recover(directory: runDirectory)?.hasSuffix(final) == true
                report["passed"] = firstVisible != nil && exact && second.string != "Second: " && insertion.blockedReason == nil && editor.enterEvents + second.enterEvents == 0
                // Exercise the sibling imports that used to mutate signed .pyc files.
                try await backend.releaseAndWait()
                let dictation = Backend()
                defer { dictation.shutdown() }
                config.mode = .dictation
                let text = try await dictation.transcribe(ModelLibrary.resourceDirectory().appendingPathComponent("Calibration/speech.wav"), config: config.forRecording())
                report["dictationWorkerCompleted"] = !text.isEmpty
                // Inspect the actual native Models view using bundled results.
                let library = ModelLibrary(mode: .streaming)
                let menus = ModelsMenu(library: library)
                if let table = menus.modelItem().submenu?.items.first?.view {
                    let material = NSVisualEffectView(frame: table.frame)
                    material.material = .menu; material.blendingMode = .withinWindow; material.state = .active
                    material.addSubview(table)
                    secondWindow.setContentSize(table.frame.size); secondWindow.contentView = material
                    try await Task.sleep(nanoseconds: 300_000_000)
                    table.layoutSubtreeIfNeeded()
                    if let image = material.bitmapImageRepForCachingDisplay(in: material.bounds) {
                        material.cacheDisplay(in: material.bounds, to: image)
                        try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("streaming-models.png"))
                    }
                    report["streamingMenuRows"] = library.displayedModels.map(\.id)
                    report["streamingMeasuredRows"] = library.displayedModels.filter { library.references[$0.id] != nil }.map(\.id)
                }
            } catch { report["error"] = error.localizedDescription; report["passed"] = false }
        }
        app.run()
    }
}
