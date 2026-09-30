import AppKit
import SwiftUI
import AVFoundation
import Carbon
import ApplicationServices
import QuartzCore
import VellaCore

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
                let session = try RecordingSession(root: root, config: Configuration(model: "/qa/unused"))
                let writer = try SegmentedPCMWriter(session: session)
                let samples = [Float](repeating: 0.1, count: 34_000)
                try samples.withUnsafeBufferPointer { try writer.append($0) }
                _exit(37) // Deliberate process death: no finish, deinit or WAV-header finalization.
            } catch { _exit(38) }
        }
        #endif
        let application = NSApplication.shared
        // Render harness (Models table and menu states to PNGs; no worker, no settings written).
        if CommandLine.arguments.count == 3, ["--render-table", "--render-menu"].contains(CommandLine.arguments[1]) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let delegate: NSApplicationDelegate = CommandLine.arguments[1] == "--render-table"
                ? TableRenderDelegate(directory: directory) : MenuRenderDelegate(directory: directory)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
            return
        }
        #if DEBUG
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-preview" {
            application.setActivationPolicy(.accessory)
            let model = DictationController()
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
        // Menu and table ↔ runtime; then publish an empty worker status and load the launch set (manual loads only;
        // nothing on a fresh install).
        RuntimeBridge.shared.attach(delegate)
        RuntimeBridge.shared.migrateRegistry()         // removed models leave the registry (their files stay)
        RuntimeBridge.shared.sweepPartialDownloads()   // stale .incomplete partials in Vella's Models folder
        DispatchQueue.main.async { Runtime.shared.start() }
        // The local HTTP API (loopback; port in worker-status.json) for the `vella` command and agents.
        DispatchQueue.main.async { delegate.startAPI() }
        withExtendedLifetime(delegate) { application.run() }
    }
}
