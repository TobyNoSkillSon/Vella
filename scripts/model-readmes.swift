import Foundation

// Fill the measured block of every model folder's README from Resources/benchmarks.json and Resources/models.json.
//
//   xcrun swift scripts/model-readmes.swift             rewrite the blocks between <!-- MEASURED_START --> and <!-- MEASURED_END -->
//   xcrun swift scripts/model-readmes.swift --check     change nothing; exit 1 and name each README whose block is not the generator's
//   xcrun swift scripts/model-readmes.swift --selftest  check the generator on synthetic data (a pending and a measured file)
//   options: --root DIR (the checkout, default the current directory), --benchmarks FILE, --models FILE
//
// The READMEs are written by hand; only the block between the markers is generated. Run it after Resources/models.json or
// Resources/benchmarks.json changes and commit the result; Tests/VellaCoreTests/ModelDocsTests runs --check. While
// benchmarks.json has `figures_pending: true` every figure is `—`, as in the Models table.

typealias JSON = [String: Any]

let startMarker = "<!-- MEASURED_START -->"
let endMarker = "<!-- MEASURED_END -->"
/// Runtime folder of each architecture (a catalog variant's `architecture`); its README covers every family built on it.
let folders = [
    "parakeet": "Worker/Sources/MLXAudioSTT/Parakeet",
    "qwen3_asr": "Worker/Sources/MLXAudioSTT/Qwen3ASR",
    "whisper": "Worker/Sources/MLXAudioSTT/Whisper",
    "nemotron_asr": "Worker/Sources/MLXAudioSTT/NemotronASR"
]
let tiers = ["16", "8", "4"]
let paths = [("standard", "Standard"), ("optimized_exact", "Optimized Exact"), ("optimized_fast", "Optimized Fast")]
let dash = "—"
let minus = "−"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadJSON(_ path: String) -> JSON {
    guard let data = FileManager.default.contents(atPath: path), let object = try? JSONSerialization.jsonObject(with: data) as? JSON else {
        fail("cannot read \(path)")
    }
    return object
}

func number(_ value: Double?, _ digits: Int) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? dash }
func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

func trimmed(_ value: Double) -> String {
    var text = String(format: "%.1f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

func percentChange(_ new: Double?, _ old: Double?) -> String {
    guard let new, let old, old != 0 else { return dash }
    let rounded = Int(((new - old) / old * 100).rounded())
    if rounded == 0 { return "0 %" }
    return (rounded > 0 ? "+" : minus) + String(abs(rounded)) + " %"
}

func isPending(_ bench: JSON) -> Bool { bench["figures_pending"] as? Bool ?? false }
func families(_ models: JSON) -> [JSON] { models["families"] as? [JSON] ?? [] }

func dtypeLabel(_ family: JSON, _ tier: String) -> String {
    switch tier {
    case "8": return "int8"
    case "4": return "int4"
    default: return family["native_dtype"] as? String == "float16" ? "fp16" : "bf16"
    }
}

func architecture(_ family: JSON) -> String {
    let variants = family["variants"] as? [String: JSON] ?? [:]
    let names = Set(variants.values.compactMap { $0["architecture"] as? String })
    guard names.count == 1, let name = names.first else { fail("\(family["id"] ?? "?"): variants name \(names.count) architectures, expected one") }
    return name
}

func readmeFolder(_ family: JSON) -> String {
    guard let folder = folders[architecture(family)] else {
        fail("\(family["id"] ?? "?"): no README folder for architecture \(architecture(family)) (add it to `folders`)")
    }
    return folder
}

/// The measured cell for a family, tier and path, or nil.
func cell(_ bench: JSON, _ id: String, _ tier: String, _ path: String) -> JSON? {
    let tierEntry = ((bench["models"] as? JSON)?[id] as? JSON).flatMap { ($0["tiers"] as? JSON)?[tier] as? JSON }
    guard let value = tierEntry?[path] as? JSON, value["measured"] as? JSON != nil else { return nil }
    return value
}

func replaceBlock(_ text: String, _ body: String) -> String? {
    guard text.components(separatedBy: startMarker).count == 2, text.components(separatedBy: endMarker).count == 2,
        let start = text.range(of: startMarker), let end = text.range(of: endMarker), start.upperBound <= end.lowerBound
    else { return nil }
    var block = body
    while block.hasSuffix("\n") { block.removeLast() }
    return String(text[..<start.upperBound]) + "\n" + block + "\n" + String(text[end.lowerBound...])
}

func pendingLine() -> String {
    "Figures pending: the 2.0.0 measurement has not been written into `Resources/benchmarks.json` yet (`figures_pending` is true), "
        + "so no figure is shown. A figure that is not measured is \(dash)."
}

/// One line naming hardware, suites and dates of the measured cells of the given families (the ones this README shows).
/// Every distinct value is listed, in sorted order, so the text does not depend on dictionary iteration order and a mix of
/// suites, dates or machines is visible instead of one of them labelling all cells.
func measuredLine(_ bench: JSON, families ids: [String]) -> String {
    let suites = bench["suites"] as? [String: JSON] ?? [:]
    var dates = Set<String>(), machines = Set<String>(), accuracy = Set<String>(), performance = Set<String>()
    for id in ids {
        let tiers = ((bench["models"] as? JSON)?[id] as? JSON)?["tiers"] as? [String: JSON] ?? [:]
        for tier in tiers.values {
            for (path, _) in paths {
                guard let measured = (tier[path] as? JSON)?["measured"] as? JSON else { continue }
                if let date = measured["date"] as? String { dates.insert(date) }
                machines.insert(measured["hardware"] as? String ?? bench["hardware"] as? String ?? dash)
                if let suite = measured["suite"] as? String { accuracy.insert(suite) }
                if let suite = measured["performance_suite"] as? String { performance.insert(suite) }
            }
        }
    }
    func minutes(_ name: String) -> String {
        guard let value = double((suites[name])?["audio_min"]) else { return dash }
        return "\(trimmed(value)) min"
    }
    func list(_ names: Set<String>) -> String {
        names.isEmpty ? dash : names.sorted().map { "\($0) (\(minutes($0)))" }.joined(separator: ", ")
    }
    let sorted = dates.sorted()
    let when = sorted.isEmpty ? dash : (sorted.count == 1 ? sorted[0] : "\(sorted[0]) to \(sorted[sorted.count - 1])")
    let hardware = machines.isEmpty ? dash : machines.sorted().joined(separator: "; ")
    return "Measured \(when) on \(hardware). Accuracy: \(list(accuracy)); speed, energy and peak RAM: \(list(performance))."
}

/// How a tier's weights are made (Resources/models.json), in words.
func recipeText(_ family: JSON, _ tier: String) -> String {
    if tier == "16" { return family["native_dtype"] as? String == "float32" ? "converted once from the fp32 download" : "the checkpoint as published" }
    let variant = (family["variants"] as? [String: JSON])?[tier == "8" ? "8b" : "4b"] ?? [:]
    guard let group = (variant["groupSize"] as? NSNumber)?.intValue else { fail("\(family["id"] ?? "?"): the \(tier == "8" ? "8b" : "4b") variant has no groupSize") }
    var text = "affine group \(group) from the \(dtypeLabel(family, "16")) weights"
    if let kept = variant["floatModules"] as? [String], !kept.isEmpty {
        text += "; " + kept.map { "`\($0)`" }.joined(separator: ", ") + " kept at \(dtypeLabel(family, "16"))"
        if let share = double(variant["floatShare"]) { text += " (" + String(format: "%.1f", share * 100) + " % of the source checkpoint's weight bytes)" }
    }
    return text
}

/// Gate and presence of a tier against 16, or `—` (also for 16 itself, the baseline, and while figures are pending).
func gateText(_ bench: JSON, _ id: String, _ tier: String) -> String {
    let entry = ((bench["models"] as? JSON)?[id] as? JSON).flatMap { ($0["tiers"] as? JSON)?[tier] as? JSON }
    guard tier != "16", let entry, !isPending(bench) else { return dash }
    let gate = entry["gate"] as? JSON ?? [:]
    let presence = entry["presence"] as? JSON
    let word = (presence?["offered"] as? Bool).map { $0 ? "present" : "absent" } ?? dash
    var text = "\(gate["status"] as? String ?? dash); \(word)"
    // Why a tier is absent (or, if it is present, why the recommendation gate failed), each under its own label.
    if let why = presence?["reasons"] as? [String], !why.isEmpty {
        text += ": " + why.joined(separator: "; ")
    } else if let why = gate["reasons"] as? [String], !why.isEmpty {
        text += "; gate: " + why.joined(separator: "; ")
    }
    return text
}

/// The family's gate limits (English and multilingual tolerance, measured noise floors), or nil.
func limitsText(_ bench: JSON, _ id: String) -> String? {
    guard let entry = (bench["models"] as? JSON)?[id] as? JSON else { return nil }
    var parts: [String] = []
    for (label, tolerance, noise) in [("English", "tolerance_pt", "noise_pt"), ("multilingual mean", "tolerance_ml_pt", "noise_ml_pt")] {
        guard let limit = double(entry[tolerance]) else { continue }
        var text = "\(label) ≤ \(number(limit, 2)) pt"
        if let floor = double(entry[noise]) { text += " (measured noise \(number(floor, 2)) pt)" }
        parts.append(text)
    }
    return parts.isEmpty ? nil : "Gate limits: " + parts.joined(separator: ", ") + "."
}

func renderFamily(_ family: JSON, _ bench: JSON) -> [String] {
    let id = family["id"] as? String ?? ""
    let hide = isPending(bench)
    var lines = ["#### \(family["name"] as? String ?? id) (`\(id)`)", ""]
    if !hide, let limits = limitsText(bench, id) { lines += [limits, ""] }
    lines += ["| Tier | Runs as | Offered | Gate vs 16 |", "|---|---|---|---|"]
    let offered = family["tiers_offered"] as? [String] ?? []
    for tier in tiers {
        lines.append(
            "| \(tier) (\(dtypeLabel(family, tier))) | \(recipeText(family, tier)) | \(offered.contains(tier) ? "yes" : "no") | \(gateText(bench, id, tier)) |")
    }
    lines += [
        "", "| Tier | Path | WER % | Format % | Multilingual WER % | Speed | J / audio min | Peak RAM MB | Speed vs Standard | Energy vs Standard |",
        "|---|---|---|---|---|---|---|---|---|---|"
    ]
    for tier in tiers {
        let standard = hide ? nil : cell(bench, id, tier, "standard")
        for (path, title) in paths {
            var row = Array(repeating: dash, count: 8)
            if !hide, let figures = cell(bench, id, tier, path) {
                let speed = double(figures["speed_x"]), joules = double(figures["j_per_min"])
                let compared = path != "standard" && standard != nil
                row = [
                    number(double(figures["wer"]), 2), number(double(figures["format"]), 2),
                    number(double((figures["multilingual"] as? JSON)?["mean"]), 2), speed.map { number($0, 1) + "×" } ?? dash,
                    number(joules, 2), number(double(figures["memory_mb"]), 0),
                    compared ? percentChange(speed, double(standard?["speed_x"])) : dash,
                    compared ? percentChange(joules, double(standard?["j_per_min"])) : dash
                ]
            }
            lines.append("| \(tier) (\(dtypeLabel(family, tier))) | \(title) | " + row.joined(separator: " | ") + " |")
        }
    }
    return lines
}

/// What a quantized tier leaves at the source dtype besides the Linear and Embedding layers the group size does not divide
/// (`DerivedPrecision.quantizationTargets`), per architecture.
let keptFloat = [
    "qwen3_asr": " The audio tower stays float at every tier.",
    "nemotron_asr": " The predictor's LSTM stays at bf16 at every tier."
]

func renderBlock(_ folder: String, _ models: JSON, _ bench: JSON) -> String {
    let own = families(models).filter { readmeFolder($0) == folder }
    let ids = own.compactMap { $0["id"] as? String }
    let extra = Set(own.map(architecture)).sorted().compactMap { keptFloat[$0] }.joined()
    var lines = [
        "<!-- Generated by scripts/model-readmes.swift from Resources/benchmarks.json and Resources/models.json. Do not edit between the markers; run the script. -->",
        "", isPending(bench) ? pendingLine() : measuredLine(bench, families: ids), "",
        "Speed is × real time, energy is joules per minute of audio (whole chip, idle subtracted), peak RAM is the worker's peak footprint. "
            + "\"vs Standard\" compares the same tier's Optimized cell with its Standard cell. \"Offered\" is `tiers_offered` in "
            + "`Resources/models.json`; \"Gate vs 16\" is the quality gate and presence verdict in `Resources/benchmarks.json`. "
            + "A quantized tier rounds only the Linear and Embedding layers whose input width the group size divides; every other tensor "
            + "and every kept module stays at the source dtype." + extra,
        ""
    ]
    for family in own { lines += renderFamily(family, bench) + [""] }
    while lines.last == "" { lines.removeLast() }
    return lines.joined(separator: "\n")
}

/// Every README folder, in catalog order.
func targets(_ models: JSON) -> [String] {
    var result: [String] = []
    for family in families(models) where !result.contains(readmeFolder(family)) { result.append(readmeFolder(family)) }
    return result
}

func run(root: URL, models: JSON, bench: JSON, check: Bool) -> [String] {
    var stale: [String] = []
    for folder in targets(models) {
        let relative = folder + "/README.md"
        let url = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            stale.append("\(relative): missing")
            continue
        }
        guard let updated = replaceBlock(text, renderBlock(folder, models, bench)) else {
            stale.append("\(relative): needs exactly one \(startMarker) ... \(endMarker) pair")
            continue
        }
        if updated == text { continue }
        if check {
            stale.append("\(relative): generated block is stale")
        } else {
            do { try updated.write(to: url, atomically: true, encoding: .utf8) } catch { fail("cannot write \(relative): \(error)") }
            print("wrote \(relative)")
        }
    }
    return stale
}

func selfTest() {
    let family: JSON = [
        "id": "demo", "name": "Demo", "native_dtype": "float16", "tiers_offered": ["16", "8"],
        "variants": [
            "FP16": ["architecture": "whisper"],
            "8b": ["architecture": "whisper", "groupSize": 64, "floatModules": ["model.encoder"], "floatShare": 0.4081] as JSON,
            "4b": ["architecture": "whisper", "groupSize": 64] as JSON
        ] as JSON
    ]
    // A second family on another architecture, measured on other suites and another date: it must not label the first one.
    let other: JSON = [
        "id": "other", "name": "Other", "native_dtype": "bfloat16", "tiers_offered": ["16"],
        "variants": ["BF16": ["architecture": "parakeet"], "8b": ["architecture": "parakeet", "groupSize": 64] as JSON] as JSON
    ]
    let models: JSON = ["families": [family, other]]
    func figures(_ speed: Double, _ joules: Double, date: String = "2026-10-02", suite: String = "v2", performance: String = "v2-quick") -> JSON {
        [
            "wer": 17.2, "format": 7.7, "multilingual": ["mean": 21.8] as JSON, "speed_x": speed, "j_per_min": joules, "memory_mb": 3346,
            "measured": ["date": date, "suite": suite, "performance_suite": performance] as JSON
        ]
    }
    let demoTiers: JSON = [
        "16": ["standard": figures(10, 100), "optimized_fast": figures(20, 80)] as JSON,
        "8": ["gate": ["status": "pass"] as JSON, "presence": ["offered": true, "reasons": []] as JSON] as JSON,
        "4": ["gate": ["status": "fail"] as JSON, "presence": ["offered": false, "reasons": ["1 clip lost"]] as JSON] as JSON
    ]
    var bench: JSON = [
        "figures_pending": false, "hardware": "Test Mac", "suites": ["v2": ["audio_min": 239.7], "v2-quick": ["audio_min": 22.5]] as JSON,
        "models": [
            "demo": ["tolerance_pt": 0.1, "noise_pt": 0.04, "tolerance_ml_pt": 0.2, "tiers": demoTiers] as JSON,
            "other": ["tiers": ["16": ["standard": figures(5, 50, date: "2026-09-28", suite: "v2-quick", performance: "v2")] as JSON] as JSON] as JSON
        ] as JSON
    ]
    let whisper = folders["whisper"]!
    let block = renderBlock(whisper, models, bench)
    for expected in [
        "| 16 (fp16) | Optimized Fast | 17.20 | 7.70 | 21.80 | 20.0× | 80.00 | 3346 | +100 % | −20 % |",
        "| 16 (fp16) | Standard | 17.20 | 7.70 | 21.80 | 10.0× | 100.00 | 3346 | — | — |",
        "| 8 (int8) | affine group 64", "`model.encoder` kept at fp16 (40.8 % of the source checkpoint's weight bytes)", "| 4 (int4) |", "fail; absent: 1 clip lost",
        "Gate limits: English ≤ 0.10 pt (measured noise 0.04 pt), multilingual mean ≤ 0.20 pt.",
        "Measured 2026-10-02 on Test Mac. Accuracy: v2 (239.7 min); speed, energy and peak RAM: v2-quick (22.5 min)."
    ] where !block.contains(expected) { fail("selftest: missing \(expected)") }
    if block.contains("2026-09-28") || block.contains("Test Mac. Accuracy: v2-quick") { fail("selftest: another family's date or suite labels this README") }
    // Mixed suites, dates and machines inside one README are all listed, in sorted order, and the text is the same every time.
    var mixed = bench
    var mixedModels = mixed["models"] as? JSON ?? [:]
    var mixedDemo = mixedModels["demo"] as? JSON ?? [:]
    var mixedTiers = mixedDemo["tiers"] as? JSON ?? [:]
    var mixedSixteen = mixedTiers["16"] as? JSON ?? [:]
    var extra = figures(30, 70, date: "2026-10-04", suite: "v2-quick", performance: "v2")
    var extraMeasured = extra["measured"] as? JSON ?? [:]
    extraMeasured["hardware"] = "Other Mac"
    extra["measured"] = extraMeasured
    mixedSixteen["optimized_exact"] = extra
    mixedTiers["16"] = mixedSixteen
    mixedDemo["tiers"] = mixedTiers
    mixedModels["demo"] = mixedDemo
    mixed["models"] = mixedModels
    let mixedLine = "Measured 2026-10-02 to 2026-10-04 on Other Mac; Test Mac. Accuracy: v2 (239.7 min), v2-quick (22.5 min); "
        + "speed, energy and peak RAM: v2 (239.7 min), v2-quick (22.5 min)."
    for _ in 0..<20 where !renderBlock(whisper, models, mixed).contains(mixedLine) { fail("selftest: mixed metadata is not listed deterministically") }
    // A present tier whose recommendation gate failed keeps its gate reasons apart from presence reasons.
    let failing: JSON = ["status": "fail", "reasons": ["x +1 pt"]]
    let tierEight: JSON = ["gate": failing, "presence": ["offered": true] as JSON]
    let gated: JSON = ["models": ["demo": ["tiers": ["8": tierEight] as JSON] as JSON] as JSON]
    if gateText(gated, "demo", "8") != "fail; present; gate: x +1 pt" { fail("selftest: \(gateText(gated, "demo", "8"))") }
    bench["figures_pending"] = true
    let pending = renderBlock(whisper, models, bench)
    if !pending.contains("Figures pending") || pending.contains("20.0×") || pending.contains("fail; absent") { fail("selftest: pending block shows figures") }
    let replaced = replaceBlock("a\n\(startMarker)\nold\n\(endMarker)\nb\n", "new")
    if replaced != "a\n\(startMarker)\nnew\n\(endMarker)\nb\n" { fail("selftest: replaceBlock") }
    if replaceBlock("no markers", "x") != nil { fail("selftest: replaceBlock accepted a file without markers") }
    print("selftest ok")
}

// MARK: main

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
if arguments.contains("--selftest") {
    selfTest()
    exit(0)
}
let check = arguments.contains("--check")
let root = URL(fileURLWithPath: option("--root") ?? FileManager.default.currentDirectoryPath)
let models = loadJSON(option("--models") ?? root.appendingPathComponent("Resources/models.json").path)
let bench = loadJSON(option("--benchmarks") ?? root.appendingPathComponent("Resources/benchmarks.json").path)
let stale = run(root: root, models: models, bench: bench, check: check)
for line in stale { FileHandle.standardError.write(Data((line + "\n").utf8)) }
if !stale.isEmpty {
    if check { FileHandle.standardError.write(Data("run `xcrun swift scripts/model-readmes.swift` and commit the result\n".utf8)) }
    exit(1)
}
if check { print("model READMEs match Resources/benchmarks.json and Resources/models.json") }
