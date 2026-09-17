import AppKit

/// Append-only streaming delivery. `sentText` records posted events, not target acceptance.
@MainActor
final class LiveInsertion {
    private(set) var sentText = ""
    private(set) var blockedReason: String?
    var didSend: Bool { !sentText.isEmpty }
    var onBlocked: ((String) -> Void)?

    static let eventMarker: Int64 = 0x56454C4C414C4956
    private let targetIsCurrent: () -> Bool
    private let send: (String) throws -> Void
    private var latest = ""
    static let maximumPendingUTF8 = 16_384
    static let maximumTailUTF8 = 8_192
    private var incremental = false
    private var hasCommitted = false
    private var tail = ""
    private var queued = ""
    private var lastPostedCharacter = ""
    var pendingUTF8Count: Int { queued.utf8.count }
    var tailUTF8Count: Int { tail.utf8.count }

    /// `committed` is NEW text only; `partial` is the current undrained suffix.
    /// Worker pieces are trimmed and joined with one ASCII space, as in its transcript.
    func offer(committed: String, partial: String) {
        guard !stopped else { return }
        guard latest.isEmpty else { pause("Cannot mix cumulative and incremental insertion."); return }
        incremental = true
        // Count bounded prefixes rather than traversing an arbitrarily large rejected input.
        guard committed.utf8.prefix(Self.maximumPendingUTF8 + 1).count <= Self.maximumPendingUTF8,
              partial.utf8.prefix(Self.maximumTailUTF8).count < Self.maximumTailUTF8 else {
            pause("Streaming insertion input exceeded its bounded window."); return
        }
        let committed = Self.sanitize(committed).trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = Self.sanitize(partial).trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = [committed, partial].filter { !$0.isEmpty }.joined(separator: " ")
        let candidate = (hasCommitted && !pieces.isEmpty ? " " : "") + pieces
        guard candidate.utf16.starts(with: tail.utf16) else {
            pause("Streaming text changed an earlier prefix."); return
        }
        let suffix = String(decoding: candidate.utf16.dropFirst(tail.utf16.count), as: UTF16.self)
        guard queued.utf8.count + suffix.utf8.count <= Self.maximumPendingUTF8 else {
            pause("Streaming insertion pending queue overflowed."); return
        }
        queued += suffix
        hasCommitted = hasCommitted || !committed.isEmpty
        tail = (hasCommitted && !partial.isEmpty ? " " : "") + partial
        scheduleFlush()
    }

    func finishStream() async {
        guard !stopped else { return }
        invalidatePending()
        flush()
        stopped = true
        stopMonitoring()
    }
    private var stopped = false
    private var generation: UInt64 = 0
    private var pending: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Custom activation chord to ignore (exact match only; supersets still pause).
    /// Default preserves the legacy ⌃⌘N behavior. Updated per recording from Model.
    var ignoredChordKeyCode: UInt16 = 45
    var ignoredChordModifiers: NSEvent.ModifierFlags = [.control, .command]

    init(targetIsCurrent: @escaping () -> Bool,
         send: ((String) throws -> Void)? = nil,
         monitorUserInput: Bool = false) {
        self.targetIsCurrent = targetIsCurrent
        self.send = send ?? { try Self.nativeSend($0) }
        if monitorUserInput { startMonitoring() }
    }

    deinit {
        pending?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func offer(_ cumulative: String) {
        guard accept(cumulative) else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard pending == nil, incremental ? !queued.isEmpty : latest != sentText else { return }
        let fence = generation
        // Fixed deadline from first offer: further tokens cannot starve live delivery.
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.generation == fence, !self.stopped else { return }
            self.pending = nil
            self.flush()
        }
    }

    func finish(_ cumulative: String) async {
        guard accept(cumulative) else { return }
        invalidatePending()
        flush()
        stopped = true
        stopMonitoring()
    }

    func cancel() {
        stopped = true
        invalidatePending()
        stopMonitoring()
    }

    func pause(_ reason: String) {
        guard !stopped else { return }
        blockedReason = reason
        cancel()
        onBlocked?(reason)
    }

    private func accept(_ cumulative: String) -> Bool {
        guard !stopped else { return false }
        guard !incremental else { pause("Cannot mix cumulative and incremental insertion."); return false }
        let text = Self.sanitize(cumulative)
        // Even unsent retractions are treated as a model edit. Do not trim whitespace:
        // a trailing-space retraction must never silently move the append boundary.
        guard text.utf16.starts(with: latest.utf16) else {
            pause("Streaming text changed an earlier prefix.")
            return false
        }
        latest = text
        return true
    }

    private func invalidatePending() {
        generation &+= 1
        pending?.cancel()
        pending = nil
    }

    // Internal for deterministic injected-sender stress tests; production uses the timer.
    func flush() {
        guard !stopped else { return }
        if incremental {
            let suffix = queued
            // Retain only the last posted grapheme for boundary validation, never scan history.
            let boundaryProbe = lastPostedCharacter + suffix
            let boundary = boundaryProbe.utf16.index(boundaryProbe.utf16.startIndex,
                                                    offsetBy: lastPostedCharacter.utf16.count)
            guard let index = String.Index(boundary, within: boundaryProbe),
                  index == boundaryProbe.endIndex || boundaryProbe.indices.contains(index) else {
                pause("Streaming text extended an already sent grapheme."); return
            }
            queued = "" // uncertain sends are never put back in the queue
            deliver(suffix)
            return
        }
        // Never split a grapheme across sends if the model extends a previously
        // posted character with combining marks or a joined emoji sequence.
        let boundary = latest.utf16.index(latest.utf16.startIndex, offsetBy: sentText.utf16.count)
        guard let characterBoundary = String.Index(boundary, within: latest),
              characterBoundary == latest.endIndex || latest.indices.contains(characterBoundary) else {
            pause("Streaming text extended an already sent grapheme.")
            return
        }
        let suffix = String(decoding: latest.utf16.dropFirst(sentText.utf16.count), as: UTF16.self)
        deliver(suffix)
    }

    private func deliver(_ suffix: String) {
        do {
            let chunks = try Self.unicodeChunks(suffix)
            for chunk in chunks {
                guard !stopped else { return }
                guard targetIsCurrent() else {
                    pause("Insertion target changed or Accessibility access was lost.")
                    return
                }
                try send(chunk)
                sentText += chunk
                lastPostedCharacter = chunk.last.map(String.init) ?? lastPostedCharacter
            }
        } catch {
            // A sender may have posted some events before throwing. Never retry.
            pause("Live insertion stopped: \(error.localizedDescription)")
        }
    }

    /// Collapse ASCII spaces (including filtered controls), retaining one trailing
    /// space. Worker prefix drains use a single join space; this is not a revision.
    static func sanitize(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let safe = (v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029)
                ? Unicode.Scalar(0x20)! : scalar
            let isSpace = safe.value == 0x20
            if !isSpace || !previousWasSpace { result.append(safe) }
            previousWasSpace = isSpace
        }
        return String(result)
    }

    enum DeliveryError: LocalizedError {
        case oversizedGrapheme, eventCreation
        var errorDescription: String? {
            switch self {
            case .oversizedGrapheme: return "A text grapheme exceeds the safe keyboard event size."
            case .eventCreation: return "Could not create native keyboard events."
            }
        }
    }

    static func unicodeChunks(_ text: String) throws -> [String] {
        var result: [String] = []
        var chunk = ""
        for character in text {
            let value = String(character)
            guard value.utf16.count <= 20 else { throw DeliveryError.oversizedGrapheme }
            if chunk.utf16.count + value.utf16.count > 20 {
                result.append(chunk)
                chunk = ""
            }
            chunk += value
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    /// Controller calls this once per checked <=20-unit batch. No clipboard or AX caret reads.
    static func nativeSend(_ text: String) throws {
        for chunk in try unicodeChunks(sanitize(text)) {
            let (down, up) = try nativeEvents(for: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Event construction is separate so tests can verify provenance without posting.
    static func nativeEvents(for chunk: String) throws -> (CGEvent, CGEvent) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw DeliveryError.eventCreation
        }
        let units = Array(chunk.utf16)
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
            }
        }
        return (down, up)
    }

    /// Exposed for deterministic monitor-policy tests; modifiers alone and motion are ignored.
    func observeUserInput(type: NSEvent.EventType, keyCode: UInt16 = 0,
                          modifiers: NSEvent.ModifierFlags = [], marker: Int64 = 0) {
        guard marker != Self.eventMarker else { return }
        if type == .keyDown {
            let relevant = modifiers.intersection([.control, .command, .shift, .option, .function])
            let ignoredRelevant = ignoredChordModifiers.intersection([.control, .command, .shift, .option, .function])
            if keyCode == ignoredChordKeyCode && relevant == ignoredRelevant { return }
            // Legacy default preserved when custom equals default; superset chords still pause.
            if ignoredChordKeyCode != 45 || ignoredChordModifiers != [.control, .command] {
                if keyCode == 45 && relevant == [.control, .command] { return }
            }
            pause("Typing interrupted live insertion.")
        } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            pause("A mouse click interrupted live insertion.")
        }
    }

    private func startMonitoring() {
        // Key-up modifier flags reflect release ordering, not the original chord.
        // Editing is already caught on key-down; shortcut releases must not block.
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let handle: (NSEvent) -> Void = { [weak self] event in
            // AppKit invokes local and global monitor handlers on the main thread.
            MainActor.assumeIsolated {
                let isKey = event.type == .keyDown
                self?.observeUserInput(type: event.type, keyCode: isKey ? event.keyCode : 0,
                    modifiers: event.modifierFlags,
                    marker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
            return event
        }
        if globalMonitor == nil || localMonitor == nil {
            pause("Could not monitor user input safely.")
        }
    }

    private func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
