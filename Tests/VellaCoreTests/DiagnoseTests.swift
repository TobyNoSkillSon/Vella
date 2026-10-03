import XCTest
@testable import VellaCore
import VellaTestSupport

/// `vella diagnose`: the report text, JSON, comparison with the reference transcripts, privacy, and the issue URL.
final class DiagnoseFormatTests: XCTestCase {
    static let host = Diagnosis.Host(chip: "Apple M4 Pro", hardware: "Mac16,7", memoryGB: 48, macos: "15.5", osBuild: "24F74", gpuFamily: "apple9")

    static let reference = DiagnoseReference(
        chip: "Apple M5 Max", gate_version: "native-kernels-8", method: "api",
        models: [
            "parakeet-v3-ultra": [
                "BF16": [
                    "optimized_fast": .init(
                        transcripts: [
                            "clip-a": "One two three.", "clip-b": "Four five six seven.", "clip-c": "Eight.",
                            "clip-d": "Nine ten.", "clip-e": "Eleven twelve."
                        ], speed_x: 512.3)
                ]
            ]
        ])

    func clips(_ texts: [String]) -> [Diagnosis.Clip] { zip(Diagnose.clips, texts).map { Diagnosis.Clip(name: $0.0.name, text: $0.1) } }

    func testReportOptimizedStockAndStreamingModels() throws {
        let ref = Self.reference.run(model: "parakeet-v3-ultra", precision: "BF16", engine: "optimized", selection: ModelSelection(tier: .t16, path: .optimized, mode: .fast))
        XCTAssertNotNil(ref)
        let got = Diagnose.compare(clips(["One two three.", "Four five sixty seven.", "Eight.", "Nine ten.", "eleven twelve"]), with: ref)
        let run = Diagnosis.Run(
            clips: got, passSeconds: [0.060, 0.050, 0.070], audioSeconds: 22.855,
            reference: Diagnose.referenceLabel(Self.reference, engine: "optimized"), referenceSpeedX: 512.3)
        let fast = Diagnosis.Model(
            id: "parakeet-v3-ultra", name: "Parakeet v3 Ultra", mode: "dictation", precision: "BF16", engine: "optimized",
            optimizations: ["decoder": true, "encoder": true], residency: "manual", workerVersion: "native-kernels-8", run: run)
        let slow = Diagnosis.Model(
            id: "qwen3-asr-1.7b", mode: "dictation", precision: "8b", engine: "mlx",
            engineReason: "The optimized path failed its self-test against stock MLX on this Mac.",
            optimizations: ["decoder": false], residency: "on_demand", notTimed: "Vella's API did not answer (timed out)")
        let stream = Diagnosis.Model(
            id: "nemotron-3.5-streaming-0.6b", mode: "streaming", precision: "BF16", engine: "optimized",
            optimizations: ["encoder": true, "decoder": false], residency: "manual",
            notTimed: "streaming models are not served by the API")
        let d = Diagnosis(
            cliVersion: "1.0.0 (35)", appVersion: "1.0.0 (35)", api: 1, host: Self.host, running: true, dictation: "idle",
            models: [fast, slow, stream],
            gate: [
                .init(status: "fast", model: "parakeet-ultra-mlx-bf16", workerVersion: "native-kernels-8"),
                .init(status: "stock", model: "Qwen3-ASR-1.7B-8bit", reason: "self-test: optimized output differs from stock MLX", workerVersion: "native-kernels-8"),
                .init(status: "stock", workerVersion: "native-kernels-7")
            ],
            gateVersion: "native-kernels-8")
        XCTAssertEqual(
            Diagnose.text(d),
            [
                "vella diagnose",
                "vella 1.0.0 (35) · app 1.0.0 (35) · API 1 · worker native-kernels-8",
                "Mac: M4 Pro · Mac16,7 · 48 GB · macOS 15.5 (24F74) · GPU family apple9",
                "parakeet-v3-ultra: Optimized · M4 Pro · BF16 · manual",
                "  optimized: decoder, encoder",
                "  fallbacks: none",
                "  clips: 3/5 identical to the reference (M5 Max, optimized); clip-b 1 word off, clip-e 2 words off · 22.9 s of audio at 381× real time (M5 Max: 512×)",
                "qwen3-asr-1.7b: MLX · 8b · on demand",
                "  optimized: none",
                "  fallbacks: The optimized path failed its self-test against stock MLX on this Mac.",
                "  not timed: Vella's API did not answer (timed out)",
                "nemotron-3.5-streaming-0.6b: Optimized · M4 Pro · BF16 · streaming · manual",
                "  optimized: encoder",
                "  fallbacks: stock: decoder",
                "  not timed: streaming models are not served by the API",
                "gate verdicts: 1 optimized, 1 stock (Qwen3-ASR-1.7B-8bit: self-test: optimized output differs from stock MLX) · 1 from an older worker version"
            ])
        XCTAssertEqual(Diagnose.title(d), "M4 Pro, macOS 15.5: parakeet-v3-ultra BF16 clips differ from the reference")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Diagnose.jsonText(d, issueURL: "u").utf8)) as? [String: Any])
        XCTAssertEqual(json["issue_url"] as? String, "u")
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        let first = try XCTUnwrap(models.first?["run"] as? [String: Any])
        XCTAssertEqual(first["speed_x"] as? Double, 380.92)
        XCTAssertEqual(first["identical"] as? Int, 3)
        let clipB = try XCTUnwrap((first["clips"] as? [[String: Any]])?[1])
        XCTAssertEqual(clipB["word_edits"] as? Int, 1)
        XCTAssertEqual(clipB["reference"] as? String, "Four five six seven.")
        XCTAssertTrue(models[1]["run"] is NSNull)
        XCTAssertEqual((json["gate_verdicts"] as? [Any])?.count, 3)
    }

    func testTitleForStockAndQuietReports() {
        var d = Diagnosis(
            host: Self.host, running: true,
            models: [
                Diagnosis.Model(id: "parakeet-v3", precision: "4b", engine: "mlx", engineReason: "The optimized kernels need Apple GPU family 9; this GPU reports apple8.")
            ])
        XCTAssertEqual(Diagnose.title(d), "M4 Pro, macOS 15.5: parakeet-v3 on MLX: The optimized kernels need Apple GPU family 9; this GPU reports apple8.")
        d.models = []
        XCTAssertEqual(Diagnose.title(d), "M4 Pro, macOS 15.5: diagnose report")
        d.running = false
        XCTAssertEqual(Diagnose.title(d), "M4 Pro, macOS 15.5: Vella not running")
    }

    func testNotRunningNothingLoadedAndNoReference() {
        var d = Diagnosis(host: Self.host, running: false)
        XCTAssertEqual(
            Diagnose.text(d),
            [
                "vella diagnose", "vella dev", "Mac: M4 Pro · Mac16,7 · 48 GB · macOS 15.5 (24F74) · GPU family apple9",
                "Vella is not running: start it from Applications and run `vella diagnose` again.",
                "gate verdicts: none yet (a model's first load runs its self-test)"
            ])
        d.running = true; d.dictationModel = "parakeet-v3-ultra"; d.referenceAvailable = false; d.dictation = "recording"
        d.switches = ["VELLA_FORCE_STOCK"]; d.refused = "Parakeet needs 1.3 GB; 0.4 GB is free."
        let text = Diagnose.text(d)
        XCTAssertTrue(text.contains("dictation: recording"))
        XCTAssertTrue(text.contains("no model loaded: nothing timed. `vella diagnose --load` loads the dictation model (parakeet-v3-ultra) and times it."))
        XCTAssertTrue(text.contains("reference transcripts: missing for this build"))
        XCTAssertEqual(text.suffix(2), ["last refusal: Parakeet needs 1.3 GB; 0.4 GB is free.", "diagnostic switches set: VELLA_FORCE_STOCK"])
    }

    func testReportStatesWhenItsReferenceIsProvisional() throws {
        let provisional = try XCTUnwrap(DiagnoseReference.decode(Data(#"{"schema": 2, "provisional": true, "models": {}}"#.utf8)))
        let qualified = try XCTUnwrap(DiagnoseReference.decode(Data(#"{"schema": 2, "models": {}}"#.utf8)))
        XCTAssertEqual(provisional.provisional, true)
        XCTAssertNotEqual(qualified.provisional, true)
        var d = Diagnosis(host: Self.host, running: false, referenceProvisional: provisional.provisional == true)
        let note = "reference: provisional (captured under load); speed comparisons are indicative only"
        XCTAssertEqual(Diagnose.text(d).filter { $0.hasPrefix("reference") }, [note])
        XCTAssertEqual(Diagnose.json(d, issueURL: "u")["reference_provisional"] as? Bool, true)
        d.referenceProvisional = qualified.provisional == true
        XCTAssertTrue(Diagnose.text(d).filter { $0.hasPrefix("reference") }.isEmpty)
        XCTAssertEqual(Diagnose.json(d, issueURL: "u")["reference_provisional"] as? Bool, false)
    }

    func testRunWithoutReferenceForThisPrecisionOrPath() {
        XCTAssertNil(Self.reference.run(model: "parakeet-v3-ultra", precision: "BF16", engine: "mlx"), "the stock path has its own reference")
        XCTAssertNil(Self.reference.run(model: "parakeet-v3-ultra", precision: "4b", engine: "optimized"))
        XCTAssertNil(Self.reference.run(model: "parakeet-v3-ultra", precision: nil, engine: "optimized"))
        let run = Diagnosis.Run(clips: clips(["a", "b", "", "d", "e"]), passSeconds: [2.0], audioSeconds: 22.855)
        let lines = Diagnose.modelLines(Diagnosis.Model(id: "qwen3-asr-1.7b", precision: "4b", engine: "optimized", run: run), chip: "Apple M1")
        XCTAssertEqual(lines.last, "  clips: 5 transcribed, no reference for 4b on this path; 1 empty · 22.9 s of audio at 11× real time")
        XCTAssertEqual(Diagnose.referenceLabel(DiagnoseReference(hardware: "Apple M5 Max, macOS 26.6"), engine: "mlx"), "M5 Max, stock MLX")
    }

    func testGateVerdictsWithoutALoadedModelCountTheNewestWorkerVersion() {
        let d = Diagnosis(
            host: Self.host, running: false,
            gate: [
                .init(status: "stock", workerVersion: "native-kernels-9"), .init(status: "fast", workerVersion: "native-kernels-10"),
                .init(status: "fast", model: "m", workerVersion: "native-kernels-10")
            ])
        XCTAssertEqual(Diagnose.text(d).last, "gate verdicts: 2 optimized · 1 from an older worker version")
    }

    /// Two-stage gate: a fast verdict with a reason is optimized without a tolerant component; it says which and why.
    func testPartialGateVerdictListsTheDisabledComponent() {
        let d = Diagnosis(
            host: Self.host, running: false,
            gate: [
                .init(
                    status: "fast", model: "parakeet-v3-ultra-bf16", reason: "optimized without nax_gemm (word edits 2 > 1 over the clips)",
                    workerVersion: "native-kernels-9"),
                .init(status: "fast", model: "m", workerVersion: "native-kernels-9")
            ])
        XCTAssertEqual(
            Diagnose.text(d).last,
            "gate verdicts: 2 optimized (parakeet-v3-ultra-bf16: optimized without nax_gemm (word edits 2 > 1 over the clips))")
    }

    func testWordEdits() {
        XCTAssertEqual(Diagnose.wordEdits("a b c", "a b c"), 0)
        XCTAssertEqual(Diagnose.wordEdits("a  b\nc", "a b c"), 0, "whitespace does not count")
        XCTAssertEqual(Diagnose.wordEdits("Hello, world.", "hello world"), 2, "case and punctuation count: formatting is output")
        XCTAssertEqual(Diagnose.wordEdits("a b c d", "a c d e"), 2)
        XCTAssertEqual(Diagnose.wordEdits("", "a b"), 2)
        XCTAssertEqual(Diagnose.wordEdits("a b", ""), 2)
        XCTAssertEqual(Diagnose.median([3, 1, 2]), 2)
        XCTAssertEqual(Diagnose.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(Diagnose.median([]), 0)
    }

    /// Nothing personal leaves the Mac: paths under a home folder are cut, gate model names are kept only when they
    /// look like a model folder's name.
    func testRedactionAndSafeNames() {
        let home = NSHomeDirectory()
        XCTAssertEqual(Diagnose.redact("could not read \(home)/Library/Application Support/Vella/Models/x"), "could not read ~/Library/Application Support/Vella/Models/x")
        XCTAssertEqual(Diagnose.redact("at /Users/someone/Models/a.safetensors; retry"), "at ~/Models/a.safetensors; retry")
        XCTAssertEqual(Diagnose.redact("no path here"), "no path here")
        XCTAssertEqual(Diagnose.safeModelName("parakeet-ultra-mlx-bf16"), "parakeet-ultra-mlx-bf16")
        XCTAssertNil(Diagnose.safeModelName("/Users/someone/x"))
        XCTAssertNil(Diagnose.safeModelName("a b"))
        let d = Diagnosis(
            host: Self.host, running: true,
            models: [Diagnosis.Model(id: "m", engine: "mlx", engineReason: "failed at /Users/someone/Library/x")],
            gate: [.init(status: "stock", model: "/Users/someone/x", reason: "\(home)/y")], statusError: "\(home)/z missing")
        let text = Diagnose.text(d).joined(separator: "\n") + Diagnose.jsonText(d, issueURL: "") + Diagnose.issueURL(d)
        XCTAssertFalse(text.contains("/Users/"), text)
        XCTAssertFalse(text.contains(home), text)
    }

    func testReferenceFileDecodes() throws {
        XCTAssertNil(DiagnoseReference.decode(Data(#"{"schema": 3, "models": {}}"#.utf8)))
        let lab = try XCTUnwrap(
            DiagnoseReference.decode(
                Data(
                    #"""
                    {"schema": 2, "chip": "Apple M5 Max", "method": "api", "extra": 1, "models": {"parakeet-v3": {"8b": {"standard":
                      {"transcripts": {"clip-a": "x"}, "speed_x": 100.5, "pass_s": [0.2], "wall_ms": {"clip-a": 1}}}}}}
                    """#.utf8)))
        XCTAssertEqual(lab.run(model: "parakeet-v3", precision: "8b", engine: "mlx")?.speed_x, 100.5)
        let url = Repository.root.appendingPathComponent("Resources/diagnose-reference.json")
        let raw = try Data(contentsOf: url)
        let schema = (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["schema"] as? Int ?? 0
        if schema < 2 { XCTAssertNil(DiagnoseReference.decode(raw), "do not compare the stale bundled reference") }
        let bundled = try XCTUnwrap(DiagnoseReference.decode(raw), "local schema-2 reference must be readable by app and CLI")
        XCTAssertNotNil(bundled.run(model: "parakeet-v3-ultra", precision: "BF16", engine: "optimized", selection: ModelSelection(tier: .t16, path: .optimized, mode: .fast)))
        for model in ["whisper-large-v3", "whisper-large-v3-turbo"] {
            for precision in ["FP16", "8b"] {
                XCTAssertNil(bundled.run(model: model, precision: precision, engine: "mlx"))
                XCTAssertNil(bundled.run(model: model, precision: precision, engine: "optimized", selection: ModelSelection(tier: .t16, path: .optimized, mode: .exact)))
            }
        }
        XCTAssertNil(DiagnoseReference.decode(Data(#"{"schema": 1, "models": {}}"#.utf8)))
    }

    func testSegmentedReferenceSeparatesFastExactAndStandard() throws {
        let fast = DiagnoseReference.Run(transcripts: ["clip-a": "fast"], speed_x: 500)
        let exact = DiagnoseReference.Run(transcripts: ["clip-a": "exact"], speed_x: 300)
        let standard = DiagnoseReference.Run(transcripts: ["clip-a": "standard"], speed_x: 200)
        let ref = DiagnoseReference(schema: 2, models: ["test": ["8b": ["optimized_fast": fast, "optimized_exact": exact, "standard": standard]]])
        XCTAssertEqual(DiagnoseReference.decode(try JSONEncoder().encode(ref)), ref)
        let selection = ModelSelection(tier: .t8, path: .optimized, mode: .fast)
        XCTAssertEqual(ref.run(model: "test", precision: "8b", engine: "optimized", selection: selection), fast)
        var precise = selection; precise.mode = .exact
        XCTAssertEqual(ref.run(model: "test", precision: "8b", engine: "optimized", selection: precise), exact)
        XCTAssertEqual(ref.run(model: "test", precision: "8b", engine: "mlx", selection: precise), standard)
        XCTAssertNil(ref.run(model: "test", precision: "8b", engine: "optimized"), "do not guess the segment")
        let legacy = DiagnoseReference(schema: 1, models: ["test": ["8b": ["optimized": fast, "mlx": standard]]])
        XCTAssertNil(legacy.run(model: "test", precision: "8b", engine: "optimized", selection: selection))
        XCTAssertNil(legacy.run(model: "test", precision: "8b", engine: "optimized", selection: precise))
        XCTAssertNil(legacy.run(model: "test", precision: "8b", engine: "mlx", selection: precise))
    }
}

final class IssueURLTests: XCTestCase {
    func query(_ url: String) throws -> [String: String] {
        let items = try XCTUnwrap(URLComponents(string: url)?.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testShortReportIsCarriedWhole() throws {
        let body = "vella diagnose\nMac: M3 · macOS 15.1\nparakeet-v3: MLX & more?=#"
        let url = IssueURL.bugReport(
            repository: "https://github.com/o/r", title: "M3: parakeet-v3 on MLX",
            fields: [("chip", "M3, Mac15,3"), ("macos", "15.1"), ("version", "")], diagnose: body, maxLength: 7000)
        XCTAssertTrue(url.hasPrefix("https://github.com/o/r/issues/new?template=bug_report.yml&title="), url)
        let q = try query(url)
        XCTAssertEqual(q["template"], "bug_report.yml")
        XCTAssertEqual(q["title"], "M3: parakeet-v3 on MLX")
        XCTAssertEqual(q["chip"], "M3, Mac15,3")
        XCTAssertEqual(q["macos"], "15.1")
        XCTAssertNil(q["version"], "empty fields are left out")
        XCTAssertEqual(q["diagnose"], body)
        XCTAssertFalse(url.contains(" ") || url.contains("\n") || url.contains("·"))
    }

    func testLongReportIsCutAtALineWithinTheLimit() throws {
        let lines = (0..<400).map { "line \($0): optimized · clips 5/5 · ✓ é" }
        let body = lines.joined(separator: "\n")
        for limit in [7000, 2000, 700] {
            let url = IssueURL.bugReport(repository: "https://github.com/o/r", title: "t", fields: [("chip", "M1")], diagnose: body, maxLength: limit)
            XCTAssertLessThanOrEqual(url.count, limit)
            let value = try XCTUnwrap(query(url)["diagnose"], "percent escapes are intact")
            XCTAssertTrue(value.hasSuffix(IssueURL.truncationNote), value)
            let kept = String(value.dropLast(IssueURL.truncationNote.count))
            XCTAssertTrue(body.hasPrefix(kept + "\n"), "whole lines only")
            XCTAssertGreaterThan(kept.split(separator: "\n").count, 0)
        }
    }

    func testOneHugeLineIsCutByCharacters() throws {
        let body = String(repeating: "ž", count: 5000)
        let url = IssueURL.bugReport(repository: "https://github.com/o/r", title: "t", fields: [], diagnose: body, maxLength: 1000)
        XCTAssertLessThanOrEqual(url.count, 1000)
        let value = try XCTUnwrap(query(url)["diagnose"])
        XCTAssertTrue(value.hasSuffix(IssueURL.truncationNote))
        XCTAssertTrue(value.dropLast(IssueURL.truncationNote.count).allSatisfy { $0 == "ž" })
    }

    func testReportURLAndTheBugForm() throws {
        let d = Diagnosis(appVersion: "1.0.0 (35)", host: DiagnoseFormatTests.host, running: false)
        let q = try query(Diagnose.issueURL(d))
        XCTAssertEqual(q["chip"], "M4 Pro, Mac16,7")
        XCTAssertEqual(q["macos"], "15.5 (24F74)")
        XCTAssertEqual(q["version"], "1.0.0 (35)")
        XCTAssertEqual(q["diagnose"], Diagnose.text(d).joined(separator: "\n"))
        XCTAssertTrue(Diagnose.issueURL(d).hasPrefix("https://github.com/TobyNoSkillSon/Vella/issues/new?template=bug_report.yml&"))
        let form = Repository.root
            .appendingPathComponent(".github/ISSUE_TEMPLATE/\(IssueURL.template)")
        guard let text = try? String(contentsOf: form, encoding: .utf8) else { throw XCTSkip("no bug form in this checkout") }
        for id in ["diagnose", "chip", "macos", "version"] { XCTAssertTrue(text.contains("id: \(id)\n"), "the form has field \(id)") }
    }

}
