import AppKit
import SwiftUI
import VellaCore
import VellaUpdate

// Render harness for the Models table and the menu (documentation and review images).
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
    static let downloaded = ["parakeet-tdt-0.6b-v3-mlx-fp32", "Qwen3-ASR-1.7B-bf16", "Qwen3-ASR-0.6B-bf16",
                             "nemotron-3.5-asr-streaming-0.6b-bf16", "nemotron-3.5-asr-streaming-0.6b-8bit"]
    static let optimized: [String: Bool] = ["encoder": true, "decoder": true]
    static let previewActions = PreviewActions()
}

/// Runtime stand-in for renders: nothing loads.
@MainActor final class PreviewActions: ModelRuntimeActions {
    func load(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {}
    func reload(family: ModelFamily, precision: String, variant: CatalogVariant, path: String, selection: ModelSelection) {}

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
        var selections: [String: ModelSelection] = [:]
        /// Every row in use (dictating): segments and switch disabled.
        var inUse = false
        /// config.json: the modes' models and lastLoaded (what an unloaded row shows).
        var config: Configuration? = nil
        var lastError: String? = nil
        var downloadError: String? = nil
        var downloading: (id: String, progress: Double)? = nil
        var benchmarks: BenchmarkFile? = nil
        /// Switch flips after the previews (family id → position), as a click would make them.
        var flips: [(String, OptimizedMode)] = []
        /// Capabilities filter and its strip.
        var filter: Set<Capability> = []
        var filterOpen = false
        /// The family whose action cell is drawn under the pointer.
        var hover: String? = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        let chip = RenderFixture.chip
        var states: [State] = []
        func sel(_ tier: ModelTier, _ path: EnginePath, _ mode: OptimizedMode = .exact) -> ModelSelection { ModelSelection(tier: tier, path: path, mode: mode) }
        let fast = RenderFixture.optimized
        states.append(State(name: "fresh-nothing-downloaded", installed: []))
        // Downloaded, nothing loaded, nothing chosen yet: every row shows Standard 16.
        states.append(State(name: "downloaded-nothing-loaded"))
        // Nothing loaded: each row shows the cell it was last loaded with (config.json selections).
        var lastUsed = State(name: "unloaded-shows-last-used")
        lastUsed.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-bf16-local", lastLoaded: ["qwen3-asr-0.6b": "8b", "parakeet-v3": "BF16"],
                                      selections: ["qwen3-asr-0.6b": sel(.t8, .optimized, .fast), "parakeet-v3": sel(.t16, .optimized, .fast)])
        states.append(lastUsed)
        // Loaded: Parakeet v3 on Optimized 16 Fast (hot, Unload), Nemotron on Optimized 8 Fast.
        var loaded = State(name: "loaded")
        loaded.config = Self.config(dictation: "parakeet-tdt-0.6b-v3-mlx-bf16-local", streaming: "nemotron-3.5-asr-streaming-0.6b-8bit",
                                    selections: ["parakeet-v3": sel(.t16, .optimized, .fast), "nemotron-3.5-streaming-0.6b": sel(.t8, .optimized, .fast)])
        loaded.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "BF16", engine: "optimized", optimizations: fast.merging(["nax_gemm": true]) { $1 },
                                                             residency: "manual", selection: sel(.t16, .optimized, .fast)),
                                 "nemotron-3.5-streaming-0.6b": LoadedFamily(precision: "8b", engine: "optimized", optimizations: ["fused_layer": true],
                                                                             residency: "on_demand", selection: sel(.t8, .optimized, .fast))]
        states.append(loaded)
        // Whisper large-v3 loaded at 16 Fast; the row previews 8 (its numbers, deltas vs Standard 16, and the green
        // Reload). Whisper offers 16 and 8.
        var whisper = State(name: "whisper-previews-8")
        whisper.installed = RenderFixture.downloaded + ["whisper-large-v3-asr-fp16"]
        whisper.runtime.loaded = ["whisper-large-v3": LoadedFamily(precision: "FP16", engine: "optimized", optimizations: ["decoder": true, "encoder": true],
                                                                   residency: "manual", selection: sel(.t16, .optimized, .fast))]
        whisper.selections = ["whisper-large-v3": sel(.t8, .optimized, .fast)]
        states.append(whisper)
        // The coupling rule: Exact offers only the precisions with an Exact recipe. Vella's shipped data has one at every
        // offered precision, so this state uses a copy of it with the Exact recipes at 8 and 4 removed (as in Vireo).
        // Nemotron is loaded at 8 Fast and flipped to Exact: the preview moves to 16, says so, and offers Reload;
        // Parakeet v3 Ultra previews 8 and is flipped to Exact the same way.
        var coupling = State(name: "exact-coupling")
        coupling.config = loaded.config
        coupling.runtime.loaded = ["nemotron-3.5-streaming-0.6b": loaded.runtime.loaded["nemotron-3.5-streaming-0.6b"]!]
        coupling.selections = ["parakeet-v3-ultra": sel(.t8, .optimized, .fast)]
        coupling.flips = [("nemotron-3.5-streaming-0.6b", .exact), ("parakeet-v3-ultra", .exact)]
        coupling.benchmarks = Self.exactAt16Only()
        states.append(coupling)
        // The Capabilities filter strip open, "Chinese, Japanese and Korean" ticked: the Parakeets and the cloud rows hide.
        var filtered = State(name: "filter-active")
        filtered.config = loaded.config
        filtered.runtime.loaded = loaded.runtime.loaded
        filtered.filter = [.cjk]; filtered.filterOpen = true
        states.append(filtered)
        // Parakeet v3 loaded on Optimized 16 Fast, previewing its Standard 16 (the reference: no deltas, green Reload);
        // Parakeet v3 Ultra previewing Standard 8 (its own numbers, deltas vs Standard 16).
        var standard = State(name: "standard-previews")
        standard.config = loaded.config
        standard.runtime.loaded = loaded.runtime.loaded
        standard.selections = ["parakeet-v3": sel(.t16, .standard, .fast), "parakeet-v3-ultra": sel(.t8, .standard, .fast)]
        states.append(standard)
        // The pointer over Qwen3 ASR 1.7B's action cell (on disk): the Load button and the trash glyph.
        var hover = State(name: "hover-action")
        hover.config = loaded.config
        hover.runtime.loaded = loaded.runtime.loaded
        hover.hover = "qwen3-asr-1.7b"
        states.append(hover)
        // In use (dictating): segments and switch disabled; a change applies at the next load.
        var inUse = State(name: "disabled-in-use")
        inUse.config = loaded.config
        inUse.runtime.loaded = loaded.runtime.loaded
        inUse.inUse = true
        states.append(inUse)
        // Qwen 1.7B loaded at 16 (its switch greyed and pinned up: Fast = Exact); Qwen 0.6B previews 8.
        var qwen = State(name: "qwen-loaded-switch-always-on")
        qwen.runtime.loaded = ["qwen3-asr-1.7b": LoadedFamily(precision: "BF16", engine: "optimized", optimizations: ["decoder": true, "encoder": true],
                                                              residency: "manual", selection: sel(.t16, .optimized, .exact))]
        qwen.selections = ["qwen3-asr-0.6b": sel(.t8, .optimized, .fast)]
        states.append(qwen)
        var fallback = State(name: "mlx-fallback")
        fallback.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "BF16", engine: "mlx",
            engineReason: "the optimized path returned non-finite values during a dictation; switched to the stock MLX path until reload",
            optimizations: ["encoder": false, "decoder": false], residency: "manual", selection: sel(.t16, .optimized, .fast))]
        states.append(fallback)
        var loadingState = State(name: "footer-loading")
        loadingState.runtime.loading = "qwen3-asr-1.7b"
        states.append(loadingState)
        // After Download in the popup: the row shows the downloading cell with its progress; it loads when done.
        var downloading = State(name: "footer-downloading")
        downloading.downloading = ("parakeet-ultra-mlx-bf16", 0.23)
        downloading.selections = ["parakeet-v3-ultra": sel(.t8, .optimized)]
        states.append(downloading)
        var failed = State(name: "footer-download-failed")
        failed.downloadError = "Parakeet v3 Ultra download failed: it stalled (no data from Hugging Face for 2 minutes). Partial files removed."
        states.append(failed)
        var refusedLong = State(name: "footer-error-long")
        refusedLong.runtime.loaded = loaded.runtime.loaded
        refusedLong.runtime.refusal = TableRefusal(message: "Qwen3 ASR 1.7B at BF16 needs ~4.2 GB; ~0.9 GB free without swapping. Unload Parakeet v3, pick 8, or allow swap in Vella → Memory.", at: now)
        states.append(refusedLong)
        var otherChip = State(name: "other-chip-M3-Pro")
        otherChip.runtime.chip = chip == "M3 Pro" ? "M5 Max" : "M3 Pro"
        states.append(otherChip)
        states.append(State(name: "unmeasured-no-benchmarks", benchmarks: BenchmarkFile()))
        writeEngineTooltips(states)
        Self.renderControls(to: directory.appendingPathComponent("controls.png")) { [self] in render(states, 0) }
    }

    /// Shipped benchmarks with the Optimized Exact recipes at 8 and 4 removed: the coupling render's data.
    static func exactAt16Only() -> BenchmarkFile {
        var file = decodeBenchmarks(try? Data(contentsOf: ModelsController.benchmarksURL(resources: ModelLibrary.resourceDirectory())))
        for (id, var model) in file.models {
            for tier in [ModelTier.t8, .t4] { model.tiers[tier]?.cells[.optimized_exact] = nil }
            file.models[id] = model
        }
        return file
    }

    /// The shared Precision rows, Exact/Fast switch and action button (TierControl.swift, ExactFastSwitch.swift,
    /// RowAction.swift) in their states, one per line.
    static func renderControls(to url: URL, done: @escaping () -> Void) {
        typealias Cell = TierControl.Cell
        func line(_ title: String, _ optimized: [String], _ standard: [String], _ selected: Cell?, enabled: Bool = true, hot: Bool = false,
                  position: ExactFastSwitch.Position = .exact, available: Bool = true, action: String = "Load", emphasized: Bool = false,
                  deletable: Bool = true, hovered: Bool = false, busy: String? = nil) -> some View {
            HStack(alignment: .center, spacing: 10) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
                TierControl(optimized: optimized, standard: standard, selected: selected, enabled: enabled, hot: hot, help: { _ in "" }, onSelect: { _ in })
                ExactFastSwitch(position: position, available: available, enabled: enabled, onChange: { _ in })
                    .offset(y: (TierControl.segmentHeight - ExactFastSwitch.height) / 2)
                    .frame(width: ExactFastSwitch.width, height: TierControl.height, alignment: .top)
                RowAction(title: action, busyText: busy, emphasized: emphasized, enabled: enabled, deletable: deletable, hot: hot, hovered: hovered,
                          help: "", onPerform: {}, onDelete: {})
            }.padding(.horizontal, 8).frame(height: ModelTable.rowHeight)
                .background(hot ? ModelTable.hotRow : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        let all = ["16", "8", "4"]
        let sheet = VStack(alignment: .leading, spacing: 4) {
            line("Optimized 16 · Exact · on disk", all, all, Cell(.optimized, "16"))
            line("Standard 8 · not downloaded", ["16", "8"], ["16", "8"], Cell(.standard, "8"), position: .fast, action: "Get", deletable: false)
            line("Optimized 8 · Fast · loaded", all, all, Cell(.optimized, "8"), hot: true, position: .fast, action: "Unload")
            line("Loaded, Standard 4 previewed", all, all, Cell(.standard, "4"), hot: true, position: .fast, action: "Reload", emphasized: true)
            line("Fast = Exact (greyed, always on)", ["16", "8"], ["16", "8"], Cell(.optimized, "16"), available: false)
            line("Exact offers 16 only", ["16"], all, Cell(.optimized, "16"))
            line("In use (disabled)", ["16", "8"], ["16", "8"], Cell(.optimized, "8"), enabled: false, position: .fast)
            line("Pointer over the action", ["16", "8"], ["16", "8"], Cell(.optimized, "16"), position: .fast, hovered: true)
            line("Downloading", ["16", "8"], ["16", "8"], Cell(.optimized, "8"), position: .fast, busy: "23%")
        }.padding(8)
        let view = NSHostingView(rootView: sheet)
        view.frame = NSRect(x: 0, y: 0, width: 190 + 30 + TierControl.width + ExactFastSwitch.width + RowAction.width + 16 + 16,
                            height: 9 * (ModelTable.rowHeight + 4) + 16)
        let container = NSView(frame: view.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor
        container.addSubview(view)
        container.appearance = NSAppearance(named: .darkAqua)
        MenuMock.capture(container, to: url, done: done)
    }

    /// A config.json whose modes' models are the render fixture's installed paths.
    static func config(dictation: String? = nil, streaming: String? = nil, lastLoaded: [String: String] = [:],
                       selections: [String: ModelSelection] = [:]) -> Configuration {
        var config = Configuration(model: dictation.map { "/render/\($0)" } ?? "")
        config.streamingModel = streaming.map { "/render/\($0)" } ?? ""
        config.lastLoaded = lastLoaded
        config.selections = selections
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
        // The first-dictation Get row offers the first offered dictation model at 16.
        if let f = catalog.offered(.dictation).first, let p = downloadPrompt(family: f, precision: precisionLabel(f, tier: .t16) ?? f.native, followUp: .transcribe, freeBytes: free) {
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
            // One block per cell: "[Row · Column]" then the tooltip's lines as shown.
            let lines = [RecognitionMode.dictation, .streaming].flatMap { mode in
                controller.families(mode).flatMap { family in table.tooltips(family).map { "[\(family.name) · \($0.0)]\n\($0.1)\n" } }
                    + controller.references(mode).flatMap { r in table.tooltips(r).map { "[\(r.name) · \($0.0)]\n\($0.1)\n" } }
            }
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("table-tooltips.txt"), atomically: true, encoding: .utf8)
            Self.renderFirstFrame(controller, to: directory.appendingPathComponent("models-first-frame.png"),
                                  check: directory.appendingPathComponent("models-first-frame-check.txt"))
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
        for (id, mode) in state.flips { if let f = controller.catalog.family(id) { controller.setMode(f, mode) } }
        controller.capabilityFilter = state.filter
        controller.filterOpen = state.filterOpen
        controller.previewHover = state.hover
        controller.previewInUse = state.inUse
        controller.lastError = state.lastError
        controller.dictation.downloadError = state.downloadError
        if let d = state.downloading, let library = [controller.dictation, controller.streaming].first(where: { $0.models.contains { $0.id == d.id } }) {
            library.downloadingID = d.id; library.busy = true; library.progress = d.progress
            let total = library.models.first { $0.id == d.id }?.downloadBytes ?? 0
            library.message = "Parakeet v3 Ultra 16 \u{00b7} Downloading from Hugging Face… \(formatBytes(Int64(Double(total) * d.progress))) of \(formatBytes(total))"
        }
        TableRenderDelegate.renderTable(controller, to: directory.appendingPathComponent("models-\(state.name).png")) { [self] in
            render(states, index + 1)
        }
    }

    /// The table as the menu first shows it: one layout pass, drawn at once, no run-loop turn and no click (the tier
    /// rows once overlapped only in this frame). `check` counts overlaps, the gap between each model's two segment rows and the sizes.
    static func renderFirstFrame(_ controller: ModelsController, to url: URL, check: URL) {
        let table = MenuTableHostingView(rootView: ModelTable(controller: controller))
        table.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(controller))
        // On the menu's dark panel, as renderTable, but captured straight after the first layout pass.
        let container = NSView(frame: table.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor
        container.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(table)
        let window = NSWindow(contentRect: table.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        table.layoutSubtreeIfNeeded()
        if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        var controls: [NSRect] = [], switches: [NSRect] = [], actions: [NSRect] = []
        func walk(_ v: NSView) {
            // A segmented control's frame carries its bezel's alignment insets; its drawn size is the alignment rect.
            if v is NSSegmentedControl, let parent = v.superview { controls.append(parent.convert(v.alignmentRect(forFrame: v.frame), to: table)) }
            if v is SwitchView { switches.append(v.convert(v.bounds, to: table)) }
            if v is RowActionView { actions.append(v.convert(v.bounds, to: table)) }
            v.subviews.forEach(walk)
        }
        walk(table)
        // Every control of the first frame at its explicit size, none overlapping another.
        let all = (controls + switches + actions).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        var overlaps = 0
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] where a.intersects(b) { overlaps += 1 } }
        // The Optimized and Standard rows of one model: segment controls in the same row band, one above the other.
        var gaps: [Int] = []
        for (i, a) in controls.enumerated() {
            for b in controls[(i + 1)...] where a.minY != b.minY && abs(a.midY - b.midY) <= TierControl.segmentHeight + TierControl.rowSpacing + 1 {
                gaps.append(Int((max(a.minY, b.minY) - min(a.maxY, b.maxY)).rounded()))
            }
        }
        let lines = ["precision segment controls: \(controls.count), exact/fast switches: \(switches.count), action buttons: \(actions.count)",
                     "overlapping pairs on the first frame: \(overlaps)",
                     "gaps between a model's Optimized and Standard rows: \(Set(gaps).sorted()) over \(gaps.count) models (expected \(Int(TierControl.rowSpacing)))",
                     "segment heights: \(Set(controls.map { Int($0.height) }).sorted()) (expected \(Int(TierControl.segmentHeight)))",
                     "switch sizes: \(Set(switches.map { "\(Int($0.width))x\(Int($0.height))" }).sorted()) (expected \(Int(ExactFastSwitch.width))x\(Int(ExactFastSwitch.height)))",
                     "action sizes: \(Set(actions.map { "\(Int($0.width))x\(Int($0.height))" }).sorted()) (expected \(Int(RowAction.width))x\(Int(RowAction.height)))"]
            + all.map { "\($0)" }
        try? lines.joined(separator: "\n").write(to: check, atomically: true, encoding: .utf8)
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
        app.factLine = { nil }; app.model.lastText = ""; app.pendingModelRow = { nil }; app.workersRunning = { true }
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

    /// `worker`: a transcription worker is running (Restart Worker); false shows Start Worker.
    struct State { var prefix: String; var settings: DefaultMenuSettings; var fact: String?; var lastText: String; var pending: (title: String, help: String)? = nil; var worker = true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: RenderFixture.root, withIntermediateDirectories: true)
        let permission = InsertionPermission(isTrusted: { true }, prompt: {}, history: PermissionPromptHistory(read: { true }, write: {}))
        let model = DictationController(insertionPermission: permission, configurationURL: RenderFixture.root.appendingPathComponent("config.json"))
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
                  pending: controller.firstOffer(.dictation).map { ($0.title, $0.help) }, worker: false),
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
        app.workersRunning = { state.worker }
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
