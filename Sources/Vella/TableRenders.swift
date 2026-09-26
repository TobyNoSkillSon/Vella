import AppKit
import SwiftUI
import VellaCore

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
        let controller = ModelsController(dictation: dictation, streaming: streaming, selectionsURL: root.appendingPathComponent("model-precision.json"))
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
        var selections: [String: String] = [:]
        var lastError: String? = nil
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
        var loaded = State(name: "loaded")
        loaded.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual"),
                                 "nemotron-3.5-streaming-0.6b": LoadedFamily(precision: "8b", engine: "optimized", optimizations: ["encoder": true], residency: "on_demand")]
        states.append(loaded)
        var reload = State(name: "qwen-BF16-loaded-8b-selected-reload")
        reload.runtime.loaded = ["qwen3-asr-1.7b": LoadedFamily(precision: "BF16", engine: "optimized", optimizations: ["decoder": true, "prefill": true], residency: "manual")]
        reload.selections = ["qwen3-asr-1.7b": "8b", "whisper-large-v3": "native"]
        states.append(reload)
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
        var downloading = State(name: "footer-downloading")
        downloading.downloading = ("whisper-large-v3-asr-4bit", 0.42)
        downloading.selections = ["whisper-large-v3": "4b"]
        states.append(downloading)
        var refusedLong = State(name: "footer-error-long")
        refusedLong.runtime.loaded = ["parakeet-v3": LoadedFamily(precision: "4b", engine: "optimized", optimizations: RenderFixture.optimized, residency: "manual")]
        refusedLong.runtime.refusal = TableRefusal(message: "Qwen3 ASR 1.7B at BF16 needs ~4.2 GB; ~0.9 GB free without swapping. Unload Parakeet v3, pick 4b, or allow swap in Vella → Memory.", at: now)
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
            let lines = [RecognitionMode.dictation, .streaming].flatMap { controller.families($0) }.flatMap { family in
                table.tooltips(family).map { "\(family.name) · \($0.0): \($0.1)" } + [""]
            }
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("table-tooltips.txt"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: RenderFixture.root)
            NSApp.terminate(nil); return
        }
        let state = states[index]
        let controller = RenderFixture.controller(installed: state.installed)
        if let b = state.benchmarks { controller.benchmarks = b }
        controller.runtime = state.runtime
        controller.previewSelections(state.selections)
        controller.lastError = state.lastError
        if let d = state.downloading, let library = [controller.dictation, controller.streaming].first(where: { $0.models.contains { $0.id == d.id } }) {
            library.downloadingID = d.id; library.busy = true; library.progress = d.progress
            library.message = "Downloading model.safetensors… 371 of 882 MB"
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
            try? FileManager.default.removeItem(at: RenderFixture.root)
            NSApp.terminate(nil); return
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
