import Foundation
import VellaWire

// `vella diagnose`: the report's data, its one-screen text, its JSON and the prefilled GitHub issue URL. Collection
// (the running app's API, sysctl, the gate's verdict files) lives in the `vella` command; everything here is pure.
// Nothing personal goes into a report: no paths, no recordings, no transcripts of the user's speech. The only audio is
// the five public self-test clips in the app bundle.

/// Transcripts and speed of the bundled self-test clips on the reference Mac (Resources/diagnose-reference.json):
/// family id → precision (as worker-status.json reports it) → segment ("optimized_fast", "optimized_exact", "standard") → run. References older than schema 2 are rejected.
public struct DiagnoseReference: Codable, Equatable {
    public struct Run: Codable, Equatable {
        public var transcripts: [String: String]
        /// Clip seconds / median wall time of one pass over the five clips through the API.
        public var speed_x: Double?
        public init(transcripts: [String: String], speed_x: Double? = nil) { self.transcripts = transcripts; self.speed_x = speed_x }
    }
    public var schema: Int
    public var date: String?
    /// "Apple M5 Max, macOS 26.6"
    public var hardware: String?
    public var chip: String?
    public var gpu_family: String?
    public var app_version: String?
    public var gate_version: String?
    /// "api" (measured as `vella diagnose` measures) or "worker" (the speed is indicative only).
    public var method: String?
    public var models: [String: [String: [String: Run]]]
    public init(
        schema: Int = 2, date: String? = nil, hardware: String? = nil, chip: String? = nil, gpu_family: String? = nil,
        app_version: String? = nil, gate_version: String? = nil, method: String? = nil, models: [String: [String: [String: Run]]] = [:]
    ) {
        self.schema = schema; self.date = date; self.hardware = hardware; self.chip = chip; self.gpu_family = gpu_family
        self.app_version = app_version; self.gate_version = gate_version; self.method = method; self.models = models
    }
    public func run(model: String, precision: String?, engine: String?, selection: ModelSelection? = nil) -> Run? {
        guard schema >= 2, let precision, let engine, let runs = models[model]?[precision] else { return nil }
        let segment: String
        if engine != "optimized" {
            segment = "standard"
        } else if let selection {
            segment = effectiveSelection(selection, engine: engine).segmentKey.rawValue
        } else {
            // A new segmented reference cannot guess Fast versus Exact from the engine alone.
            return nil
        }
        if let run = runs[segment] { return run }
        return nil
    }
    /// Only qualified per-segment references (schema 2) may be compared.
    public static func decode(_ data: Data) -> DiagnoseReference? {
        guard let reference = try? JSONDecoder().decode(DiagnoseReference.self, from: data), reference.schema == 2 else { return nil }
        return reference
    }
}

public struct Diagnosis: Equatable {
    public struct Host: Equatable {
        /// "Apple M4 Pro"
        public var chip: String?
        /// hw.model, e.g. "Mac16,7".
        public var hardware: String?
        public var memoryGB: Int?
        /// "15.5"
        public var macos: String?
        /// kern.osversion, e.g. "24F74" (part of the gate key).
        public var osBuild: String?
        /// Metal GPU family the optimized kernels are gated on ("apple9"); never a chip name.
        public var gpuFamily: String?
        public init(chip: String? = nil, hardware: String? = nil, memoryGB: Int? = nil, macos: String? = nil, osBuild: String? = nil, gpuFamily: String? = nil) {
            self.chip = chip; self.hardware = hardware; self.memoryGB = memoryGB; self.macos = macos; self.osBuild = osBuild; self.gpuFamily = gpuFamily
        }
    }
    /// One clip of the timed run: the model's text and, with a reference, how many words differ from it.
    public struct Clip: Equatable {
        public var name: String
        public var text: String
        /// Word-level edits against the reference transcript; nil without one.
        public var wordEdits: Int?
        public var reference: String?
        public init(name: String, text: String, wordEdits: Int? = nil, reference: String? = nil) {
            self.name = name; self.text = text; self.wordEdits = wordEdits; self.reference = reference
        }
    }
    public struct Run: Equatable {
        /// The warm-up pass's transcripts, compared with the reference.
        public var clips: [Clip]
        /// Wall seconds of each timed pass over every clip (one request at a time).
        public var passSeconds: [Double]
        public var audioSeconds: Double
        /// "M5 Max, optimized" when a reference exists for this model, precision and path.
        public var reference: String?
        public var referenceSpeedX: Double?
        public init(clips: [Clip], passSeconds: [Double], audioSeconds: Double, reference: String? = nil, referenceSpeedX: Double? = nil) {
            self.clips = clips; self.passSeconds = passSeconds; self.audioSeconds = audioSeconds
            self.reference = reference; self.referenceSpeedX = referenceSpeedX
        }
        public var speedX: Double? {
            let m = Diagnose.median(passSeconds)
            return m > 0 ? audioSeconds / m : nil
        }
        public var identical: Int { clips.filter { $0.wordEdits == 0 }.count }
    }
    public struct Model: Equatable {
        public var id: String
        public var name: String?
        public var mode: String?
        public var precision: String?
        public var engine: String?
        public var engineReason: String?
        public var optimizations: [String: Bool]
        public var residency: String?
        public var workerVersion: String?
        public var run: Run?
        /// Why the model was not timed, or the request's error.
        public var notTimed: String?
        /// The selection the worker was launched with (tier × Standard/Optimized × Exact/Fast); what runs is
        /// `effectiveSelection(selection, engine:)`.
        public var selection: ModelSelection?
        public init(
            id: String, name: String? = nil, mode: String? = nil, precision: String? = nil, engine: String? = nil,
            engineReason: String? = nil, optimizations: [String: Bool] = [:], residency: String? = nil,
            workerVersion: String? = nil, run: Run? = nil, notTimed: String? = nil
        ) {
            self.id = id; self.name = name; self.mode = mode; self.precision = precision; self.engine = engine
            self.engineReason = engineReason; self.optimizations = optimizations; self.residency = residency
            self.workerVersion = workerVersion; self.run = run; self.notTimed = notTimed
        }
    }
    /// One persisted optimized-path verdict (the worker data dir's FastPath/*.json).
    public struct GateVerdict: Equatable {
        /// "fast", "stock" or "inconclusive".
        public var status: String
        /// The model folder's name; nil for verdicts written before it was recorded.
        public var model: String?
        public var reason: String?
        public var workerVersion: String?
        public var gpuFamily: String?
        public var osBuild: String?
        public init(status: String, model: String? = nil, reason: String? = nil, workerVersion: String? = nil, gpuFamily: String? = nil, osBuild: String? = nil) {
            self.status = status; self.model = model; self.reason = reason; self.workerVersion = workerVersion
            self.gpuFamily = gpuFamily; self.osBuild = osBuild
        }
    }

    /// This `vella` command's version, "1.0.0 (34)"; nil outside an app bundle.
    public var cliVersion: String?
    public var appVersion: String?
    public var api: Int?
    public var host: Host
    /// False when Vella was not running: the report then holds this Mac's facts and the gate verdicts only.
    public var running: Bool
    /// "idle", "recording", "transcribing".
    public var dictation: String?
    public var dictationModel: String?
    public var models: [Model]
    public var gate: [GateVerdict]
    /// The gate version this app's workers write (from a loaded model, else the bundled reference).
    public var gateVersion: String?
    public var statusError: String?
    public var refused: String?
    /// Names of diagnostic environment switches that are set (values are left out: they can hold paths).
    public var switches: [String]
    /// Set when `--load` loaded the dictation model for this run.
    public var loadedForDiagnosis: String?
    /// False when the bundled reference file was missing or unreadable.
    public var referenceAvailable: Bool
    public init(
        cliVersion: String? = nil, appVersion: String? = nil, api: Int? = nil, host: Host, running: Bool, dictation: String? = nil,
        dictationModel: String? = nil, models: [Model] = [], gate: [GateVerdict] = [], gateVersion: String? = nil,
        statusError: String? = nil, refused: String? = nil, switches: [String] = [], loadedForDiagnosis: String? = nil,
        referenceAvailable: Bool = true
    ) {
        self.cliVersion = cliVersion; self.appVersion = appVersion; self.api = api; self.host = host; self.running = running
        self.dictation = dictation; self.dictationModel = dictationModel; self.models = models; self.gate = gate
        self.gateVersion = gateVersion; self.statusError = statusError; self.refused = refused; self.switches = switches
        self.loadedForDiagnosis = loadedForDiagnosis; self.referenceAvailable = referenceAvailable
    }
}

public enum Diagnose {
    public static let repository = "https://github.com/TobyNoSkillSon/Vella"
    /// GitHub answers 414 above roughly 8 KB of URL; stay well under it.
    public static let maxURLLength = 7000
    /// The worker's self-test clips (public LibriSpeech, CC BY 4.0), in run order, with their length in seconds.
    public static let clips: [(name: String, seconds: Double)] = [
        ("clip-a", 3.38), ("clip-b", 8.205), ("clip-c", 2.69), ("clip-d", 3.505), ("clip-e", 5.075)
    ]
    /// Timed passes after the warm-up pass.
    public static let timedPasses = 3

    // MARK: comparison

    /// Words of a transcript: split on whitespace, case and punctuation kept (formatting is part of the output).
    public static func words(_ text: String) -> [Substring] { text.split(whereSeparator: { $0.isWhitespace }) }

    /// Word-level Levenshtein distance.
    public static func wordEdits(_ a: String, _ b: String) -> Int { WordEdits.distance(words(a), words(b)) }

    /// Clips of a run compared with the reference run for the model's precision and path (unchanged without one).
    public static func compare(_ clips: [Diagnosis.Clip], with run: DiagnoseReference.Run?) -> [Diagnosis.Clip] {
        guard let run else { return clips }
        return clips.map { clip in
            var c = clip
            if let expected = run.transcripts[clip.name] { c.wordEdits = wordEdits(expected, clip.text); c.reference = expected }
            return c
        }
    }

    /// "M5 Max, optimized" / "M5 Max, stock MLX"
    public static func referenceLabel(_ reference: DiagnoseReference, engine: String?, selection: ModelSelection? = nil) -> String {
        let chip = displayChip(reference.chip) ?? displayChip(reference.hardware?.components(separatedBy: ",").first) ?? "reference Mac"
        let path = selection.map { recipeLabel(effectiveSelection($0, engine: engine)) } ?? (engine == "optimized" ? "optimized" : "stock MLX")
        return chip + ", " + path
    }

    public static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Every reason a loaded model is not fully on the optimized path; empty when none.
    public static func fallbacks(_ m: Diagnosis.Model) -> [String] {
        var out: [String] = []
        if let reason = m.engineReason.map(redact), !reason.isEmpty { out.append(reason) } else if m.engine == "mlx" { out.append("stock MLX (no reason reported)") }
        let stock = m.optimizations.filter { !$0.value }.keys.sorted()
        if m.engine == "optimized", !stock.isEmpty { out.append("stock: " + stock.joined(separator: ", ")) }
        return out
    }

    // MARK: privacy

    /// Removes anything that looks like a path under a home folder ("/Users/name/…" → "~/…").
    public static func redact(_ text: String) -> String {
        var out = text
        let home = NSHomeDirectory()
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        guard let regex = try? NSRegularExpression(pattern: #"/(?:Users|home)/[^/\s:;,"')]+"#) else { return out }
        return regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
    }

    /// A model folder name as the gate recorded it; nil when it does not look like one (never a path).
    public static func safeModelName(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= 120,
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
        else { return nil }
        return name
    }

    // MARK: text

    static func fixed(_ x: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", x) }
    /// 512 / 31 / 4.2
    static func speed(_ x: Double) -> String { x >= 10 ? fixed(x, 0) : fixed(x, 1) }

    /// The one-screen report.
    public static func text(_ d: Diagnosis) -> [String] {
        var versions = "vella \(d.cliVersion ?? "dev")"
        if d.running { versions += " · app \(d.appVersion ?? "?") · API \(d.api.map(String.init) ?? "?")" }
        if let g = d.gateVersion { versions += " · worker \(g)" }
        let h = d.host
        let mac = [
            displayChip(h.chip) ?? "unknown chip", h.hardware, h.memoryGB.map { "\($0) GB" },
            "macOS \(h.macos ?? "?")" + (h.osBuild.map { " (\($0))" } ?? ""), "GPU family \(h.gpuFamily ?? "?")"
        ]
        .compactMap { $0 }.joined(separator: " · ")
        var out = ["vella diagnose", versions, "Mac: " + mac]
        if !d.running {
            out.append("Vella is not running: start it from Applications and run `vella diagnose` again.")
        } else {
            if let loaded = d.loadedForDiagnosis { out.append("loaded \(loaded) for this diagnosis (--load)") }
            if let state = d.dictation, state != "idle" { out.append("dictation: \(state)") }
            for m in d.models { out += modelLines(m, chip: h.chip) }
            if d.models.isEmpty {
                out.append(
                    "no model loaded: nothing timed. `vella diagnose --load` loads the dictation model"
                        + (d.dictationModel.map { " (\($0))" } ?? "") + " and times it.")
            }
        }
        if !d.referenceAvailable { out.append("reference transcripts: missing for this build") }
        out.append(gateLine(d))
        if let e = d.statusError { out.append("last load error: \(redact(e))") }
        if let r = d.refused { out.append("last refusal: \(redact(r))") }
        if !d.switches.isEmpty { out.append("diagnostic switches set: " + d.switches.sorted().joined(separator: ", ")) }
        return out
    }

    static func modelLines(_ m: Diagnosis.Model, chip: String?) -> [String] {
        // No engine and no precision: the model is not loaded (a --load that failed), not running on MLX.
        let loaded = m.engine != nil || m.precision != nil
        var head = "\(m.id): " + (loaded ? engineLabel(engine: m.engine, chip: chip) : "not loaded")
        if let p = m.precision, !p.isEmpty { head += " · \(p)" }
        if let asked = m.selection {
            let running = effectiveSelection(asked, engine: m.engine)
            head += " · " + recipeLabel(running) + (running == asked ? "" : " (\(recipeLabel(asked)) asked)")
        }
        if m.mode == "streaming" { head += " · streaming" }
        if let r = m.residency, !r.isEmpty { head += " · " + r.replacingOccurrences(of: "_", with: " ") }
        var out = [head]
        let active = m.optimizations.filter(\.value).keys.sorted()
        if !m.optimizations.isEmpty { out.append("  optimized: " + (active.isEmpty ? "none" : active.joined(separator: ", "))) }
        let f = fallbacks(m)
        out.append("  fallbacks: " + (f.isEmpty ? "none" : f.joined(separator: "; ")))
        if let run = m.run {
            var line = "  clips: "
            if let reference = run.reference {
                line += "\(run.identical)/\(run.clips.count) identical to the reference (\(reference))"
                let differing = run.clips.compactMap { c -> String? in
                    guard let n = c.wordEdits, n > 0 else { return nil }
                    return "\(c.name) \(n) word\(n == 1 ? "" : "s") off"
                }
                if !differing.isEmpty { line += "; " + differing.joined(separator: ", ") }
            } else {
                line += "\(run.clips.count) transcribed, no reference for \(m.precision ?? "this precision") on this path"
            }
            let empty = run.clips.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            if empty > 0 { line += "; \(empty) empty" }
            if let s = run.speedX {
                line += " · \(fixed(run.audioSeconds, 1)) s of audio at \(speed(s))× real time"
                if let r = run.referenceSpeedX, let label = run.reference {
                    line += " (\(label.components(separatedBy: ",").first ?? label): \(speed(r))×)"
                }
            }
            out.append(line)
        }
        if let n = m.notTimed { out.append("  not timed: \(redact(n))") }
        return out
    }

    /// "gate verdicts: 2 optimized, 1 stock (parakeet-…-4bit: self-test: …)", current worker version only. Partial
    /// verdicts count as optimized and list their reason ("optimized without nax_gemm (…)").
    static func gateLine(_ d: Diagnosis) -> String {
        guard !d.gate.isEmpty else { return "gate verdicts: none yet (a model's first load runs its self-test)" }
        // Without a loaded model the current version is unknown: the newest recorded one stands in for it.
        let version = d.gateVersion ?? d.gate.compactMap(\.workerVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
        let current = d.gate.filter { version == nil || $0.workerVersion == nil || $0.workerVersion == version }
        let older = d.gate.count - current.count
        let counts = ["fast", "stock", "inconclusive"].compactMap { status -> String? in
            let n = current.filter { $0.status == status }.count
            return n == 0 ? nil : "\(n) \(status == "fast" ? "optimized" : status)"
        }
        var line = "gate verdicts: " + (counts.isEmpty ? "none for this worker version" : counts.joined(separator: ", "))
        // A "fast" verdict with a reason is partial: a tolerant component failed its own self-test and stays off.
        let notFast = current.filter { $0.status != "fast" || $0.reason != nil }.map { v -> String in
            let name = safeModelName(v.model) ?? "unnamed"
            return v.reason.map { "\(name): \(redact($0))" } ?? name
        }
        if !notFast.isEmpty { line += " (" + notFast.prefix(4).joined(separator: "; ") + (notFast.count > 4 ? "; …" : "") + ")" }
        if older > 0 { line += " · \(older) from an older worker version" }
        return line
    }

    /// A short issue title: chip, macOS, and what does not match or is not optimized.
    public static func title(_ d: Diagnosis) -> String {
        let place = "\(displayChip(d.host.chip) ?? "unknown chip"), macOS \(d.host.macos ?? "?")"
        guard d.running else { return "\(place): Vella not running" }
        if let m = d.models.first(where: { m in m.run.map { $0.reference != nil && $0.identical < $0.clips.count } ?? false }) {
            return String("\(place): \(m.id) \(m.precision ?? "") clips differ from the reference".prefix(120))
        }
        let stock = d.models.filter { $0.engine == "mlx" }
        if let first = stock.first {
            let reason = fallbacks(first).first.map { ": \($0)" } ?? ""
            return String("\(place): \(stock.map(\.id).joined(separator: ", ")) on MLX\(reason)".prefix(120))
        }
        return "\(place): diagnose report"
    }

    // MARK: JSON

    public static func json(_ d: Diagnosis, issueURL: String) -> [String: Any] {
        func v(_ x: Any?) -> Any { x ?? NSNull() }
        func r2(_ x: Double?) -> Any { x.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
        let h = d.host
        let host: [String: Any] = [
            "chip": v(h.chip), "hardware": v(h.hardware), "memory_gb": v(h.memoryGB), "macos": v(h.macos),
            "os_build": v(h.osBuild), "gpu_family": v(h.gpuFamily)
        ]
        let models: [[String: Any]] = d.models.map { m in
            var o: [String: Any] = [
                "id": m.id, "name": v(m.name), "mode": v(m.mode), "precision": v(m.precision), "engine": v(m.engine),
                "label": engineLabel(engine: m.engine, chip: h.chip), "optimizations": m.optimizations,
                "residency": v(m.residency), "worker_version": v(m.workerVersion), "fallbacks": fallbacks(m),
                "selection": v(m.selection.map { selectionObject(effectiveSelection($0, engine: m.engine)) }),
                "requested_selection": v(m.selection.map(selectionObject)),
                "not_timed": v(m.notTimed.map(redact))
            ]
            if let run = m.run {
                let clips: [[String: Any]] = run.clips.map { c in
                    ["clip": c.name, "text": c.text, "word_edits": v(c.wordEdits), "reference": v(c.reference)]
                }
                o["run"] =
                    [
                        "clips": clips, "identical": run.reference == nil ? NSNull() as Any : run.identical as Any,
                        "pass_s": run.passSeconds.map { ($0 * 10000).rounded() / 10000 }, "audio_s": r2(run.audioSeconds),
                        "speed_x": r2(run.speedX), "reference": v(run.reference), "reference_speed_x": r2(run.referenceSpeedX)
                    ] as [String: Any]
            } else {
                o["run"] = NSNull()
            }
            return o
        }
        let gate: [[String: Any]] = d.gate.map { g in
            [
                "status": g.status, "model": v(safeModelName(g.model)), "reason": v(g.reason.map(redact)), "worker_version": v(g.workerVersion),
                "gpu_family": v(g.gpuFamily), "os_build": v(g.osBuild)
            ]
        }
        return [
            "vella": v(d.cliVersion), "app": v(d.appVersion), "api": v(d.api), "worker_version": v(d.gateVersion), "running": d.running,
            "host": host, "dictation": v(d.dictation), "dictation_model": v(d.dictationModel), "loaded_for_diagnosis": v(d.loadedForDiagnosis),
            "models": models, "gate_verdicts": gate, "last_load_error": v(d.statusError.map(redact)), "last_refusal": v(d.refused.map(redact)),
            "diagnostic_switches": d.switches.sorted(), "reference_available": d.referenceAvailable, "issue_url": issueURL
        ]
    }

    public static func jsonText(_ d: Diagnosis, issueURL: String) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? JSONSerialization.data(withJSONObject: json(d, issueURL: issueURL), options: options)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func issueURL(_ d: Diagnosis) -> String {
        IssueURL.bugReport(
            repository: repository, title: title(d),
            fields: [
                ("chip", [displayChip(d.host.chip), d.host.hardware].compactMap { $0 }.joined(separator: ", ")),
                ("macos", [d.host.macos, d.host.osBuild.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")),
                ("version", d.appVersion ?? d.cliVersion ?? "")
            ], diagnose: text(d).joined(separator: "\n"), maxLength: maxURLLength)
    }
}

/// A new-issue URL for the bug-report form (.github/ISSUE_TEMPLATE/bug_report.yml), fields prefilled by their ids.
/// The `diagnose` field goes last and is cut at a line boundary (or, for one huge line, a character) to keep the
/// whole URL within `maxLength`; percent escapes are never split.
public enum IssueURL {
    public static let template = "bug_report.yml"
    public static let truncationNote = "\n[truncated: paste the full `vella diagnose` output]"
    /// RFC 3986 unreserved characters, ASCII only (CharacterSet.alphanumerics would pass non-ASCII letters).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    public static func bugReport(repository: String, title: String, fields: [(String, String)], diagnose: String, maxLength: Int) -> String {
        var url = "\(repository)/issues/new?template=\(template)&title=\(encode(title))"
        for (id, value) in fields where !value.isEmpty { url += "&\(id)=\(encode(value))" }
        let prefix = "&diagnose="
        let budget = maxLength - url.count - prefix.count
        let full = encode(diagnose)
        if full.count <= budget { return url + prefix + full }
        let note = encode(truncationNote)
        var kept = "", used = 0
        let lines = diagnose.components(separatedBy: "\n")
        for (n, line) in lines.enumerated() {
            let piece = encode((n == 0 ? "" : "\n") + line)
            if used + piece.count + note.count > budget {
                if n == 0 { // one line longer than the whole budget: keep what fits, character by character
                    for ch in line {
                        let e = encode(String(ch))
                        if used + e.count + note.count > budget { break }
                        kept += e; used += e.count
                    }
                }
                break
            }
            kept += piece; used += piece.count
        }
        return url + prefix + kept + note
    }
}
