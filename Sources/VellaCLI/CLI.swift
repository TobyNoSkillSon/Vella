import Foundation
import VellaCore

let usage = """
vella: transcribe audio files offline with the models loaded in Vella on this Mac.

    vella transcribe FILE [--model ID] [--language CODE] [--json | --verbose-json | --srt | --vtt]
        prints the transcript; --json/--verbose-json print OpenAI's JSON response, --srt/--vtt subtitles.
        FILE: anything macOS decodes (wav, mp3, m4a, flac, caf, aiff), up to 3 hours. --model takes an id from
        `vella models`; without it the current dictation model is used. Dictation always goes first.
    vella status                 one line: running, dictation model, loaded models, API address
    vella models [--json]        one line per model usable now: id, name, precision, loaded / current
    vella url                    the OpenAI-compatible base URL (base_url for the openai SDKs)
    vella skill [--install DIR]  print the agent skill, or write DIR/transcribe/SKILL.md

Talks to the Vella app over its local HTTP API (OpenAI-compatible /v1/audio/transcriptions, /v1/models, plus
/status); starts the app if it is not running. Transcripts are printed, never pasted or saved.
"""

struct CLIError: Error { let message: String; init(_ message: String) { self.message = message } }

/// The `vella` command. `write`/`warn` are stdout/stderr.
struct VellaCLI {
    var environment = ProcessInfo.processInfo.environment
    var write: (String) -> Void = { print($0) }
    var warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func run(_ argv: [String]) async -> Int32 {
        guard let command = argv.first, !["-h", "--help", "help"].contains(command) else { write(usage); return 0 }
        do {
            try await dispatch(command, Array(argv.dropFirst()))
            return 0
        } catch let error as CLIError {
            warn("error: \(error.message)"); return 1
        } catch {
            warn("error: \(error.localizedDescription)"); return 1
        }
    }

    struct Arguments {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        init(_ args: [String], values valueOptions: Set<String>, flags flagOptions: Set<String>) throws {
            var i = 0
            while i < args.count {
                let a = args[i]
                if valueOptions.contains(a) {
                    guard i + 1 < args.count else { throw CLIError("\(a) needs a value") }
                    values[a] = args[i + 1]; i += 2
                } else if flagOptions.contains(a) {
                    flags.insert(a); i += 1
                } else if a.hasPrefix("--") {
                    throw CLIError("unknown option \(a); see vella --help")
                } else { positional.append(a); i += 1 }
            }
        }
    }

    func dispatch(_ command: String, _ rest: [String]) async throws {
        switch command {
        case "transcribe": try await transcribe(rest)
        case "status":
            _ = try Arguments(rest, values: [], flags: [])
            let (status, port) = try await client().status()
            write(Self.statusLine(status, port: port))
        case "models":
            let args = try Arguments(rest, values: [], flags: ["--json"])
            let data = try await client().request("GET", "/v1/models")
            if args.flags.contains("--json") { write(String(decoding: data, as: UTF8.self)); return }
            let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
            if models.isEmpty { write("no dictation model downloaded; get one in Vella → Models…"); return }
            models.map(Self.modelLine).forEach(write)
        case "url":
            _ = try Arguments(rest, values: [], flags: [])
            write("http://127.0.0.1:\(try await client().ensureRunning())/v1")
        case "skill":
            let args = try Arguments(rest, values: ["--install"], flags: [])
            guard let text = skillText() else { throw CLIError("SKILL.md not found; is Vella installed?") }
            if let dir = args.values["--install"] {
                let dest = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("transcribe/SKILL.md")
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: dest)
                write("wrote \(dest.path)")
            } else { write(text) }
        default: throw CLIError("unknown command \(command); see vella --help")
        }
    }

    func transcribe(_ rest: [String]) async throws {
        let args = try Arguments(rest, values: ["--model", "--language"], flags: ["--json", "--verbose-json", "--srt", "--vtt", "--text"])
        guard args.positional.count == 1 else { throw CLIError("vella transcribe FILE [--model ID] [--language CODE] [--json | --srt | --vtt]") }
        let formats: [(String, String)] = [("--json", "json"), ("--verbose-json", "verbose_json"), ("--srt", "srt"), ("--vtt", "vtt"), ("--text", "text")]
        let chosen = formats.filter { args.flags.contains($0.0) }
        guard chosen.count <= 1 else { throw CLIError("choose one of --json, --verbose-json, --srt, --vtt") }
        let url = URL(fileURLWithPath: (args.positional[0] as NSString).expandingTildeInPath,
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError("no such file: \(args.positional[0])")
        }
        var body: [String: Any] = ["path": url.path, "response_format": chosen.first?.1 ?? "text"]
        if let model = args.values["--model"] { body["model"] = model }
        if let language = args.values["--language"] { body["language"] = language }
        let data = try await client().request("POST", "/v1/audio/transcriptions", json: body)
        let text = String(decoding: data, as: UTF8.self)
        write(chosen.isEmpty || chosen.first?.1 == "text" ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text.trimmingCharacters(in: .newlines))
    }

    func client() -> VellaClient { VellaClient(environment: environment) }

    // MARK: Formatting

    /// "Vella 1.0.0 running (pid 812), no model loaded · dictation model Parakeet v3 (8b) · API http://127.0.0.1:52314/v1"
    static func statusLine(_ s: [String: Any], port: Int) -> String {
        let version = (s["version"] as? String).map { " \($0)" } ?? ""
        let pid = (s["pid"] as? NSNumber)?.intValue ?? 0
        let loaded = (s["models"] as? [String: Any]) ?? [:]
        var parts = ["Vella\(version) running (pid \(pid)), " + (loaded.isEmpty ? "no model loaded" : loaded.keys.sorted().map { id in
            let precision = ((loaded[id] as? [String: Any])?["precision"] as? String).map { " \($0)" } ?? ""
            return id + precision
        }.joined(separator: ", ") + " loaded")]
        if let loading = s["loading"] as? String { parts.append("loading \(loading)") }
        if let current = s["dictation_model"] as? [String: Any], let name = current["name"] as? String {
            let precision = (current["precision"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            parts.append("dictation model \(name)\(precision)")
        }
        if let state = s["dictation"] as? String, state != "idle" { parts.append(state) }
        if let jobs = s["api_jobs"] as? [String: Any], let running = (jobs["running"] as? NSNumber)?.intValue, running > 0 {
            parts.append("\(running + ((jobs["waiting"] as? NSNumber)?.intValue ?? 0)) file(s) transcribing")
        }
        if let error = s["error"] as? String, !error.isEmpty { parts.append("error: \(error.prefix(80))") }
        parts.append("API http://127.0.0.1:\(port)/v1")
        return parts.joined(separator: " · ")
    }
    /// "parakeet-v3  Parakeet v3 · 8b · loaded · current"
    static func modelLine(_ m: [String: Any]) -> String {
        var parts = [m["name"] as? String ?? ""]
        if let p = m["precision"] as? String, !p.isEmpty { parts.append(p) }
        if m["loaded"] as? Bool == true { parts.append("loaded") }
        if m["current"] as? Bool == true { parts.append("current dictation model") }
        return "\(m["id"] as? String ?? "?")  " + parts.joined(separator: " · ")
    }

    // MARK: Skill

    func skillText() -> String? {
        var candidates = client().appCandidates.map { $0.appendingPathComponent("Contents/Resources/SKILL.md") }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/SKILL.md"))   // Sources/VellaCLI/CLI.swift -> root
        for url in candidates { if let text = try? String(contentsOf: url, encoding: .utf8) { return text } }
        return nil
    }
}

/// Finds the running app's API (worker-status.json in Vella's support directory), launching the app if needed.
struct VellaClient {
    var environment: [String: String]

    var supportDirectory: URL {
        if let dir = environment["VELLA_SUPPORT_DIR"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella", isDirectory: true)
    }
    /// With an isolated VELLA_SUPPORT_DIR only VELLA_APP is launched: a test or QA run never starts the user's app.
    var appCandidates: [URL] {
        var out: [URL] = []
        if let path = environment["VELLA_APP"], !path.isEmpty { out.append(URL(fileURLWithPath: path)) }
        if environment["VELLA_SUPPORT_DIR"] != nil { return out }
        if let bundle = Self.containingApp { out.append(bundle) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let recorded = try? String(contentsOf: home.appendingPathComponent(".local/share/vella/app-path"), encoding: .utf8) {
            let path = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { out.append(URL(fileURLWithPath: path)) }
        }
        out.append(home.appendingPathComponent("Applications/Vella.app"))
        out.append(URL(fileURLWithPath: "/Applications/Vella.app"))
        return out
    }
    /// Vella.app when this executable ships inside it (Contents/Helpers/vella).
    static var containingApp: URL? {
        var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "/").resolvingSymlinksInPath()
        if !url.path.hasPrefix("/") { return nil }
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension == "app" { return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) ? url : nil }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The running app's status file (nil when its app is gone).
    func runningStatus() -> WorkerStatus? {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("worker-status.json")),
              let status = try? JSONDecoder().decode(WorkerStatus.self, from: data),
              let port = status.api_port, port > 0, let pid = status.app_pid, pid > 0, kill(pid, 0) == 0 else { return nil }
        return status
    }
    /// The API port when the app that wrote the status file is alive.
    func runningPort() -> Int? { runningStatus()?.api_port }

    func ensureRunning() async throws -> Int {
        if let port = runningPort() { return port }
        guard environment["VELLA_NO_LAUNCH"] != "1" else { throw CLIError("Vella is not running") }
        guard let app = appCandidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }) else {
            throw CLIError("Vella is not running and is not installed (looked for \(appCandidates.first?.path ?? "~/Applications/Vella.app"))")
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-g"]
        if let dir = environment["VELLA_SUPPORT_DIR"] { arguments += ["--env", "VELLA_SUPPORT_DIR=\(dir)"] }
        open.arguments = arguments + [app.path]
        open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
        try? open.run(); open.waitUntilExit()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let port = runningPort() { return port }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CLIError("Vella did not start in time")
    }

    /// `GET /status`, refusing an API version this command does not know.
    func status() async throws -> ([String: Any], Int) {
        let port = try await ensureRunning()
        let data = try await request("GET", "/status", port: port)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CLIError("Vella answered /status with something other than JSON") }
        return (object, port)
    }

    func request(_ method: String, _ path: String, json: [String: Any]? = nil, port known: Int? = nil) async throws -> Data {
        let port: Int
        if let known { port = known } else { port = try await ensureRunning() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 4 * 3600   // a 3-hour file on a slow model
        if let json {
            // A local path is only read for a client that can read Vella's status file (not a sandboxed app).
            if let token = runningStatus()?.api_token { request.setValue(token, forHTTPHeaderField: "X-Vella-Token") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 4 * 3600
        config.timeoutIntervalForResource = 4 * 3600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw CLIError("Vella's API did not answer (\(error.localizedDescription))") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw CLIError(message ?? "HTTP \(code)")
        }
        if path == "/status", let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let api = (object["api"] as? NSNumber)?.intValue, api > vellaAPIVersion {
            throw CLIError("this vella command knows API \(vellaAPIVersion) but the app speaks API \(api); reinstall Vella")
        }
        return data
    }
}
