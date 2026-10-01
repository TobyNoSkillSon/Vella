import XCTest
import VellaTestSupport

/// The per-model READMEs, the skill's model list and the user guide's API section are generated from
/// Resources/models.json and Resources/benchmarks.json (scripts/model-readmes.swift, scripts/agent-docs.swift), so they cannot
/// drift from the catalog or the measured figures. The scripts are Swift scripts run with `xcrun swift`, like the repository's
/// other build scripts.
final class ModelDocsTests: XCTestCase {
    static let root = Repository.root
    static let xcrun = "/usr/bin/xcrun"
    /// Runtime folder of each architecture, as in scripts/model-readmes.swift.
    static let folders = [
        "parakeet": "Worker/Sources/MLXAudioSTT/Parakeet", "qwen3_asr": "Worker/Sources/MLXAudioSTT/Qwen3ASR",
        "whisper": "Worker/Sources/MLXAudioSTT/Whisper", "nemotron_asr": "Worker/Sources/MLXAudioSTT/NemotronASR"
    ]

    func text(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }

    func script(_ name: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.xcrun), "no xcrun")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.xcrun)
        process.arguments = ["swift", Self.root.appendingPathComponent("scripts/\(name)").path] + arguments
        process.currentDirectoryURL = Self.root
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testModelReadmesMatchTheGenerator() throws {
        let result = try script("model-readmes.swift", ["--check"])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testSkillAndUserGuideModelListsMatchTheGenerator() throws {
        let result = try script("agent-docs.swift", ["--check"])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testGeneratorsHandlePendingAndMeasuredFiles() throws {
        for name in ["model-readmes.swift", "agent-docs.swift"] {
            let result = try script(name, ["--selftest"])
            XCTAssertEqual(result.status, 0, "\(name): \(result.output)")
            XCTAssertTrue(result.output.contains("selftest ok"), name)
        }
    }

    /// While the figures are pending, the generated blocks show no figure.
    func testPendingFiguresShowNoNumbers() throws {
        let bench = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("Resources/benchmarks.json"))) as? [String: Any]
        guard bench?["figures_pending"] as? Bool == true else { return }
        for path in ["Resources/SKILL.md", "docs/USAGE.md"] {
            let body = try text(path)
            let block = try XCTUnwrap(body.components(separatedBy: "<!-- MODELS_START -->").dropFirst().first?.components(separatedBy: "<!-- MODELS_END -->").first)
            XCTAssertTrue(block.contains("Figures pending"), path)
            for line in block.components(separatedBy: "\n") where line.hasPrefix("| `") {
                XCTAssertTrue(line.hasSuffix("| — | — | — | — |"), "\(path): \(line)")
            }
        }
    }

    /// Every catalog family is covered by the README of its architecture's folder, and each README has the sections the
    /// contribution recipe asks for.
    func testEveryModelFolderHasAReadmeWithTheRequiredSections() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/models.json"))
        let families = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["families"] as? [[String: Any]])
        XCTAssertFalse(families.isEmpty)
        var covered = Set<String>()
        for family in families {
            let id = try XCTUnwrap(family["id"] as? String)
            let variants = try XCTUnwrap(family["variants"] as? [String: [String: Any]])
            let architecture = try XCTUnwrap(variants.values.compactMap { $0["architecture"] as? String }.first)
            let folder = try XCTUnwrap(Self.folders[architecture], "\(id): no README folder for \(architecture)")
            let readme = try text("\(folder)/README.md")
            XCTAssertTrue(readme.contains("`\(id)`"), "\(folder)/README.md does not name \(id)")
            covered.insert(folder)
        }
        for folder in covered {
            let readme = try text("\(folder)/README.md")
            for section in [
                "## What it is", "## Tiers offered, and why", "## What Vella optimizes", "## Rejected levers", "## Quality gate", "## Measured figures",
                "<!-- MEASURED_START -->", "<!-- MEASURED_END -->", "Screening numbers"
            ] {
                XCTAssertTrue(readme.contains(section), "\(folder)/README.md lacks \(section)")
            }
            XCTAssertTrue(readme.contains("calibrat"), "\(folder)/README.md states the no-calibration ruling")
            XCTAssertFalse(readme.contains("{{"), folder)
        }
    }

    /// The switches and revision strings a README names for its kept levers exist in the code.
    func testReadmeSwitchesAndRevisionsExistInTheSource() throws {
        var source = ""
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Worker/Sources"), includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "swift" { source += try String(contentsOf: url, encoding: .utf8) }
        }
        let pairs: [(folder: String, tokens: [String])] = [
            ("Parakeet", [
                "VELLA_PARAKEET_INT8", "+int8-2", "VELLA_PARAKEET_INT4", "+int4-2", "VELLA_PARAKEET_TAILBLOCK", "+tailblock-1",
                "VELLA_PARAKEET_NAX", "VELLA_DICTATION_KEEP_CACHE", "parakeet-r2-dense-encoder", "smallm-"
            ]),
            ("NemotronASR", ["VELLA_NEMO_KEEPCACHE", "keepcache-1", "VELLA_NEMO_JOINTBATCH", "jointbatch-1", "nemotron-stream-5", "VELLA_FORCE_STOCK"]),
            ("Qwen3ASR", ["qwen3-asr-3-f32-encoder-p3"]),
            ("Whisper", ["whisper-3-f16-model", "VELLA_DICTATION_KEEP_CACHE"])
        ]
        for pair in pairs {
            let readme = try text("Worker/Sources/MLXAudioSTT/\(pair.folder)/README.md")
            for token in pair.tokens {
                XCTAssertTrue(source.contains(token), "\(token) is not in Worker/Sources")
                if token != "smallm-" { XCTAssertTrue(readme.contains(token), "\(pair.folder)/README.md does not name \(token)") }
            }
        }
        let parakeet = try text("Worker/Sources/MLXAudioSTT/Parakeet/README.md")
        XCTAssertTrue(source.contains("qtile-1") && parakeet.contains("qtile-1"))
    }
}
