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
func pinnedTrees(_ text: String) -> Set<String> {
    let assignment = try! NSRegularExpression(pattern: #"^(?:WORKER_CODE_TREE|WORKER_FULL_TREE|PACKAGES_TREE|BASE_WORKER_TREE|REFERENCE_WORKER_FULL_TREE)=([0-9a-f]{40})\b"#, options: .anchorsMatchLines)
    return Set(
        assignment.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
}
/// Unlike the source-identity script's code pin, this requires the full committed Worker tree, including READMEs.
/// Refresh WORKER_FULL_TREE and its published provenance references after committing a Worker README-only change.
func currentTreesMatchPins(_ text: String) -> Bool {
    for (name, path) in [("WORKER_FULL_TREE", "Worker"), ("PACKAGES_TREE", "Packages")] {
        let assignment = try! NSRegularExpression(pattern: "^\(name)=([0-9a-f]{40})\\b", options: .anchorsMatchLines)
        guard let match = assignment.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return false }
        let actual = git(["rev-parse", "HEAD:\(path)"])
        guard actual.0 == 0, actual.1.trimmingCharacters(in: .whitespacesAndNewlines) == String(text[range]) else { return false }
    }
    return true
}
/// Recompute the README-stripped Worker code tree and Packages tree from both HEAD and disk; pins alone are not evidence.
func sourceIdentityPasses() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [root.appendingPathComponent("scripts/worker-source-identity.sh").path]
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
let historicalTrees: Set<String> = [
    "af976137fbcd3cb0346fb187aced20cd82f9cc86", "ce8b527583b37c77274eb242b58025b85f35b6fc", "093375e515b30db74a5803abfdd6c1c0d28e29e2", "53e0cd3fce3cb0b11646dd3b085c0328e51fc5aa"
]
let sourcePins = try String(contentsOf: root.appendingPathComponent("scripts/worker-source-identity.sh"), encoding: .utf8)
guard currentTreesMatchPins(sourcePins), sourceIdentityPasses() else {
    fputs("commit citations: source tree pins differ from HEAD or checkout\n", stderr); exit(1)
}
let trees = historicalTrees.union(pinnedTrees(sourcePins))
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
                prefix.range(of: #"(?:github\.com/[^/ ]+/[^/ ]+|huggingface\.co/(?:datasets/)?[^/ ]+/[^/ ]+)/(blob|commit|tree|resolve)/$"#, options: .regularExpression) != nil
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
    // The full SHA: a 7-character prefix can be all digits (e.g. 3377576), which citations() rightly skips as a number.
    guard citations("commit `\(head)`; worker SHA-256 `\(String(repeating: "a", count: 64))`") == [head],
        citations("commit `deadbee`") == ["deadbee"], git(["rev-parse", "--verify", "deadbee^{commit}"]).0 != 0,
        citations(#""revision": "deadbee""#).isEmpty,
        citations("- package: fixture revision (deadbee)").isEmpty,
        citations("https://github.com/vendor/fixture/blob/deadbee/LICENSE").isEmpty,
        citations("https://huggingface.co/vendor/fixture/commit/deadbee").isEmpty,
        citations("https://github.com/TobyNoSkillSon/Vella/commit/deadbee") == ["deadbee"],
        pinnedTrees("WORKER_FULL_TREE=\(String(repeating: "b", count: 40)) # source\nSOURCE=\(String(repeating: "c", count: 40))") == [String(repeating: "b", count: 40)],
        pinnedTrees(sourcePins).count == 5,
        pinnedTrees(sourcePins).allSatisfy({ citations("source tree `\($0)`").isEmpty }),
        citations("unknown tree `\(String(repeating: "d", count: 40))`") == [String(repeating: "d", count: 40)],
        !currentTreesMatchPins(
            sourcePins.replacingOccurrences(of: #"(?m)^WORKER_FULL_TREE=[0-9a-f]{40}"#, with: "WORKER_FULL_TREE=" + String(repeating: "e", count: 40), options: .regularExpression)),
        !currentTreesMatchPins(
            sourcePins.replacingOccurrences(of: #"(?m)^PACKAGES_TREE=[0-9a-f]{40}"#, with: "PACKAGES_TREE=" + String(repeating: "e", count: 40), options: .regularExpression)),
        isAncestorOfHead(String(head.prefix(7))), isAncestorOfHead("HEAD~1"), !isAncestorOfHead("deadbee")
    else { fputs("commit citation fixture failed\n", stderr); exit(1) }
    print("commit citations: short/full SHA extraction, non-commit exclusions and ancestor check tested")
    exit(0)
}
let files =
    ["README.md", "CHANGELOG.md", "Resources/benchmarks.json", "Resources/diagnose-reference.json", "Resources/SKILL.md", "scripts/worker-source-identity.sh"]
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
