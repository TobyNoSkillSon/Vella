import Foundation

/// Notification only: never downloads or runs an installer, or requests TCC access.
@MainActor final class ReleaseUpdateChecker {
    struct Available: Equatable {
        let tag: String
        var url: URL { URL(string: "https://github.com/TobyNoSkillSon/Vella/releases/tag/\(tag)")! }
    }
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }
    private(set) var available: Available?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let currentVersion: String
    private let fetch: () async throws -> Data
    private var inFlight = false
    private static let lastAttemptKey = "releaseCheck.lastAttempt"
    private static let availableKey = "releaseCheck.availableTag"

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         defaults: UserDefaults = .standard,
         fetch: @escaping () async throws -> Data = ReleaseUpdateChecker.fetchLatest) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        if let tag = defaults.string(forKey: Self.availableKey),
           let installed = Self.version(currentVersion), let cached = Self.version(tag),
           installed.lexicographicallyPrecedes(cached) {
            available = Available(tag: tag)
        } else {
            defaults.removeObject(forKey: Self.availableKey)
        }
    }

    /// Called only after completed transcription. Persist attempts before networking so
    /// failures, concurrent completions and relaunches cannot cause daily retry storms.
    func checkAfterUse(now: Date = Date(), calendar: Calendar = .current) async {
        guard !inFlight, let current = Self.version(currentVersion) else { return }
        if let last = defaults.object(forKey: Self.lastAttemptKey) as? Date,
           last >= now || calendar.isDate(last, inSameDayAs: now) { return }
        defaults.set(now, forKey: Self.lastAttemptKey)
        inFlight = true
        defer { inFlight = false }
        do {
            let data = try await fetch()
            guard data.count <= 1_048_576, !Task.isCancelled,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  !release.draft, !release.prerelease,
                  let latest = Self.version(release.tag_name),
                  current.lexicographicallyPrecedes(latest) else { return }
            if let known = available, let version = Self.version(known.tag),
               latest.lexicographicallyPrecedes(version) { return }
            available = Available(tag: release.tag_name)
            defaults.set(release.tag_name, forKey: Self.availableKey)
            onChange?()
        } catch { /* Keep a known update visible even when GitHub is unavailable. */ }
    }

    /// Stable numeric major.minor.patch only. Reject unexpected tags and URL characters.
    static func version(_ value: String) -> [Int]? {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    nonisolated static func fetchLatest() async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/TobyNoSkillSon/Vella/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Vella-release-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
