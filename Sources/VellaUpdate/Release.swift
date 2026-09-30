import Foundation

/// A published release from the GitHub releases API (`GET /repos/{owner}/{repo}/releases/latest`).
public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let version: SemanticVersion
    public let name: String
    /// The release body (Markdown), as written on GitHub.
    public let body: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [String]

    public init(
        tag: String, version: SemanticVersion, name: String = "", body: String = "", draft: Bool = false,
        prerelease: Bool = false, assets: [String] = []
    ) {
        self.tag = tag; self.version = version; self.name = name; self.body = body
        self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }

    /// The release archive's file name (the name scripts/package-release.sh writes and scripts/install-release.sh downloads).
    public var zipName: String { Self.zipName(version) }
    public static func zipName(_ version: SemanticVersion) -> String { "Vella-\(version)-arm64.zip" }

    public enum ParseError: Error, CustomStringConvertible {
        case notJSON, missing(String), badTag(String)
        public var description: String {
            switch self {
            case .notJSON: return "the release answer is not a JSON object"
            case .missing(let key): return "the release answer has no \(key)"
            case .badTag(let tag): return "release tag \(tag) is not a version"
            }
        }
    }

    /// Parses one release object. Unknown fields are ignored; tag_name must be a version (`v1.0.1`). Answers over 1 MB
    /// are refused: a release object is a few kilobytes.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard data.count <= 1_048_576, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        guard let tag = object["tag_name"] as? String else { throw ParseError.missing("tag_name") }
        guard let version = SemanticVersion(tag) else { throw ParseError.badTag(tag) }
        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return ReleaseInfo(
            tag: tag, version: version, name: object["name"] as? String ?? "", body: object["body"] as? String ?? "",
            draft: object["draft"] as? Bool ?? false, prerelease: object["prerelease"] as? Bool ?? false, assets: assets)
    }

    /// The update to offer to `current`: this release when it is published (not a draft or prerelease, and not a
    /// prerelease version) and newer. nil otherwise.
    public func offer(to current: SemanticVersion) -> ReleaseInfo? {
        guard !draft, !prerelease, !version.isPrerelease, version > current else { return nil }
        return self
    }

    /// The body's opening text (up to its first heading after some text) as plain lines, at most `maxCharacters` (cut at a
    /// word, with `…`), for the confirmation popup. Markdown emphasis, code marks, headings, code blocks and link targets
    /// are dropped.
    public func shortNotes(maxCharacters: Int = 360) -> String {
        var lines: [String] = []
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("#") { if lines.isEmpty { continue } else { break } }
            if raw.hasPrefix("    ") || raw.hasPrefix("\t") || raw.hasPrefix("```") { continue }
            let line = Self.plain(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(line)
            if lines.joined(separator: "\n").count > maxCharacters { break }
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            let cut = text.prefix(maxCharacters)
            let end = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? cut.endIndex
            text = String(cut[..<end]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
        }
        return text
    }

    static func plain(_ line: String) -> String {
        var s = line
        while s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix(">") { s.removeFirst() }
        // [text](url) -> text
        if let regex = try? NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        for mark in ["**", "__", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        if let regex = try? NSRegularExpression(pattern: #"(^|[\s(])[*_]([^*_\s][^*_]*)[*_]"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2")
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "• " + trimmed.dropFirst(2) }
        return s
    }
}

/// The expected SHA-256 of `name` in a SHA256SUMS file (`<hex>  <name>` lines, as `shasum -a 256` writes them).
/// Exactly one well-formed line must name the file; anything else is nil (missing or ambiguous).
public func expectedSHA256(sums: String, name: String) -> String? {
    var found: [String] = []
    for line in sums.split(whereSeparator: \.isNewline) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 2 else { continue }
        var file = String(fields[1]); if file.hasPrefix("*") { file.removeFirst() } // shasum's binary-mode marker
        if file == name { found.append(String(fields[0])) }
    }
    guard found.count == 1, let hash = found.first, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
    return hash.lowercased()
}

/// The zip listing (`zipinfo -1`) holds only `Vella.app` and its contents, as scripts/install-release.sh requires: at
/// least one and at most 20 000 entries, each `Vella.app` or under `Vella.app/`, with no `..` component, no backslash,
/// and no AppleDouble (`._*`) or `__MACOSX` entry (they would unpack into the bundle and break its signature).
public func archiveEntriesAreSafe(_ entries: [String], app: String = "Vella.app") -> Bool {
    guard !entries.isEmpty, entries.count <= 20_000 else { return false }
    return entries.allSatisfy { entry in
        guard entry == app || entry == app + "/" || entry.hasPrefix(app + "/"), !entry.contains("\\") else { return false }
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0 == ".." || $0.hasPrefix("._") || $0 == "__MACOSX" }
    }
}
