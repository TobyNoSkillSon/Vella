import Foundation

/// A chooser uses metadata only; recovery performs the existing integrity checks after consent.
struct SavedRecordingChoice {
    let directory: URL
    let title: String
    let created: Date
    init(directory: URL, title: String, created: Date = .distantPast) { self.directory = directory; self.title = title; self.created = created }
    static func list(root: URL) -> [SavedRecordingChoice] {
        RecordingSession.discover(root: root).compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                let manifest = try? JSONDecoder().decode(RecordingSession.Manifest.self, from: data)
            else { return nil }
            let seconds = Int(manifest.segments.reduce(0) { $0 + $1.seconds })
            let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let title = manifest.created.formatted(date: .abbreviated, time: .shortened) + " · " + manifest.config.mode.title + " · " + duration + " · " + manifest.state
            return SavedRecordingChoice(directory: directory, title: title, created: manifest.created)
        }.sorted { $0.created > $1.created }
    }
}
