import XCTest
import VellaCore
import VellaTestSupport
@testable import VellaCLI

/// Executes every fenced CLI example with virtual API data: no user app, downloads, audio or GUI.
final class DocCLIExamplesTests: XCTestCase {
    private let row: [String: Any] = [
        "id": "parakeet-v3-ultra", "name": "Parakeet v3 Ultra", "dtype": "bf16", "mode": "Dictation", "loaded": true,
        "current": true, "action": "Unload", "selection": ["tier": "16", "path": "optimized", "mode": "fast"], "cells": [], "local_files": []
    ]
    private var status: [String: Any] {
        [
            "version": "2.0.0", "pid": 29335, "dictation": "idle", "api": 1,
            "models": ["parakeet-v3-ultra": ["precision": "BF16", "engine": "optimized", "selection": ["tier": "16", "path": "optimized", "mode": "fast"]]],
            "dictation_model": ["id": "parakeet-v3-ultra", "name": "Parakeet v3 Ultra", "selection": ["tier": "16", "path": "optimized", "mode": "fast"]]
        ]
    }
    private func tokens(_ command: String) -> [String] {
        // The documented shell examples use quoted setting values, no shell expansion beyond placeholders.
        let regex = try! NSRegularExpression(pattern: #""([^"\\]*(?:\\.[^"\\]*)*)"|'([^']*)'|([^\s]+)"#)
        let text = command as NSString
        return regex.matches(in: command, range: NSRange(location: 0, length: text.length)).map { match in
            for group in 1...3 where match.range(at: group).location != NSNotFound { return text.substring(with: match.range(at: group)) }
            return ""
        }
    }
    func testEveryDocumentedCLIExampleAndOutputShape() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-doc-examples-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("talk.m4a"); try Data("fixture".utf8).write(to: audio)
        try JSONSerialization.data(withJSONObject: ["app_pid": getpid(), "api_port": 63080, "api_token": "fixture"])
            .write(to: root.appendingPathComponent("worker-status.json"))
        var count = 0
        for path in ["README.md", "docs/USAGE.md", "Resources/SKILL.md", "Resources/AGENT_GUIDE.md", "AGENTS.md", "CONTRIBUTING.md"] {
            let doc = try String(contentsOf: Repository.root.appendingPathComponent(path), encoding: .utf8)
            var shell = false
            for (index, raw) in doc.components(separatedBy: "\n").enumerated() {
                if raw.hasPrefix("```") { shell = !shell && ["```sh", "```bash", "```shell", "```"].contains(raw); continue }
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard shell, line.hasPrefix("vella ") else { continue }
                let parts = line.components(separatedBy: "#")
                let command = parts[0].components(separatedBy: ">")[0].trimmingCharacters(in: .whitespaces)
                var args = Array(tokens(command).dropFirst())
                args = args.map { value in
                    if value == "talk.m4a" { return audio.path }
                    if ["MODEL_ID", "ID"].contains(value) { return "parakeet-v3-ultra" }
                    if value == "~/.agents/skills" { return root.appendingPathComponent("skills").path }
                    return value
                }
                var output: [String] = [], errors: [String] = []
                let settings: [String: Any] = ["Keep Hot": ["Manually loaded": "Always", "Loaded on demand": "15 min idle"], "Memory": "Fit in free memory"]
                let client = VellaClient(
                    environment: ["VELLA_SUPPORT_DIR": root.path, "VELLA_NO_LAUNCH": "1"],
                    transport: { request in
                        let path = request.url!.path
                        let object: Any
                        if path == "/status" {
                            object = self.status
                        } else if path == "/v1/models/catalog" {
                            object = ["data": [self.row]]
                        } else if path.hasPrefix("/v1/settings") {
                            object = settings
                        } else if path == "/v1/audio/transcriptions" {
                            let fields = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                            let format = fields["response_format"] as? String ?? "text"
                            let text = format == "srt" ? "1\n00:00:00,000 --> 00:00:01,000\nFixture words." : "Fixture words."
                            if ["text", "srt", "vtt"].contains(format) {
                                return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                            }
                            object = ["text": "Fixture words.", "language": fields["language"] as? String ?? "unknown", "segments": []]
                        } else {
                            object = self.row
                        }
                        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    })
                // diagnose's collector reads local resources; do not let it time the fixture's loaded row.
                var selectedClient = client
                if args.first == "diagnose" {
                    selectedClient.transport = { request in
                        (
                            try JSONSerialization.data(withJSONObject: ["api": 1, "models": [:], "dictation": "idle"]),
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                        )
                    }
                }
                let cli = VellaCLI(environment: client.environment, clientFactory: { selectedClient }, write: { output.append($0) }, warn: { errors.append($0) })
                let code = await cli.run(args)
                let location = "\(path):\(index + 1) \(command)"
                XCTAssertEqual(code, 0, location + " " + errors.joined(separator: "\n")); XCTAssertFalse(output.isEmpty, location)
                if parts.count > 1 {
                    let claim = parts.dropFirst().joined(separator: "#").trimmingCharacters(in: .whitespaces)
                    if claim.hasPrefix("Vella 2.") || claim.hasPrefix("http://") {
                        XCTAssertEqual(output.first, claim, location)
                    } else if claim.hasPrefix("parakeet-v3-ultra  ") {
                        XCTAssertEqual(output.first, claim.components(separatedBy: "   (one line").first, location)
                    }
                }
                switch args.first {
                case "models":
                    if args.contains("--json") {
                        XCTAssertNotNil((try? JSONSerialization.jsonObject(with: Data(output[0].utf8))) as? [String: Any], location)
                    } else {
                        XCTAssertEqual(output[0], VellaCLI.modelLine(row), location)
                    }
                case "status": XCTAssertEqual(output[0], VellaCLI.statusLine(status, port: 63080), location)
                case "url": XCTAssertEqual(output, ["http://127.0.0.1:63080/v1"], location)
                case "diagnose": XCTAssertTrue(output.last?.contains("prefilled GitHub bug report") == true, location)
                case "select", "get", "load", "reload", "unload", "delete": XCTAssertEqual(output[0], VellaCLI.modelLine(row), location)
                case "keep-hot", "memory": XCTAssertTrue(output[0].hasPrefix("Keep Hot · Manually loaded"), location)
                case "skill": XCTAssertTrue(output[0].hasPrefix("wrote "), location)
                case "transcribe": XCTAssertTrue(output[0].contains("Fixture words."), location)
                default: XCTFail("Documented command lacks output-shape assertion: " + location)
                }
                if let capture = ProcessInfo.processInfo.environment["VELLA_DOC_EXAMPLE_OUTPUTS"] {
                    let directory = URL(fileURLWithPath: capture)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = "cli-" + (args.first ?? "unknown") + (args.contains("--json") ? "-json" : args.contains("--verbose-json") ? "-verbose-json" : "")
                    try (command + "\n\n" + output.joined(separator: "\n")).write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                }
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 40, "All documented fenced CLI examples must remain covered")
    }
}
