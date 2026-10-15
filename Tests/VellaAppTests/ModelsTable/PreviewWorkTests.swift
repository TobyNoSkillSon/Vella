import XCTest
import AppKit
import VellaCore
@testable import Vella

@MainActor final class PreviewWorkTests: XCTestCase {
    func testPreviewWork() throws { try previewWork(loaded: false) }
    func testLoadedPreviewWork() throws { try previewWork(loaded: true) }

    private func previewWork(loaded: Bool) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-work-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ProcessInfo.processInfo.environment["VELLA_PREVIEW_FIXTURE"].map { URL(fileURLWithPath: $0) }
        for name in ["config.json", "models-installed.json", "Worker"] {
            if let source, FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path) {
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
            }
        }
        if source == nil {
            try JSONEncoder().encode(Configuration(model: "/fixture/native", streamingModel: "/fixture/derived")).write(to: root.appendingPathComponent("config.json"))
        }
        let c = ModelsController(dictation: ModelLibrary(mode: .dictation, registryURL: root.appendingPathComponent("models-installed.json")), configURL: root.appendingPathComponent("config.json"))
        c.runtime = loaded
            ? TableRuntime(loaded: ["parakeet-v3-ultra": LoadedFamily(precision: "BF16", engine: "optimized")]) : TableRuntime()
        let family = try XCTUnwrap(c.catalog.family("parakeet-v3-ultra"))
        let view = MenuTableHostingView(rootView: ModelTable(controller: c, requestDelete: { _ in }))
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(c))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        var counts: [String: Int] = [:]
        c.observeWork = { counts[$0, default: 0] += 1 }
        for tier in [ModelTier.t8, .t4, .t16, .t8, .t4, .t16] {
            counts = [:]
            let start = ProcessInfo.processInfo.systemUptime
            c.select(family, tier: tier)
            let action = ProcessInfo.processInfo.systemUptime
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let end = ProcessInfo.processInfo.systemUptime
            print("PREVIEW tier=\(tier.rawValue) action_ms=\((action-start)*1000) rendered_ms=\((end-start)*1000) work=\(counts)")
            XCTAssertEqual(c.currentSelection(family).tier, tier)
            XCTAssertEqual(counts["render"], 1, "one synchronous table update per preview")
            XCTAssertNil(counts["adviceCalculation"], "previews reuse advice for unchanged inputs")
            XCTAssertNil(counts["manifestRead"], "including negative configured-path lookups")
            XCTAssertNil(counts["verdictScan"])
            XCTAssertNil(counts["verdictScanScheduled"])
            XCTAssertNil(counts["localPathLookup"], "all precisions are snapshotted on the first row render")
        }
        print("PREVIEW host=\(HostInfo.cpuBrand ?? "?") version=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "nil") verdicts=\(c.verdicts.count)")
    }
}
