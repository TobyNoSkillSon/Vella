import AppKit
import Combine
import SwiftUI

// Transcripts…: a dedicated window over the saved transcripts, newest first, ten at a time. Built like Mobius's windows
// (no visible title bar; the content's top line sits level with the traffic lights; one canvas, hairlines, quiet
// controls) in Vella's own colours: the icon's near-black and its lavender. One instance, kept by AppDelegate.

enum TranscriptsPalette {
    static let canvas = rgb(0x131418)
    static let hairline = Color.white.opacity(0.07)
    static let t1 = rgb(0xF1F2F4), t2 = rgb(0xA3A8B1), t3 = rgb(0x767C86)
    /// The icon's bars.
    static let lavender = rgb(0xC4B8FF)
    static let amber = rgb(0xF2BD66)
    static let nsCanvas = NSColor(srgbRed: 0x13 / 255, green: 0x14 / 255, blue: 0x18 / 255, alpha: 1)
    static func rgb(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// ⌘W closes, Esc closes, and the edit keys reach the selected text: a menu-bar app has no main menu to carry them.
final class TranscriptsWindow: NSWindow {
    /// Renders and tests build the window far off every screen; AppKit would otherwise pull it back on screen.
    nonisolated(unsafe) static var keepOffscreen = false
    /// A plain click (no drag, single click) at a point of the window. The text's own selection handles the same events
    /// first: a drag still selects, and a click still places the caret.
    var onClick: ((NSPoint) -> Void)?
    private var downAt: NSPoint?
    /// Further than this between down and up is a drag (a selection), not a click.
    static let clickSlop: CGFloat = 3
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        switch event.type {
        case .leftMouseDown: downAt = event.clickCount == 1 && event.modifierFlags.isDisjoint(with: [.shift, .command, .control, .option]) ? event.locationInWindow : nil
        case .leftMouseDragged:
            if let down = downAt, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) > Self.clickSlop { downAt = nil }
        case .leftMouseUp:
            defer { downAt = nil }
            guard let down = downAt, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) <= Self.clickSlop else { return }
            onClick?(down)
        default: break
        }
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.keepOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let action: Selector?
        switch key {
        case "w": performClose(nil); return true
        case "c": action = #selector(NSText.copy(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

@MainActor final class TranscriptsWindowController: NSWindowController, NSWindowDelegate {
    let model: TranscriptsModel
    static let title = "Transcripts"
    static let defaultSize = NSSize(width: 640, height: 720), minSize = NSSize(width: 420, height: 320)
    static let autosave = "Transcripts"
    /// Off for renders and tests, which place the window offscreen: that frame must never be remembered.
    static var autosaves = true
    private var observers: Set<AnyCancellable> = []
    private var lastReload = Date.distantPast
    /// Makes Vella the active app (an accessory app is not active on its own). Tests count it instead.
    static var activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    /// `changes`: fires when a dictation leaves new text (the window, if open, reloads its rows).
    init(root: URL, changes: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()) {
        model = TranscriptsModel(root: root)
        let window = TranscriptsWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Self.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = TranscriptsPalette.nsCanvas
        super.init(window: window)
        let host = NSHostingController(rootView: TranscriptsView(model: model, copy: { [weak self] in self?.copyRow($0) }))
        // A click on a row's text copies it (Toby, 15 Oct: "we just click on the text or copy to actually copy it").
        // The window sees the click because the selectable text's own view takes the mouse before any SwiftUI gesture.
        window.onClick = { [weak self, weak host] point in
            guard let self, let view = host?.view else { return }
            var local = view.convert(point, from: nil)
            if !view.isFlipped { local.y = view.bounds.height - local.y }
            // The pinned day heading covers the rows scrolled under it.
            guard local.y > TranscriptLayout.band, let entry = self.model.entry(atText: local) else { return }
            self.copyRow(entry)
        }
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(Self.defaultSize)
        window.delegate = self
        window.center()
        if Self.autosaves { window.setFrameAutosaveName(Self.autosave) }
        if TranscriptsWindow.keepOffscreen { window.setFrameOrigin(NSPoint(x: -9000, y: -9000)) }
        changes.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.reload(force: true)
        }.store(in: &observers)
    }
    required init?(coder: NSCoder) { nil }

    /// Copies a row and shows "Copied" on it.
    func copyRow(_ entry: TranscriptEntry) {
        copy(entry.text)
        model.markCopied(entry.id)
    }
    /// Rows are read before the window shows, so its first frame already has them.
    func show() {
        reload(force: true)
        showWindow(nil)
        Self.activateApp()
        window?.makeKeyAndOrderFront(nil)
    }
    /// Coming back to the window picks up what changed while it was in the background (one folder listing).
    func windowDidBecomeKey(_ notification: Notification) { reload(force: false) }
    /// Reopening starts again at the newest ten.
    func windowWillClose(_ notification: Notification) { model.reset() }
    private func reload(force: Bool) {
        guard force || Date().timeIntervalSince(lastReload) > 1 else { return }
        lastReload = Date()
        model.reload()
    }
}

struct TranscriptsView: View {
    @ObservedObject var model: TranscriptsModel
    let copy: (TranscriptEntry) -> Void
    var body: some View {
        // No drawn title bar (Mobius DESIGN.md): the list's top line, the pinned day heading, sits level with the
        // traffic lights; the window keeps its title for Mission Control and the Window menu.
        Group {
            if model.entries.isEmpty {
                TranscriptsEmptyView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        // The band still moves the window when there is no pinned heading in it.
                        Color.clear.frame(height: TranscriptLayout.band).contentShape(Rectangle()).gesture(WindowDragGesture())
                    }
            } else {
                TranscriptList(model: model, copy: copy)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(TranscriptsPalette.canvas.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

struct TranscriptsEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 26, weight: .medium)).foregroundStyle(TranscriptsPalette.lavender.opacity(0.85))
            Text("No transcripts yet").font(.system(size: 13)).foregroundStyle(TranscriptsPalette.t2)
        }
        .padding(.bottom, 40)
    }
}

/// Day sections in the shown order.
struct TranscriptDay: Identifiable {
    let id: Date
    let title: String
    let entries: [TranscriptEntry]
    static func group(_ entries: [TranscriptEntry], now: Date = Date(), calendar: Calendar = .current) -> [TranscriptDay] {
        var days: [TranscriptDay] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.created)
            if let last = days.last, last.id == day {
                days[days.count - 1] = TranscriptDay(id: day, title: last.title, entries: last.entries + [entry])
            } else {
                days.append(TranscriptDay(id: day, title: title(day, now: now, calendar: calendar), entries: [entry]))
            }
        }
        return days
    }
    static func title(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(calendar: calendar).weekday(.wide).day().month(.wide)
        if !sameYear { style = style.year() }
        return day.formatted(style)
    }
}

/// Row geometry: the time sits in a left gutter on the text's first line; day headings and text share one left edge,
/// which clears the traffic lights, so a pinned heading can sit on their line.
enum TranscriptLayout {
    static let inset: CGFloat = 20
    static let gutter: CGFloat = 76
    static var textLeading: CGFloat { inset + gutter }
    /// The title bar's band (macOS 26): the pinned heading is centred in it, level with the traffic lights.
    static let band: CGFloat = 32
}

struct TranscriptList: View {
    @ObservedObject var model: TranscriptsModel
    let copy: (TranscriptEntry) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(TranscriptDay.group(model.entries)) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            TranscriptRow(
                                entry: entry, expanded: model.expanded.contains(entry.id), copied: model.copiedID == entry.id,
                                toggle: { model.toggle(entry.id) }, copy: { copy(entry) },
                                textFrame: { model.textFrames[entry.id] = $0 })
                        }
                    } header: {
                        Text(day.title)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(TranscriptsPalette.t2)
                            .frame(maxWidth: .infinity, minHeight: TranscriptLayout.band, alignment: .leading)
                            .padding(.leading, TranscriptLayout.textLeading)
                            .background(TranscriptsPalette.canvas)
                            .contentShape(Rectangle()).gesture(WindowDragGesture())
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if model.hasMore {
                    Button("Show more") { model.showMore() }
                        .buttonStyle(QuietButtonStyle())
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }
}

struct TranscriptRow: View {
    let entry: TranscriptEntry
    let expanded: Bool
    /// Just copied: the Copy label reads "Copied".
    let copied: Bool
    let toggle: () -> Void
    let copy: () -> Void
    /// Where the text sits in the window (SwiftUI's global space: the hosting view's top-left coordinates): a click
    /// there copies the row (TranscriptsWindow.onClick).
    let textFrame: (CGRect) -> Void
    static let clampLines = 4
    static let incompleteHelp = "Some audio wasn’t transcribed. Recover Saved Recording… in the menu tries again."
    @VellaState private var fullHeight: CGFloat = 0
    @VellaState private var clampedHeight: CGFloat = 0
    /// Longer than four lines at this width: the chevron under Copy opens or closes it.
    private var long: Bool { fullHeight > clampedHeight + 1 }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.created.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(TranscriptsPalette.t3)
                if entry.incomplete {
                    Text("Incomplete").font(.system(size: 11, weight: .medium)).foregroundStyle(TranscriptsPalette.amber)
                        .help(Self.incompleteHelp)
                }
            }
            .frame(width: TranscriptLayout.gutter - 10, alignment: .leading)
            .padding(.trailing, 10)
            Text(entry.text)
                .font(.system(size: 13)).lineSpacing(2.5).foregroundStyle(TranscriptsPalette.t1)
                .textSelection(.enabled) // a drag selects part of it for ⌘C; a click copies it whole
                .lineLimit(expanded ? nil : Self.clampLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    if !expanded { clampedHeight = $0 }
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    textFrame($0)
                }
                .background(alignment: .topLeading) {
                    Text(entry.text).font(.system(size: 13)).lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            fullHeight = $0
                        }
                        .accessibilityHidden(true)
                }
                .accessibilityAction(named: "Copy") { copy() }
            Button(action: copy) {
                // As wide as "Copied" either way, so the text beside it never reflows when it changes.
                ZStack(alignment: .trailing) {
                    Text("Copied").hidden()
                    Text(copied ? "Copied" : "Copy")
                }
            }
            .buttonStyle(CopyButtonStyle(lit: copied))
            .padding(.leading, 12)
            .padding(.trailing, -8) // the label's text, not its hover fill, lines up with the row's edge
            .accessibilityLabel(copied ? "Copied" : "Copy transcript")
        }
        .padding(.horizontal, TranscriptLayout.inset).padding(.vertical, 8)
        .overlay(alignment: .bottomTrailing) {
            // A long transcript opens and closes from a chevron under Copy, level with its last line.
            if long || expanded {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 14)
                }
                .buttonStyle(CopyButtonStyle())
                .help(expanded ? "Show less" : "Show all")
                .accessibilityLabel(expanded ? "Show less" : "Show all")
                .padding(.trailing, TranscriptLayout.inset - 8).padding(.bottom, 6)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(TranscriptsPalette.hairline).frame(height: 1).padding(.leading, TranscriptLayout.textLeading).padding(.trailing, TranscriptLayout.inset)
        }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.directory]) }
        }
    }
}

/// A quiet outlined text button (Mobius's Remove style): secondary text, hairline border, filled while pressed.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? TranscriptsPalette.t1 : TranscriptsPalette.t2)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.0)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Copy on every row stays visible but quiet: plain secondary text, brighter with a soft fill under the pointer.
/// `lit`: just copied, the label reads in the primary text colour without a fill.
struct CopyButtonStyle: ButtonStyle {
    var lit = false
    func makeBody(configuration: Configuration) -> some View { CopyLabel(configuration: configuration, lit: lit) }
    private struct CopyLabel: View {
        let configuration: ButtonStyleConfiguration
        let lit: Bool
        @VellaState private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(lit || hovering || configuration.isPressed ? TranscriptsPalette.t1 : TranscriptsPalette.t3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
