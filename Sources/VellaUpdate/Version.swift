import Foundation

/// A release version as Vella tags its releases: `MAJOR.MINOR.PATCH`, optionally `-PRERELEASE` and `+BUILD`, with or
/// without a leading `v`. Ordered by Semantic Versioning 2.0: numeric parts, then a prerelease sorts before its
/// release (`0.3.0-ci1 < 0.3.0`), prerelease identifiers compare numerically when both are numbers, build metadata
/// is ignored.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: [String]
    public let build: String?

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        var build: String?
        if let plus = s.firstIndex(of: "+") {
            build = String(s[s.index(after: plus)...]); s = String(s[..<plus])
            guard let b = build, !b.isEmpty, b.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        }
        var prerelease: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let pre = String(s[s.index(after: dash)...]); s = String(s[..<dash])
            prerelease = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // No leading zeros (SemVer §2): `v01.0.0` is not a release tag.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), part.count <= 9, part.count == 1 || part.first != "0",
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
        self.prerelease = prerelease; self.build = build
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) + (build.map { "+" + $0 } ?? "")
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.major == b.major && a.minor == b.minor && a.patch == b.patch && a.prerelease == b.prerelease
    }

    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false          // equal, or a release is newer than its prerelease
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true                          // numeric identifiers sort before alphanumeric ones
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}
