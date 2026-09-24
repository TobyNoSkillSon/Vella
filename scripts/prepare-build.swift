import Foundation

func fail(_ message: String) -> Never {
    fputs("Vella: \(message)\n", stderr); exit(1)
}

func command(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws {
    let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
    let errors = Pipe(); child.standardOutput = Pipe(); child.standardError = errors
    try child.run()
    let deadline = Date().addingTimeInterval(timeout)
    while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if child.isRunning { child.terminate(); throw NSError(domain: "Tool timed out: \(arguments.joined(separator: " "))", code: 1) }
    guard child.terminationStatus == 0 else {
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw NSError(domain: "\(arguments.joined(separator: " ")) failed: \(detail.suffix(3000))", code: Int(child.terminationStatus))
    }
}

func checkTools() {
    print("Checking Xcode, Metal Toolchain and SwiftUI compatibility…")
    do {
        try command("/usr/bin/xcode-select", ["-p"], timeout: 10)
        let selected = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); process.arguments = ["-p"]
            let pipe = Pipe(); process.standardOutput = pipe
            try? process.run(); process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        var normalized = selected
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let developer = normalized.hasSuffix(".app") ? normalized + "/Contents/Developer" : normalized
        guard developer.hasSuffix("/Contents/Developer"), FileManager.default.fileExists(atPath: developer + "/Platforms/MacOSX.platform") else {
            fail("A complete Xcode installation is required for source builds (Command Line Tools alone cannot compile MLX Metal shaders). Existing Vella was not replaced.")
        }
        try command("/usr/bin/xcrun", ["--find", "metal"], timeout: 15)
        try command("/usr/bin/xcrun", ["swift", "package", "--version"], timeout: 30)
        try command("/usr/bin/xcrun", ["swiftc", "-typecheck", "-target", "arm64-apple-macosx14.0", "Tests/StateCompatibilityFixture.swift"], timeout: 120)
    } catch { fail("The selected Xcode/Metal Toolchain cannot build Vella: \(error). Install or repair full Xcode and its Metal Toolchain component; existing Vella was not replaced.") }
}

func compact(_ output: URL) throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let policy = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Resources/benchmark-policy.json"))) as? [String: Any] ?? [:]
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("Resources/ReferenceResults")
    for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
        guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { continue }
        guard record["suiteID"] as? String == policy["suiteID"] as? String,
              record["suiteHash"] as? String == policy["suiteHash"] as? String,
              (record["repeats"] as? Int ?? -1) >= (policy["minimumRepeats"] as? Int ?? Int.max) else { continue }
        let formatting = record["formatting"] as? [String: Any] ?? [:]
        if let hash = policy["scorerSHA256"] as? String, formatting["scorerSHA256"] as? String != hash { continue }
        if let hash = policy["lexicalNormalizerSHA256"] as? String, formatting["lexicalNormalizerSHA256"] as? String != hash { continue }
        record["clips"] = []
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .fragmentsAllowed])
        try (data + Data([10])).write(to: output.appendingPathComponent(file.lastPathComponent), options: .atomic)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["check"] { checkTools() }
else if args.count == 2 && args[0] == "compact" {
    do { try compact(URL(fileURLWithPath: args[1])) }
    catch { fail("Reference-result compaction failed; existing Vella was not replaced: \(error)") }
} else { fail("Usage: prepare-build.swift check | compact <output-directory>") }
