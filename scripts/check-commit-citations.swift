#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func git(_ args: [String]) -> (Int32, String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
    p.currentDirectoryURL = root; p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A citation must name a commit of the history being published: reachable from HEAD, not merely present in the local object store.
func isAncestorOfHead(_ sha: String) -> Bool { git(["merge-base", "--is-ancestor", "\(sha)^{commit}", "HEAD"]).0 == 0 }

let pattern = try NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#)
// Content identities, not commits. These remain valid in a shallow or history-free source export.
let trees: Set<String> = [
    "af976137fbcd3cb0346fb187aced20cd82f9cc86", "ce8b527583b37c77274eb242b58025b85f35b6fc", "093375e515b30db74a5803abfdd6c1c0d28e29e2", "53e0cd3fce3cb0b11646dd3b085c0328e51fc5aa"
]
func citations(_ text: String) -> Set<String> {
    var result = Set<String>()
    for line in text.components(separatedBy: "\n") {
        // Remote model/dataset revisions are not commits in Vella's history.
        if line.contains("\"revision\"") || line.contains("huggingface.co/datasets/") || line.hasPrefix("- package: ") { continue }
        if line.hasPrefix("- source: https://github.com/") && !line.lowercased().contains("github.com/tobynoskillson/vella") { continue }
        for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            let sha = String(line[range])
            let prefix = String(line[..<range.lowerBound])
            if !prefix.lowercased().contains("github.com/tobynoskillson/vella"),
                prefix.range(of: #"github\.com/[^/ ]+/[^/ ]+/(blob|commit|tree)/$"#, options: .regularExpression) != nil
            {
                continue
            }
            if trees.contains(sha) || sha.allSatisfy(\.isNumber) { continue }
            if line[..<range.lowerBound].hasSuffix("@") { continue } // explicitly cited remote revision
            if line[..<range.lowerBound].hasSuffix("full-") { continue } // measurement tag, not a commit
            result.insert(sha)
        }
    }
    return result
}
if CommandLine.arguments.contains("--selftest") {
    let head = git(["rev-parse", "HEAD"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard citations("commit `\(head.prefix(7))`; worker SHA-256 `\(String(repeating: "a", count: 64))`") == [String(head.prefix(7))],
        citations("commit `deadbee`") == ["deadbee"], git(["rev-parse", "--verify", "deadbee^{commit}"]).0 != 0,
        citations(#""revision": "deadbee""#).isEmpty,
        citations("- package: fixture revision (deadbee)").isEmpty,
        citations("https://github.com/vendor/fixture/blob/deadbee/LICENSE").isEmpty,
        citations("https://github.com/TobyNoSkillSon/Vella/commit/deadbee") == ["deadbee"],
        isAncestorOfHead(String(head.prefix(7))), isAncestorOfHead("HEAD~1"), !isAncestorOfHead("deadbee")
    else { fputs("commit citation fixture failed\n", stderr); exit(1) }
    print("commit citations: short/full SHA extraction, non-commit exclusions and ancestor check tested")
    exit(0)
}
let files =
    ["README.md", "CHANGELOG.md", "Resources/benchmarks.json", "Resources/diagnose-reference.json", "Resources/SKILL.md", "docs/data.js", "scripts/worker-source-identity.sh"]
    + git(["ls-files", "*.md"]).1.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Worker/") && !$0.hasPrefix("Packages/") }
var failures: [String] = []
var checked = Set<String>()
for file in files {
    do {
        for sha in citations(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) {
            checked.insert(sha)
            if git(["rev-parse", "--verify", "\(sha)^{commit}"]).0 != 0 {
                failures.append("\(file): missing cited commit \(sha)")
            } else if !isAncestorOfHead(sha) {
                failures.append("\(file): cited commit \(sha) is not an ancestor of HEAD (not in the history to be published)")
            }
        }
    } catch { failures.append("\(file): cannot read citation source") }
}
if !failures.isEmpty { fputs(failures.joined(separator: "\n") + "\n", stderr); exit(1) }
print("commit citations: \(checked.count) published-history commits resolve and are ancestors of HEAD (binary hashes, trees and remote revisions excluded)")
