#!/usr/bin/env swift
import Foundation

// Portable documentation generator, not an inference or measurement runner.
// xcrun swift scripts/benchmark-method.swift [--root DIR] [--check]
typealias JSON = [String: Any]
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
func object(_ value: Any?) -> JSON { value as? JSON ?? [:] }
func text(_ value: Any?) -> String { value as? String ?? "not recorded" }
func browserURL(_ value: Any?) -> String {
    let url = text(value), prefix = "https://raw.githubusercontent.com/"
    guard url.hasPrefix(prefix) else { return url }
    let parts = url.dropFirst(prefix.count).split(separator: "/").map(String.init)
    guard parts.count >= 4 else { return url }
    return "https://github.com/" + parts[0...1].joined(separator: "/") + "/blob/" + parts[2...].joined(separator: "/")
}
func number(_ value: Any?, _ digits: Int = 2) -> String {
    guard let value = value as? NSNumber else { return "not measured" }
    return String(format: "%.*f", digits, value.doubleValue)
}
func read(_ url: URL) -> JSON {
    guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? JSON else { fail("cannot read " + url.lastPathComponent) }
    return value
}
var args = Array(CommandLine.arguments.dropFirst()), check = false
var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
while !args.isEmpty {
    switch args.removeFirst() {
    case "--check": check = true
    case "--root": guard !args.isEmpty else { fail("--root needs a directory") }; root = URL(fileURLWithPath: args.removeFirst())
    default: fail("usage: benchmark-method.swift [--root DIR] [--check]")
    }
}
let b = read(root.appendingPathComponent("Resources/benchmarks.json"))
let m = read(root.appendingPathComponent("docs/benchmark-method.json"))
guard (b["schema"] as? NSNumber)?.intValue == 2, (m["schema"] as? NSNumber)?.intValue == 1 else { fail("unsupported benchmark methods input schema") }
let suites = object(m["suites"]), protocolData = object(m["protocol"]), gates = object(protocolData["gates"])
let scoring = object(m["scoring"]), sources = object(m["sources"]), builds = object(b["builds"])
let measured = object(builds["measured"]), shipped = object(builds["shipped"]), bridge = object(builds["bridge"])
let models = object(b["models"])
let catalog = read(root.appendingPathComponent("Resources/models.json"))
let families = catalog["families"] as? [JSON] ?? []
let names = Dictionary(uniqueKeysWithValues: families.map { (text($0["id"]), text($0["name"])) })
let paths = [("standard", "Standard"), ("optimized_exact", "Optimized Exact"), ("optimized_fast", "Optimized Fast")]
var lines = ["# Benchmark methods", "", "Vella 2.0.0. The published cell data is in [Resources/benchmarks.json](../Resources/benchmarks.json). Suite metadata is in [benchmark-method.json](benchmark-method.json). This document describes the measurements, not a prediction for every Mac.", "", "## Suites", "", "Quality uses the full v2 suite. Warm speed, energy and peak worker footprint use the frozen v2-quick subset. The suites are not interchangeable: quick excludes several long-form allocations and is not the source of the published quality figures.", "", "| Suite ID | Clips | Audio min | English min | Formatting min | Manifest SHA-256 |", "|---|---:|---:|---:|---:|---|"]
for key in ["v2", "v2-quick"] {
    let suite = object(suites[key]), publicSuite = object(object(b["suites"])[key])
    guard text(suite["id"]) == text(publicSuite["id"]), text(suite["manifest_sha256"]) == text(publicSuite["hash"]) else { fail("methods suite identity differs from benchmarks: " + key) }
    lines.append("| \(text(suite["id"])) | \(number(suite["clips"], 0)) | \(number(suite["minutes"], 3)) | \(number(object(object(suite["languages"])["en"])["minutes"], 3)) | \(number(object(suite["formatting"])["minutes"], 3)) | `\(text(suite["manifest_sha256"]))` |")
}
let quick = object(suites["v2-quick"])
lines += ["", "Durations above are calculated from manifest sample counts; the model table rounds suite minutes more coarsely. Both suites use \(number(object(suites["v2"])["sample_rate"], 0)) Hz mono PCM. The manifest hash is SHA-256 of the complete manifest bytes: it pins clip IDs, order, source revisions, references and per-clip file/PCM hashes. The runner verifies SHA-256 of little-endian signed PCM16 bytes before preparing worker inputs.", "", "v2-quick was frozen \(text(quick["frozen"])) with selection seed \(number(quick["selection_seed"], 0)). Selection is seeded shuffle within allocations, then round-robin across speaker/recording groups, with new groups first. It includes a long-form call to exercise segmentation and overlap joining. Excluded allocations: \((quick["excluded_allocations"] as? [String] ?? []).map { "`" + $0 + "`" }.joined(separator: ", ")).", "", "| Language | v2 clips | v2 min | v2-quick clips | v2-quick min |", "|---|---:|---:|---:|---:|"]
let fullLanguages = object(object(suites["v2"])["languages"]), quickLanguages = object(quick["languages"])
for lang in fullLanguages.keys.sorted() {
    let full = object(fullLanguages[lang]), short = object(quickLanguages[lang])
    lines.append("| \(lang) | \(number(full["clips"], 0)) | \(number(full["minutes"], 3)) | \(number(short["clips"], 0)) | \(number(short["minutes"], 3)) |")
}
lines += ["", "Language codes: en English, pl Polish, de German, fr French, es Spanish, sv Swedish, tr Turkish, ja Japanese, zh Mandarin Chinese, ko Korean.", "", "### Dataset identities and licences", "", "These are the source manifest's licence statements, not a grant to redistribute every recording. Sources marked no are not cleared for recording redistribution by this benchmark, whether because terms are restrictive or rights are unclear. No benchmark recording or reference transcript is included here.", "", "| Source ID / dataset | v2 clips / min | Quick clips / min | Licence | Audio redistributable |", "|---|---:|---:|---|---|"]
for id in sources.keys.sorted() {
    let source = object(sources[id]), full = object(object(object(suites["v2"])["sources"])[id]), short = object(object(quick["sources"])[id])
    let quickCount = short.isEmpty ? "0 / 0" : number(short["clips"], 0) + " / " + number(short["minutes"], 3)
    lines.append("| `\(id)` — \(text(source["name"])) | \(number(full["clips"], 0)) / \(number(full["minutes"], 3)) | \(quickCount) | \(text(source["licence"])) | \(source["redistributable"] as? Bool == true ? "yes" : "no") |")
}
lines += ["", "Pinned upstream revisions and attribution:", ""]
for id in sources.keys.sorted() {
    let source = object(sources[id])
    // Quoted revision field follows the repository citation guard's remote-revision convention.
    lines += ["- `\(id)`: \(text(source["url"]))", "  - \"revision\": \(text(source["revision"]))", "  - Licence: \(browserURL(source["licenceUrl"]))", "  - Attribution: \(text(source["attribution"]))", "  - Reference: \(text(source["referenceProduction"]))"]
}
lines += ["", "## Scoring", "", "**WER** is English lexical Levenshtein error: total substitutions + deletions + insertions, divided by total reference words, multiplied by 100. Counts are pooled across English clips, not averaged across clip percentages. Reference text is `lexicalReference` when provided, otherwise `reference`. Alignment ties choose substitution, then deletion, then insertion.", "", "**Format** is character error rate against the human-written English formatting subset, multiplied by 100. It is reference agreement, not a universal editorial-correctness score; lower is better. Case and punctuation remain. Both reference and hypothesis undergo the filler preprocessing below, then whitespace collapse and typographic canonicalization: curly double quotes become ASCII double quotes, curly single quotes become apostrophes, en/em dashes become hyphens, and ellipsis becomes three periods. If the reference's double quotes are unbalanced, or an opening quote lacks an opening boundary, double quotes are removed from both sides. Character edit counts and reference character counts are pooled. Auxiliary case/punctuation scores do not replace the published Format CER.", "", "Multilingual scores are separate from English WER. pl/de/fr/es/sv/tr use word tokens; ja/zh/ko use Unicode code points after width normalization, excluding whitespace, punctuation and symbols (CER, not WER). Supported-language coverage comes from the model language map. The scorer keeps separate unweighted supported-language WER and CER means. The gate's multilingual mean is an unweighted diagnostic across supported languages, including mixed units; it is not a pooled English WER.", "", "Normalizer `\(text(scoring["version"]))`; scorer SHA-256 `\(text(scoring["scorer_sha256"]))`; formatting scorer SHA-256 `\(text(scoring["formatting_scorer_sha256"]))`.", "", "### Exact preprocessing", "", "This is the scorer's executable preprocessing. It is applied identically to reference and hypothesis. English expands digit forms (including currencies, percentages and ordinals), removes only standalone fillers, keeps contractions, and treats hyphens as word breaks. Multilingual preprocessing does not apply English filler/number rules.", "", "```python", text(scoring["normalizer_python"]), "```", "", "## Warm speed and segmentation", "", "Speed (RTFx) = original audio seconds / warm-pass wall seconds. The model is loaded and a first request is run before the timed pass. The numerator does not count duplicated overlap or synthetic streaming gaps.", "", "Inside the timer: the sequential worker request loop, stdio/JSON transport, worker reading the prepared segment WAVs, feature extraction, inference/decoding, reply handling, overlap assembly and per-clip cache reads. This is a worker benchmark using the app's segmentation policy, not a kernel-only timer. Outside: original file decode/resampling, preparation of segmented PCM/WAV inputs, model load/first-request warm-up, and the app/HTTP layer. `vella transcribe` end-to-end additionally includes decoding the file and app/HTTP work, so its wall time is not the catalog's speed denominator.", "", "Dictation follows `SegmentedPCMWriter` and `RecordingSession` semantics: silence-aware cuts, forced-cut overlap, final-tail merge/re-split and conservative text overlap removal. Whisper uses a longer preferred window than other dictation architectures. The Python port differs only in code-point versus Swift grapheme-cluster counting for the overlap text window, and last-bit RMS summation order; it is not the app process itself.", "", "Streaming clips are concatenated into a persistent session, with a \(number(protocolData["stream_gap_seconds"])) s digital-silence endpoint gap between clips, then finished. Requests send \(number(protocolData["stream_packet_samples"], 0))-sample PCM packets faster than real time. Its timer includes packet encoding, gaps and final commit; it does not measure microphone-to-visible-text latency. Streaming state can make transcripts depend on clip order and shard boundaries. Identity checks must replay the same preceding stream and shards.", "", "## Energy and memory", "", "VellaEnergy reads cumulative macOS IOReport Energy Model counters at bracket start and end: there is **no fixed energy sampling interval**. The components are CPU + GPU + ANE + DRAM, system-wide, not attributed to the worker and not wall-socket power. Unavailable channels yield no figure rather than zero.", "", "Each fresh-worker run records cold load/warm-up separately, then a \(number(protocolData["baseline_ms"], 0)) ms loaded-idle baseline, then a warm workload bracket. For each component: `net joules = work joules − loaded-idle joules × (work seconds / idle seconds)`; negative differences are retained. Sum the four components and divide by original audio minutes for J / min. The energy bracket ends after child exit/teardown, slightly beyond the speed timer. The \(number(protocolData["idle_poll_ms"], 0)) ms dictation-idle polling is a precondition check, not energy sampling.", "", "There are \(number(protocolData["energy_repeats"], 0)) repeats per cell. Slow workloads are sharded into bounded brackets (\(number(protocolData["bracket_limit_seconds"], 0)) s limit); each shard has its own loaded-idle subtraction. A repeat merges shard joules and audio durations, and sums warm wall times before calculating speed. Published speed is the median repeat speed; energy is the median clean-repeat J / min. The aggregator requires at least two clean repeats for energy, otherwise it publishes no energy figure; each cell's `energy_note` records the clean count and range. Peak RAM is the maximum worker `proc_pid_rusage` peak footprint across repeats, including loading, reported in MiB despite the table's MB label. It is not total app or system RAM.", "", "CPU-only work takes a shared quiet lock. GPU correctness work adds an exclusive GPU lock; its timings are not catalog measurements. Measurement takes the exclusive quiet lock plus GPU lock, so managed builds/tests and inference do not overlap. The wrapper also waits for idle dictation and checks foreign CPU/GPU activity before beginning. Steady display/terminal compositing is recorded separately and covered by the idle subtraction; excessive compositing prevents a start. These locks do not stop unrelated user work.", "", "Within a bracket, the absolute change in foreign CPU use between loaded-idle and work must be at most \(number(protocolData["foreign_cpu_delta_cores"])) cores, after subtracting the change in `kernel_task` GPU-driver CPU work when readable. Dictation observed during the preconditions or idle baseline fails the idle guard; this polling is not a continuous guard inside the warm workload. Contaminated brackets are not published; the driver quarantines unfinished evidence and retries up to \(number(protocolData["max_attempts"], 0)) total attempts, then blocks. The contamination check is a proxy, not proof that all background energy is eliminated.", "", "## Build and hardware identity", "", "Measured hardware: \(text(b["hardware"])), \(number(protocolData["gpu_cores"], 0)) GPU cores. Measurement dates: \((measured["dates"] as? [String] ?? []).joined(separator: ", ")). Measured build `\(text(measured["commit"]))`, built from `\(text(measured["built_from"]))`; worker SHA-256 `\(text(measured["worker_sha256"]))`. Frozen lever-map SHA-256 `\(text(measured["env_map_sha256"]))`.", "", "Authoritative shipped source identities:", ""]
for key in object(shipped["worker_source_trees"]).keys.sorted() {
    lines.append("- \(key) Git tree: `\(text(object(shipped["worker_source_trees"])[key]))`.")
}
lines += ["- Build-script SHA-256: `\(text(shipped["build_scripts_sha256"]))`.", "- Build-script change: \(text(shipped["build_scripts_note"]))", "- CI worker SHA-256: \(shipped["worker_sha256"] as? String ?? "pending verified publication artifact; no local binary is substituted").", "", "Commit IDs identify published history; tree and byte hashes pin content even if history is rewritten. Model checkpoint revisions and derived-quantization recipes are pinned in [models.json](../Resources/models.json) and each benchmark cell's `recipe`.", "", "Carried-over measurements use a scoped **CPU-only identity bridge**, not a fresh performance run: \(text(bridge["summary"])) No cross-build speed/energy spot remeasurement was performed for this bridge. Source/key/verdict equality is evidence about executed code, not evidence that binary bytes are identical. Clean Swift rebuilds differ even under the same compiler; the Metal library is byte-identical.", "", "Recorded Whisper Fast identity receipt: \(text(object(bridge["whisper_fast_token_identity"])["summary"]))", "", "| Model | Recorded recipe gate revisions |", "|---|---|"]
for id in models.keys.sorted() {
    var revisions = Set<String>()
    for tier in object(object(models[id])["tiers"]).values {
        for (key, _) in paths { if let revision = object(object(object(tier)[key])["recipe"])["gate_revision"] as? String { revisions.insert(revision) } }
    }
    lines.append("| \(names[id] ?? id) | \(revisions.sorted().map { "`" + $0 + "`" }.joined(separator: ", ")) |")
}
if let night = builds["night"] as? JSON {
    lines += ["", "Refreshed same-build cells: source `\(text(night["source_commit"]))`, worker SHA-256 `\(text(night["worker_sha256"]))`. Per-cell `measured` and `build_provenance` fields identify their own date and build; older figures do not silently acquire the refresh date."]
}
lines += ["", "## Modes and gates", "", "**Standard** runs no kept optimization levers. **Optimized Exact** runs exact kept levers only. **Optimized Fast** runs every kept lever, including inexact ones. Kept levers ship on by default in their mode; benchmark environment switches are A/B controls, not user setup requirements. Exact components match the stock path on the load-time self-test, not a universal transcript-identity guarantee. Identical recipes can share a canonical measured cell through `display_cells`; separate recipes or missing measurements must not borrow a sibling's figure.", "", "The load-time hardware/component self-test, tier **presence** gate and task-quality gate are different checks. Presence decides whether a tier is offered at all. The tighter task-quality gate (historically called the recommendation gate) records whether loss exceeds the measured noise allowance; Vella does not automatically recommend a tier.", "", "Presence fails for request errors/worker exits, an empty or truncated clip beyond the recorded lost-clip allowance, English or supported-language mean degradation at or above +\(number(gates["PRESENCE_WER_PT"])) percentage points, or any supported language at or above +\(number(gates["PRESENCE_LANG_PT"])) points. Lost clips are empty hypotheses or deleted reference tails containing at least \(number(gates["TAIL_WORDS"], 0)) units the baseline had correct. CJK uses character units. Middle-clip deletion spans and total deletion counts are reported, not independently gated.", "", "For English WER and Format CER, tolerance = `min(\(number(gates["T_CAP"])), max(\(number(gates["T_FLOOR"])), English noise + \(number(gates["T_MARGIN"]))))` points. For the supported-language mean, tolerance = `min(\(number(gates["T_ML_CAP"])), max(\(number(gates["T_ML_FLOOR"])), multilingual noise + \(number(gates["T_ML_MARGIN"]))))`. Each supported language with at least \(number(gates["LANG_MIN_MINUTES"])) minutes must not degrade by more than +\(number(gates["LANG_WORSE_PT"])) points. Errors and lost clips are also checked. The historical streaming trade policy permits a multilingual-only failure when English and the other checks pass and speed is at least \(number(gates["STREAM_SPEED_TRADE"]))× the fastest outright-passing tier; it is not a relaxation of the presence gate. The final per-cell runner calls the strict comparator directly and does not apply that historical override.", "", "Dated noise pairs are reused, not rerun on the final build. A pair is a measured rate difference, not a confidence interval or a three-seed loss calibration. Missing pairs use the absolute tolerance floor and are not claimed to have zero measured noise.", "", "| Model | Noise pair date | English noise pt | ML noise pt | English / Format limit pt | ML mean limit pt |", "|---|---|---:|---:|---:|---:|"]
let noise = object(object(b["noise_floor"])["families"])
for id in noise.keys.sorted() {
    let value = object(noise[id])
    lines.append("| \(names[id] ?? id) | \(value["noise_date"] as? String ?? "no pair") | \(number(value["noise_pt"])) | \(number(value["noise_ml_pt"])) | \(number(value["tolerance_pt"])) | \(number(value["tolerance_ml_pt"])) |")
}
lines += ["", "Pair identities:", ""]
for id in noise.keys.sorted() { lines.append("- \(names[id] ?? id): \(text(object(noise[id])["noise_source"])).") }
lines += ["", "Gate baselines are retained in the data, not inferred from the mode name. Final Whisper per-cell and tier gates use same-build faithful FP16 Standard, measured in the same quiet window as shared Exact/Fast. Non-Whisper gates use their recorded same-build tier-16 Standard controls. Historical Whisper Float32-baseline verdicts were withdrawn and are not the final gates.", "", "## Not measured yet", ""]
var pending: [String: [String]] = [:]
for id in models.keys.sorted() {
    for tierID in object(object(models[id])["tiers"]).keys.sorted() {
        let tier = object(object(object(models[id])["tiers"])[tierID])
        for (key, title) in paths {
            let cell = object(tier[key])
            if cell["measured"] as? JSON == nil {
                pending[text(cell["not_measured_reason"]), default: []].append("\(names[id] ?? id) · tier \(tierID) · \(title)")
            }
        }
    }
}
if pending.isEmpty { lines.append("No offered cells currently have missing measurement status. Per-cell dates/builds still apply.") }
for reason in pending.keys.sorted() { lines.append("- \(pending[reason]!.joined(separator: "; ")): \(reason)") }
lines += ["", "The original Whisper loader made a Float32 positional table that promoted activations away from checkpoint dtype. The shipped loader fixes this and removes the encoder-dtype lever. Earlier Standard/Exact figures were withdrawn rather than relabeled as faithful fp16 measurements. The historical Fast identity receipt did not create Standard/Exact measurements. The final faithful FP16 Standard and shared Exact/Fast cells were measured together in a quiet window completed 4 October; deltas and gates use that FP16 Standard baseline. Unoffered tiers are a gate decision, not missing measurements.", "", "## Check your Mac", "", "Run `vella diagnose` while Vella is idle with a dictation model loaded; `vella diagnose --json` returns structured data. It never starts the app or downloads a model. `--load` explicitly loads the selected dictation model first. It reports hardware, OS/app/worker versions, selected mode, active components and fallbacks.", "", "For each loaded dictation model it runs five built-in public clips: one warm-up pass, whose transcripts are compared, then three sequential timed passes. Local speed is total clip audio seconds divided by median pass time. The timing uses the app's HTTP API and includes file decode and transport, unlike the catalog worker timer. Transcript comparison is whitespace-token edit distance with case/punctuation kept, **not** the v2 normalizer or WER against dataset gold. It compares with the qualified reference for that model, precision and effective mode only; missing/unqualified references are not replaced. Streaming models are reported but not timed by this API diagnostic.", "", "Different Macs and fallback components can change speed and text. Reference speed remains an M5 Max measurement, never an estimate for your Mac, and diagnose does not measure energy. A short five-clip diagnostic is not a full-suite quality gate. A provisional bundled reference is labeled as provisional rather than qualified release evidence.", "", "## Reproduction and drift checks", "", "`xcrun swift scripts/benchmark-method.swift --check` regenerates this document from the portable suite snapshot and published benchmark data and fails if it differs. Release checks run it alongside the other documentation checks. The private finalization step also verifies the snapshot against the source manifests/scorer and runs this check. The snapshot is repository documentation, not an app resource.", "", "The measurement runner itself will be published with 2.1 after cleanup. In 2.0 this is a methods description with pinned dataset identities, scoring rules and measured cell provenance, not a claim that the complete runner and source manifests are already public. No universal Apple Silicon speed/energy result, bit-reproducible Swift binary, or full-suite OS build identifier is asserted beyond the recorded evidence."]
if let index = lines.firstIndex(of: "## Warm speed and segmentation") {
    lines.insert(contentsOf: ["After `strip_fillers_formatted` above, Format applies this canonicalization and quote-eligibility rule before character alignment:", "", "```python", text(scoring["formatting_python"]), "```", ""], at: index - 1)
}
if let index = lines.firstIndex(where: { $0.hasPrefix("Carried-over measurements") }), let note = shipped["note"] as? String {
    lines.insert(contentsOf: ["Shipped-source scope: " + note, ""], at: index)
}
let receipt = object(m["build_receipt"])
if let index = lines.firstIndex(of: "| Model | Recorded recipe gate revisions |") {
    lines.insert(contentsOf: ["Clean rebuild receipt: Swift driver/compiler `\(text(receipt["swift"]))`; `\(text(receipt["metal"]))`; `\(text(receipt["xcode"]))`; macOS build `\(text(receipt["os_build"]))`. This is the rebuild receipt, not a per-bracket OS-build capture. Identical `default.metallib` SHA-256: `\(text(receipt["metallib_sha256"]))`.", ""], at: index)
}
let policies = object(protocolData["segmentation_policies"])
let policyRows = ["", "Segmentation `\(text(protocolData["segmentation_version"]))`:", "", "| Policy | Preferred s | Maximum s | Silence s / RMS | Overlap s | Minimum tail s | Merge slack s |", "|---|---:|---:|---|---:|---:|---:|"] + policies.keys.sorted().map { key -> String in
    guard let values = policies[key] as? [NSNumber], values.count == 7 else { fail("invalid segmentation policy") }
    return "| \(key) | \(number(values[0])) | \(number(values[1])) | \(number(values[2])) / \(number(values[3], 3)) | \(number(values[4])) | \(number(values[5])) | \(number(values[6])) |"
} + [""]
if let index = lines.firstIndex(of: "## Energy and memory") { lines.insert(contentsOf: policyRows, at: index - 1) }
let result = lines.joined(separator: "\n") + "\n", output = root.appendingPathComponent("docs/BENCHMARKS.md")
if check {
    guard (try? String(contentsOf: output, encoding: .utf8)) == result else { fail("docs/BENCHMARKS.md differs from generator") }
    print("benchmark methods: generated document matches published inputs")
} else {
    do { try result.write(to: output, atomically: true, encoding: .utf8) } catch { fail("cannot write docs/BENCHMARKS.md") }
    print("wrote docs/BENCHMARKS.md")
}
