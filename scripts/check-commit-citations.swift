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

let pattern = try NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#)
// Content identities, not commits. These remain valid in a shallow or history-free source export.
let trees: Set<String> = [
    "af976137fbcd3cb0346fb187aced20cd82f9cc86", "ce8b527583b37c77274eb242b58025b85f35b6fc", "093375e515b30db74a5803abfdd6c1c0d28e29e2", "528e719d0956b012f181cdf70cd3baa8f250275f"
]
func citations(_ text: String) -> Set<String> {
    var result = Set<String>()
    for line in text.components(separatedBy: "\n") {
        // Remote model/dataset revisions are not commits in Vella's history.
        if line.contains("\"revision\"") || line.contains("huggingface.co/datasets/") { continue }
        for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            let sha = String(line[range])
            if trees.contains(sha) || sha.allSatisfy(\.isNumber) { continue }
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
        citations(#""revision": "deadbee""#).isEmpty
    else { fputs("commit citation fixture failed\n", stderr); exit(1) }
    print("commit citations: short/full SHA extraction and non-commit exclusions tested")
    exit(0)
}
let files =
    ["README.md", "CHANGELOG.md", "Resources/benchmarks.json", "Resources/diagnose-reference.json", "Resources/SKILL.md", "docs/data.js", "scripts/worker-source-identity.sh"]
    + git(["ls-files", "docs/*.md", ".github/*.md"]).1.split(separator: "\n").map(String.init)
var failures: [String] = []
var checked = Set<String>()
for file in files {
    do {
        for sha in citations(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) {
            checked.insert(sha)
            if git(["rev-parse", "--verify", "\(sha)^{commit}"]).0 != 0 { failures.append("\(file): missing cited commit \(sha)") }
        }
    } catch { failures.append("\(file): cannot read citation source") }
}
if !failures.isEmpty { fputs(failures.joined(separator: "\n") + "\n", stderr); exit(1) }
print("commit citations: \(checked.count) published-history commits resolve (binary hashes, trees and remote revisions excluded)")
