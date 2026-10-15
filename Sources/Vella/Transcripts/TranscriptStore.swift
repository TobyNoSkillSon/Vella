import Foundation

/// One saved transcript as the Transcripts window shows it.
struct TranscriptEntry: Identifiable, Equatable {
    /// The recording folder's path: stable across refreshes, so expansion survives a reload.
    var id: String { directory.path }
    let directory: URL
    let created: Date
    let text: String
    /// Written from `partial-transcript.txt`: some audio was never transcribed.
    let incomplete: Bool
}

/// Reads saved transcripts page by page. Opening lists the Recordings folder once (names and creation dates only, one
/// directory read however many recordings there are) and reads text only for the rows on screen; nothing else is decoded.
struct TranscriptStore {
    let root: URL
    /// Every recording folder, newest first.
    struct Slot: Equatable {
        let directory: URL
        let created: Date
    }

    /// The recording folders newest first, by the folder's creation date (when the recording started). Folders without a
    /// session.json are not recordings; they are checked only when a page reaches them (`entry(at:)`).
    func index() -> [Slot] {
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Slot? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            return Slot(directory: url, created: values.creationDate ?? .distantPast)
        }.sorted { $0.created != $1.created ? $0.created > $1.created : $0.directory.lastPathComponent > $1.directory.lastPathComponent }
    }

    /// The finished transcript, else the partial one; nil for a recording with no text yet (still recording, or failed
    /// before any segment was recognized).
    func entry(_ slot: Slot) -> TranscriptEntry? {
        let complete = slot.directory.appendingPathComponent("transcript.txt")
        let partial = slot.directory.appendingPathComponent("partial-transcript.txt")
        if let text = Self.read(complete) { return TranscriptEntry(directory: slot.directory, created: slot.created, text: text, incomplete: false) }
        if let text = Self.read(partial).map(Self.withoutPartialHeader), !text.isEmpty {
            return TranscriptEntry(directory: slot.directory, created: slot.created, text: text, incomplete: true)
        }
        return nil
    }
    /// Whether the slot has text, without reading it (existence checks only).
    func hasText(_ slot: Slot) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: slot.directory.appendingPathComponent("transcript.txt").path)
            || fm.fileExists(atPath: slot.directory.appendingPathComponent("partial-transcript.txt").path)
    }

    /// Reads counted for tests (lazy loading is a contract: only the rows on screen are read).
    nonisolated(unsafe) static var reads = 0
    private static func read(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        reads += 1
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    /// The partial file's first line is a bracketed note for the clipboard ("[Incomplete transcript — retry missing audio
    /// segments]"); the window marks the row Incomplete instead.
    static func withoutPartialHeader(_ text: String) -> String {
        guard text.hasPrefix("[Incomplete") else { return text }
        let rest = text.drop(while: { $0 != "\n" })
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The window's list: the first page, then more on request. Text is read only for rows being shown.
@MainActor final class TranscriptsModel: ObservableObject {
    static let firstPage = 10
    static let morePage = 20
    let store: TranscriptStore
    @Published private(set) var entries: [TranscriptEntry] = []
    /// Another transcript exists past the last shown one.
    @Published private(set) var hasMore = false
    /// Expanded rows by id (kept across refreshes for the session).
    @Published var expanded: Set<String> = []
    private var slots: [TranscriptStore.Slot] = []
    /// Index of the next slot to read.
    private var cursor = 0

    init(root: URL) { store = TranscriptStore(root: root) }

    /// Re-lists the folder and reads the same number of rows as are shown now (at least the first page): a new
    /// transcript appears at the top, a retried one turns complete, a deleted one leaves.
    func reload() {
        let target = max(Self.firstPage, entries.count)
        slots = store.index(); cursor = 0
        var next: [TranscriptEntry] = []
        append(upTo: target, into: &next)
        if next != entries { entries = next }
        updateHasMore()
        expanded.formIntersection(Set(entries.map(\.id)))
    }
    /// Forgets the shown rows (the window closed): the next reload reads the first page only.
    func reset() { entries = []; expanded = []; slots = []; cursor = 0; hasMore = false }
    func showMore() {
        var next = entries
        append(upTo: entries.count + Self.morePage, into: &next)
        entries = next
        updateHasMore()
    }
    private func append(upTo count: Int, into list: inout [TranscriptEntry]) {
        while list.count < count, cursor < slots.count {
            if let entry = store.entry(slots[cursor]) { list.append(entry) }
            cursor += 1
        }
    }
    /// Existence checks only: skip slots without text until one with text is found.
    private func updateHasMore() {
        var i = cursor
        while i < slots.count, !store.hasText(slots[i]) { i += 1 }
        let more = i < slots.count
        if more != hasMore { hasMore = more }
    }
    func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
}
