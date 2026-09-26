import AppKit
import SwiftUI
import VellaCore
import VellaUpdate

// Render harness after the Verdict-family pattern (Verdict 95ddba5, Sources/Verdict/TableRenders.swift).
// Neither mode starts a worker, downloads, or writes settings: libraries use a temporary registry, the controller is
// in preview mode, and the menu's model uses a temporary configuration file.
// VELLA_BENCHMARKS=<file> renders against a fixture; VELLA_RENDER_CHIP='Apple M3 Pro' renders as another Mac.

@MainActor enum RenderFixture {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-render-\(ProcessInfo.processInfo.processIdentifier)")
    static var chip: String { displayChip(ProcessInfo.processInfo.environment["VELLA_RENDER_CHIP"]) ?? "M5 Max" }

    /// A preview controller over the real catalog with isolated libraries and the given downloads.
    static func controller(installed: [String] = []) -> ModelsController {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("models-installed.json")
        let resources = ModelLibrary.resourceDirectory()
        let dictation = ModelLibrary(mode: .dictation, resources: resources, registryURL: registry, calibration: CalibrationStore(directory: root.appendingPathComponent("Calibrations"), resources: resources))
        let streaming = ModelLibrary(mode: .streaming, resources: resources, registryURL: registry)
        let controller = ModelsController(dictation: dictation, streaming: streaming)
        controller.previewing = true
        controller.actions = previewActions   // buttons render enabled, as with a running runtime; perform() is a no-op in preview
        setInstalled(controller, installed)
        return controller
    }
    static func setInstalled(_ controller: ModelsController, _ ids: [String]) {
        for library in [controller.dictation, controller.streaming] {
            library.installed = [:]
            for id in ids where library.models.contains(where: { $0.id == id }) { library.installed[id] = InstalledModel(path: "/render/\(id)") }
        }
    }
    static let downloaded = ["parakeet-tdt-0.6b-v3-mlx-4bit", "parakeet-tdt-0.6b-v3-mlx-8bit", "Qwen3-ASR-1.7B-bf16", "Qwen3-ASR-1.7B-4bit",
                             "nemotron-3.5-asr-streaming-0.6b-8bit"]
    static let optimized: [String: Bool] = ["encoder": true, "decoder": true]
    static let previewActions = PreviewActions()
}

/// Runtime stand-in for renders: nothing loads.
@MainActor final class PreviewActions: ModelRuntimeActions {
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) {}
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String) {}
    func unload(family: ModelFamily) {}
    func delete(family: ModelFamily, path: String, delete: @escaping @MainActor () -> Bool) async -> Bool { false }
}

@MainActor final class TableRenderDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    @MainActor struct State {
        var name: String
        var installed: [String] = RenderFixture.downloaded
        var runtime = TableRuntime(chip: RenderFixture.chip)
        /// Previewed segments (a click, not yet loaded).
        var selections: [String: String] = [:]
        /// config.json: the modes' models and lastLoaded (what an unloaded row shows).
        var config: Configuration? = nil
        var lastError: String? = nil
        var downloadError: String? = nil
        var downloading: (id: String, progress: Double)? = nil
        var benchmarks: BenchmarkFile? = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        let chip = RenderFixture.chip
        var states: [State] = []
        states.append(State(name: "fresh-nothing-downloaded", installed: []))
        states.append(State(name: "downloaded-nothing-loaded"))
        // Nothing loaded: each row shows the precision it was last loaded at (Parakeet v3 4 is dictation's model,
        // Qwen was last loaded at 16, Nemotron 8 is streaming's model); rows never loaded show the recommended one.
        var lastLoaded = State(name: "unloaded-shows-last-loaded")
        lastLoaded.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-4bit", streaming: "nemotron-3.5-asr-streaming-0.6b-8bit",
                                        lastLoaded: ["qwen3-asr-1.7b": "BF16"])
        states.append(lastLoaded)
        var loaded = State(name: "loaded")
        loaded.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-4bit", streaming: "nemotron-3.5-asr-streaming-0.6b-8bit")
        loaded.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual"),
                                 "nemotron-3.5-streaming-0.6b": LoadedFamily(precision: "8b", engine: "optimized", optimizations: ["encoder": true], residency: "on_demand")]
        states.append(loaded)
        // Toby's 1.0.0 case: Parakeet v3 loaded at 4 (config said FP32). The row shows 4 with Unload; clicking 32 is a
        // preview with its numbers, deltas and the green Reload (which asks before the 2.5 GB download).
        var bug = State(name: "parakeet-4-loaded-preview-32-reload")
        bug.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-4bit")
        bug.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "on_demand")]
        bug.selections = ["parakeet-v3": "FP32"]
        states.append(bug)
        var reload = State(name: "qwen-16-loaded-preview-8-reload")
        reload.runtime.loaded = ["qwen3-asr-1.7b": LoadedFamily(precision: "BF16", engine: "optimized", optimizations: ["decoder": true, "prefill": true], residency: "manual")]
        reload.selections = ["qwen3-asr-1.7b": "8b"]
        states.append(reload)
        // Precisions made on this Mac, selected before measurement: figures read \u{2014}; Get downloads the source,
        // Load appears once the source is downloaded (Ultra BF16 here).
        var derived = State(name: "derived-selected-unmeasured")
        derived.installed = RenderFixture.downloaded + ["parakeet-ultra-mlx-bf16"]
        derived.selections = ["parakeet-v3": "BF16", "parakeet-v3-ultra": "4b", "nemotron-3.5-streaming-0.6b": "4b"]
        states.append(derived)
        var derivedLoaded = State(name: "derived-loaded")
        derivedLoaded.installed = RenderFixture.downloaded + ["parakeet-ultra-mlx-bf16"]
        derivedLoaded.runtime.loaded = ["parakeet-v3-ultra": LoadedFamily(precision: "8b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual")]
        states.append(derivedLoaded)
        var fallback = State(name: "mlx-fallback")
        fallback.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "mlx",
            engineReason: "the optimized path returned non-finite values during a dictation; switched to the stock MLX path until reload",
            optimizations: ["encoder": false, "decoder": false], residency: "manual")]
        states.append(fallback)
        var partly = State(name: "partly-optimized")
        partly.runtime.loaded = ["qwen3-asr-1.7b": LoadedFamily(precision: "8b", engine: "mlx", engineReason: "the fused prefill self-test failed on this Mac",
            optimizations: ["decoder": true, "prefill": false], residency: "on_demand")]
        states.append(partly)
        var loadingState = State(name: "footer-loading")
        loadingState.runtime.loading = "qwen3-asr-1.7b"
        states.append(loadingState)
        // After Download in the popup: the row shows the downloading precision with its progress; it loads when done.
        var downloading = State(name: "footer-downloading")
        downloading.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-4bit")
        downloading.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "on_demand")]
        downloading.downloading = ("parakeet-tdt-0.6b-v3-mlx-fp32", 0.23)
        downloading.selections = ["parakeet-v3": "FP32"]
        states.append(downloading)
        // A stalled download ends with its reason on the footer's error line; its partial files are gone.
        var failed = State(name: "footer-download-failed")
        failed.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-4bit")
        failed.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "on_demand")]
        failed.downloadError = "Parakeet v3 FP32 download failed: it stalled (no data from Hugging Face for 2 minutes). Partial files removed."
        states.append(failed)
        var refusedLong = State(name: "footer-error-long")
        refusedLong.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual")]
        refusedLong.runtime.refusal = TableRefusal(message: "Qwen3 ASR 1.7B at BF16 needs ~4.2 GB; ~0.9 GB free without swapping. Unload Parakeet v3, pick 4-bit, or allow swap in Vella → Memory.", at: now)
        states.append(refusedLong)
        var refusedShort = State(name: "footer-error-short")
        refusedShort.runtime.refusal = TableRefusal(message: "Qwen3 ASR 1.7B at BF16 needs ~4.2 GB; ~0.9 GB free.", at: now)
        states.append(refusedShort)
        var otherChip = State(name: "other-chip-M3-Pro")
        otherChip.runtime.chip = chip == "M3 Pro" ? "M5 Max" : "M3 Pro"
        states.append(otherChip)
        states.append(State(name: "unmeasured-no-benchmarks", benchmarks: BenchmarkFile()))
        writeEngineTooltips(states)
        render(states, 0)
    }

    /// A config.json whose modes' models are the render fixture's installed paths.
    static func config(dictation: String? = nil, streaming: String? = nil, lastLoaded: [String: String] = [:]) -> Configuration {
        var config = Configuration(model: dictation.map { "/render/\($0)" } ?? "")
        config.streamingModel = streaming.map { "/render/\($0)" } ?? ""
        config.lastLoaded = lastLoaded
        return config
    }

    /// The download confirmation popups (`download-prompt-*.png` and their text in download-prompts.txt).
    private func renderPrompts(_ controller: ModelsController, done: @escaping () -> Void) {
        let catalog = controller.catalog
        let free = freeDiskBytes(at: FileManager.default.temporaryDirectory)
        var prompts: [(String, DownloadPrompt)] = []
        if let f = catalog.family("parakeet-v3"), let p = downloadPrompt(family: f, precision: "FP32", followUp: .reload(from: "4b"), freeBytes: free) {
            prompts.append(("reload-parakeet-32", p))
        }
        if let f = catalog.family("parakeet-v3-ultra"), let p = downloadPrompt(family: f, precision: "8b", followUp: .load, freeBytes: free) {
            prompts.append(("derived-ultra-8", p))
        }
        // The first-dictation Get row offers the first offered dictation model at its recommended precision.
        if let f = catalog.offered(.dictation).first, let p = downloadPrompt(family: f, precision: controller.recommended(f) ?? f.native, followUp: .transcribe, freeBytes: free) {
            prompts.append(("first-dictation", p))
        }
        let text = prompts.map { "\($0.0)\n\($0.1.title)\n\n\($0.1.body)\n" }.joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("download-prompts.txt"), atomically: true, encoding: .utf8)
        func next(_ index: Int) {
            guard index < prompts.count else { done(); return }
            Self.renderAlert(DownloadGate.alert(prompts[index].1), to: directory.appendingPathComponent("download-prompt-\(prompts[index].0).png")) { next(index + 1) }
        }
        next(0)
    }
    /// An NSAlert's panel in dark mode, captured offscreen onto the dark alert background (the real panel is vibrant;
    /// the capture has no default-button tint because the offscreen window is not key).
    static func renderAlert(_ alert: NSAlert, to url: URL, done: @escaping () -> Void) {
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.layout()
        let window = alert.window
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000)); window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { window.orderOut(nil); done(); return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                out.size = rep.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: rep.size), xRadius: 16, yRadius: 16).fill()
                rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                try? out.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil); done()
        }
    }

    private func writeEngineTooltips(_ states: [State]) {
        var text: [String] = []
        for state in states {
            for (id, m) in state.runtime.loaded.sorted(by: { $0.key < $1.key }) {
                text.append("\(state.name) / \(id): \(engineLabel(engine: m.engine, chip: state.runtime.chip))\n"
                            + engineHelp(engine: m.engine, reason: m.engineReason, optimizations: m.optimizations, chip: state.runtime.chip, precision: m.precision) + "\n")
            }
        }
        try? text.joined(separator: "\n").write(to: directory.appendingPathComponent("engine-tooltips.txt"), atomically: true, encoding: .utf8)
    }

    private func render(_ states: [State], _ index: Int) {
        guard index < states.count else {
            // Table tooltips for one representative state (a PNG cannot hover).
            let controller = RenderFixture.controller(installed: RenderFixture.downloaded)
            controller.runtime = TableRuntime(chip: RenderFixture.chip)
            let table = ModelTable(controller: controller)
            let headers = ["Header · WER: \(ModelTable.werHeaderHelp)", "Header · Format: \(ModelTable.formatHeaderHelp)", "Header · Speed: \(ModelTable.speedHeaderHelp)", ""]
            let lines = headers + [RecognitionMode.dictation, .streaming].flatMap { mode in
                controller.families(mode).flatMap { family in table.tooltips(family).map { "\(family.name) · \($0.0): \($0.1)" } + [""] }
                    + controller.references(mode).flatMap { r in table.tooltips(r).map { "\(r.name) · \($0.0): \($0.1)" } + [""] }
            }
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("table-tooltips.txt"), atomically: true, encoding: .utf8)
            renderPrompts(controller) {
                try? FileManager.default.removeItem(at: RenderFixture.root)
                NSApp.terminate(nil)
            }
            return
        }
        let state = states[index]
        let controller = RenderFixture.controller(installed: state.installed)
        if let b = state.benchmarks { controller.benchmarks = b }
        controller.runtime = state.runtime
        controller.previewConfig(state.config)
        controller.previewSelections(state.selections)
        controller.lastError = state.lastError
        controller.dictation.downloadError = state.downloadError
        if let d = state.downloading, let library = [controller.dictation, controller.streaming].first(where: { $0.models.contains { $0.id == d.id } }) {
            library.downloadingID = d.id; library.busy = true; library.progress = d.progress
            let total = library.models.first { $0.id == d.id }?.downloadBytes ?? 0
            library.message = "Parakeet v3 FP32 \u{00b7} Downloading from Hugging Face… \(formatBytes(Int64(Double(total) * d.progress))) of \(formatBytes(total))"
        }
        TableRenderDelegate.renderTable(controller, to: directory.appendingPathComponent("models-\(state.name).png")) { [self] in
            render(states, index + 1)
        }
    }

    /// The table on the menu's dark panel colour, as it appears inside the Models… submenu.
    static func renderTable(_ controller: ModelsController, to url: URL, done: @escaping () -> Void) {
        let table = MenuTableHostingView(rootView: ModelTable(controller: controller))
        table.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(controller))
        let container = NSView(frame: table.frame.insetBy(dx: -12, dy: -10))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor
        container.layer?.cornerRadius = 10
        table.frame.origin = NSPoint(x: 12, y: 10)
        container.addSubview(table)
        container.appearance = NSAppearance(named: .darkAqua)
        MenuMock.capture(container, to: url, done: done)
    }
}

@MainActor final class MenuRenderDelegate: NSObject, NSApplicationDelegate {
    let directory: URL

    static let sampleRelease = ReleaseInfo(tag: "v1.0.1", version: SemanticVersion("1.0.1")!, name: "Vella 1.0.1", body: """
        ## 1.0.1

        **Faster first load.** Models load in about half the time.
        - Fixes the menu staying open after a paste.

        ## Verify

            gh attestation verify Vella-1.0.1-arm64.zip --repo TobyNoSkillSon/Vella
        """)

    /// `update-menu.png` (a newer release offered under Support) and `update-popup.png` (the confirmation).
    private func renderUpdate(done: @escaping () -> Void) {
        let release = Self.sampleRelease
        app.menuSettings = DefaultMenuSettings(availableMB: 86_900)
        app.factLine = { nil }; app.model.lastText = ""; app.pendingModelRow = { nil }
        app.updates.preview(.available(release)); app.rebuildMenu()
        MenuMock.render(app.menu.items, width: 340, to: directory.appendingPathComponent("update-menu.png")) { [self] in
            let alert = app.updates.confirmation(release)
            alert.window.appearance = NSAppearance(named: .darkAqua)
            alert.layout()
            let window = alert.window
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000)); window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                // Layer-backed controls draw only through their layers offscreen: render the layer tree over the
                // dark alert colour.
                if let view = window.contentView, let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: Int(view.bounds.width * window.backingScaleFactor), pixelsHigh: Int(view.bounds.height * window.backingScaleFactor),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                    window.displayIfNeeded()
                    rep.size = view.bounds.size          // points; set before the context so it draws at the backing scale
                    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { window.orderOut(nil); done(); return }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).setFill()
                    NSBezierPath(roundedRect: NSRect(origin: .zero, size: view.bounds.size), xRadius: 16, yRadius: 16).fill()
                    if let layer = view.layer { layer.render(in: context.cgContext) } else { view.displayIgnoringOpacity(view.bounds, in: context) }
                    NSGraphicsContext.restoreGraphicsState()
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("update-popup.png"))
                }
                window.orderOut(nil)
                done()
            }
        }
    }

    private var app: AppDelegate!
    init(directory: URL) { self.directory = directory }

    struct State { var prefix: String; var settings: DefaultMenuSettings; var fact: String?; var lastText: String; var pending: (title: String, help: String)? = nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: RenderFixture.root, withIntermediateDirectories: true)
        let permission = InsertionPermission(isTrusted: { true }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = Model(insertionPermission: permission, configurationURL: RenderFixture.root.appendingPathComponent("config.json"))
        app = AppDelegate(model: model)
        let controller = RenderFixture.controller(installed: RenderFixture.downloaded)
        controller.runtime = TableRuntime(loaded: ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual")],
                                          chip: RenderFixture.chip)
        app.modelsMenu = ModelsMenu(controller: controller)
        let states = [
            State(prefix: "default-", settings: DefaultMenuSettings(availableMB: 86_900), fact: "1 model loaded · 1.3 GB in memory", lastText: "Rendered transcript"),
            State(prefix: "tight-", settings: DefaultMenuSettings(availableMB: 900, lastEvicted: "Nemotron 3.5 Streaming"), fact: "1 model loaded · 1.3 GB in memory", lastText: ""),
            State(prefix: "custom-", settings: DefaultMenuSettings(manualIdleMinutes: 60, onDemandIdleMinutes: 5, allowSwap: true, availableMB: 42_100), fact: nil, lastText: ""),
            State(prefix: "first-dictation-", settings: DefaultMenuSettings(availableMB: 86_900), fact: nil, lastText: "",
                  pending: pendingModelEntry(name: "Parakeet v3", precision: "4b", downloadBytes: 637_004_647)),
        ]
        render(states, 0)
    }

    private func render(_ states: [State], _ index: Int) {
        guard index < states.count else {
            renderUpdate { try? FileManager.default.removeItem(at: RenderFixture.root); NSApp.terminate(nil) }
            return
        }
        let state = states[index]
        app.menuSettings = state.settings
        app.factLine = { state.fact }
        app.model.lastText = state.lastText
        app.pendingModelRow = { state.pending }
        if state.pending != nil { app.modelsMenu.controller.runtime = TableRuntime(chip: RenderFixture.chip); RenderFixture.setInstalled(app.modelsMenu.controller, []) }
        app.rebuildMenu()
        let submenus = [("Keep Hot", "keep-hot"), ("Memory", "memory"), ("Mode", "mode")]
        MenuMock.render(app.menu.items, width: 340, to: directory.appendingPathComponent("\(state.prefix)menu.png")) { [self] in
            MenuMock.renderSubmenus(of: app.menu, titles: submenus, into: directory, prefix: state.prefix) { [self] in
                guard state.prefix == "default-" else { render(states, index + 1); return }
                // Main-menu tooltips plus the Keep Hot and Memory ones.
                MenuMock.renderTooltips(of: app.menu, submenus: ["Keep Hot", "Memory"], to: directory.appendingPathComponent("tooltips.png")) { [self] in
                    render(states, index + 1)
                }
            }
        }
    }
}
