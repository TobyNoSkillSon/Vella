import Foundation

// Shipped data uses portable provenance: hashes, commits, tags, suite IDs and checkpoint repository IDs.
// Absolute/named-user home paths and excluded competitor receipts stay in local lab evidence.
// Withdrawn third-party comparison: no competitor name or competitor_comparisons key ships.
// Generic shell placeholders ($HOME and ~/) in installation instructions reveal no local identity.

func violations(_ text: String, isText: Bool = true, isPublic: Bool = true) -> [String] {
    let lower = text.lowercased()
    var reasons: [String] = []
    if isPublic && isText && lower.contains("lab/") { reasons.append("local-only evidence path") }
    for (needle, reason) in [
        ("/users/", "macOS home path"), ("/home/", "Unix home path"), ("/root/", "Unix root home path"), (#":\users\"#, "Windows home path"), ("buzz", "excluded competitor")
    ] {
        if lower.contains(needle) { reasons.append(reason) }
    }
    for (pattern, reason) in [
        (#"[a-z]:[\\/]+users[\\/]"#, "Windows home path"),
        (#"~[a-z_][a-z0-9_.-]*[\\/]"#, "named-user home path"),
        (#"(?:\\u002f|%2f)(?:users|home)(?:\\u002f|%2f)"#, "encoded home path")
    ] {
        if (!reason.contains("named-user") || isText), lower.range(of: pattern, options: .regularExpression) != nil { reasons.append(reason) }
    }
    return reasons
}

// Competitor tokens that must not appear in anything shipped or published (text files only; binaries are not scanned for names).
let competitorTokens = ["whisper.cpp", "whispercpp", "whisper-cpp", "whisper_cpp", "whisper cpp", "ggml", "wcpp", "macwhisper", "buzz", "competitor_comparisons"]
func competitorMentions(_ text: String) -> [String] {
    let lower = text.lowercased()
    return competitorTokens.filter { lower.contains($0) }.map { "withdrawn competitor comparison: " + $0 }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}

if CommandLine.arguments.contains("--selftest") {
    let bad = [
        "/Users/private/file", "/home/private/file", "/root/private/file", #"C:\Users\private\file"#, "~private/file", "bUzZ.app", #"\u002fUsers\u002fprivate"#,
        "%2Fhome%2Fprivate", "lab/notes/private.md"
    ]
    for example in bad where violations(example).isEmpty { fail("public guard missed a forbidden identity kind") }
    for example in ["$HOME/Applications", "~/Applications", "mlx-community/checkpoint", "https://tobynoskillson.github.io/Vella/"] where !violations(example).isEmpty {
        fail("public guard rejected a portable identifier or generic shell placeholder")
    }
    // Compressed image bytes can resemble a short named-user tilde path; literal absolute paths and names still scan.
    if !violations("random ~ab/ bytes", isText: false).isEmpty { fail("public guard misread compressed image bytes") }
    for example in ["/Users/private/file", "/home/private/file", "/root/private/file", #"C:\Users\private\file"#, "bUzZ.app"] where violations(example, isText: false).isEmpty {
        fail("public guard missed an identity embedded in binary metadata")
    }
    for example in [
        "whisper.cpp Metal CLI", "wcpp-metal-server", "MacWhisper", "Buzz.app", "\"competitor_comparisons\": {}", "WhisperCpp", "whisper_cpp", "Whisper cpp", "ggml-fixture"
    ] where competitorMentions(example).isEmpty {
        fail("public guard missed a withdrawn competitor mention")
    }
    for example in ["Whisper large-v3 turbo", "mlx-whisper", "stock MLX"] where !competitorMentions(example).isEmpty {
        fail("public guard rejected a non-competitor mention")
    }
    print("public-data guard selftest ok"); exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count <= 1 else { fail("usage: public-data-guard.swift [checkout-root] | --selftest") }
let root = URL(fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
var files = ["Resources/benchmarks.json", "Resources/models.json", "README.md", "Resources/SKILL.md", "CHANGELOG.md"]
// Files that are scanned for competitor names only: the rest of Resources/ (the agent guide, plist, calibration data).
var competitorOnly: [String] = []
if let entries = FileManager.default.enumerator(atPath: root.appendingPathComponent("Resources").path) {
    while let relative = entries.nextObject() as? String {
        let path = "Resources/" + relative
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory), !isDirectory.boolValue, !files.contains(path) {
            competitorOnly.append(path)
        }
    }
}
let modelDocs = "Worker/Sources/MLXAudioSTT"
if let entries = FileManager.default.enumerator(atPath: root.appendingPathComponent(modelDocs).path) {
    while let relative = entries.nextObject() as? String {
        if relative.hasSuffix("/README.md") { files.append(modelDocs + "/" + relative) }
    }
}
let docs = root.appendingPathComponent("docs")
// DirectoryEnumerator URLs can canonicalize /var to /private/var independently of the root URL.
// Relative entries avoid substring slicing across those aliases.
if let entries = FileManager.default.enumerator(atPath: docs.path) {
    while let relative = entries.nextObject() as? String {
        let url = docs.appendingPathComponent(relative)
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.append("docs/" + relative)
        }
    }
}
guard files.contains("docs/data.js") else { fail("public-data guard: docs/data.js missing") }
var failures: [String] = []
for relative in files.sorted() {
    guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(relative).path) else { fail("cannot read " + relative) }
    let isText = String(data: data, encoding: .utf8) != nil
    var reasons = violations(String(decoding: data, as: UTF8.self), isText: isText)
    if isText { reasons += competitorMentions(String(decoding: data, as: UTF8.self)) }
    if !reasons.isEmpty { failures.append(relative + ": " + reasons.joined(separator: ", ")) }
}
for relative in competitorOnly.sorted() {
    guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(relative).path), let text = String(data: data, encoding: .utf8) else { continue }
    let reasons = competitorMentions(text)
    if !reasons.isEmpty { failures.append(relative + ": " + reasons.joined(separator: ", ")) }
}
// Every tracked public text file is covered, including metadata and strings compiled into the app.
let listing = Process(), pipe = Pipe()
listing.executableURL = URL(fileURLWithPath: "/usr/bin/git")
listing.arguments = ["-C", root.path, "ls-files", "-z"]
listing.standardOutput = pipe; listing.standardError = FileHandle.nullDevice
try listing.run()
let tracked = pipe.fileHandleForReading.readDataToEndOfFile()
listing.waitUntilExit()
let publicPaths =
    listing.terminationStatus == 0
    ? String(decoding: tracked, as: UTF8.self).split(separator: "\0").map(String.init)
    : (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
for relative in publicPaths {
    guard !["Tests/", "lab/", ".build/", ".git/"].contains(where: { relative.hasPrefix($0) }),
        !["scripts/public-data-guard.swift", "scripts/check-doc-claims.sh"].contains(relative),
        let data = FileManager.default.contents(atPath: root.appendingPathComponent(relative).path),
        let text = String(data: data, encoding: .utf8)
    else { continue }
    let reasons = competitorMentions(text)
    if !reasons.isEmpty { failures.append(relative + ": " + reasons.joined(separator: ", ")) }
}
// Drafts remain local; scan them when the release job supplies their folder.
if let folder = ProcessInfo.processInfo.environment["VELLA_RELEASE_DRAFTS"], let entries = FileManager.default.enumerator(atPath: folder) {
    while let relative = entries.nextObject() as? String {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(relative)
        guard ["RELEASE-NOTES-2.0.0.md", "WEBSITE-MASTER-BRIEF.md", "X-POST-DRAFT.md"].contains(relative), let text = try? String(contentsOf: url, encoding: .utf8) else {
            continue
        }
        let reasons = violations(text, isPublic: false) + competitorMentions(text)
        if !reasons.isEmpty { failures.append("release draft " + relative + ": " + reasons.joined(separator: ", ")) }
    }
}
if !failures.isEmpty { fail(failures.joined(separator: "\n")) }
print("public data contains portable provenance only and no competitor comparison (\(files.count + competitorOnly.count) files checked)")
