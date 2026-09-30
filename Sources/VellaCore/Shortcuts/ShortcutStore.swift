import Foundation

// MARK: Store (transactional persist/rollback)

public final class ShortcutStore {
    public private(set) var configuration: ShortcutConfiguration
    public private(set) var lastError: String?
    private let fileURL: URL?
    public init(initial: ShortcutConfiguration = .default, fileURL: URL? = nil) {
        self.configuration = initial
        self.fileURL = fileURL
    }
    public func load() {
        guard let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(ShortcutConfiguration.self, from: data)
            if let err = ShortcutValidation.validate(decoded) {
                lastError = err
                return
            }
            configuration = decoded
            lastError = nil
        } catch {
            lastError = "Saved shortcut could not be read; keeping \(ShortcutLabels.display(configuration))."
        }
    }
    @discardableResult
    public func save(_ config: ShortcutConfiguration) -> Bool {
        if let err = ShortcutValidation.validate(config) {
            lastError = err
            return false
        }
        let previous = configuration
        do {
            let data = try JSONEncoder().encode(config)
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                // Verify round-trip before committing in-memory state.
                let check = try JSONDecoder().decode(ShortcutConfiguration.self, from: Data(contentsOf: fileURL))
                guard check == config else { throw NSError(domain: "VellaShortcut", code: -1) }
            }
            configuration = config
            lastError = nil
            return true
        } catch {
            configuration = previous // Restore memory; a post-write verification failure may leave the new file.
            lastError = "Could not save shortcut; kept \(ShortcutLabels.display(previous)). \(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    public func resetToDefault() -> ShortcutConfiguration {
        _ = save(.default)
        return configuration
    }
}
