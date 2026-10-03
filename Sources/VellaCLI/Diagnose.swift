import Darwin
import Foundation
import Metal
import VellaCore

/// Collects `vella diagnose` from the running app. It never launches Vella and loads nothing unless asked (`--load`
/// loads the dictation model). Timing uses only the five public self-test clips in the app bundle, sent through the
/// app's own API one request at a time, so dictation still goes first.
struct DiagnoseCollector {
    var client: VellaClient
    /// Per-request limit for one clip (a stuck worker must not hang the report).
    var clipTimeout: TimeInterval = 300

    var environment: [String: String] { client.environment }

    func collect(load: Bool) async -> Diagnosis {
        var d = Diagnosis(cliVersion: Self.version(of: VellaClient.containingApp), host: Self.localHost(), running: false)
        d.gate = Self.gateVerdicts(in: gateStorage)
        guard let file = client.runningStatus(), let port = file.api_port else {
            let bundled = reference(appBundle: nil)
            d.referenceAvailable = bundled != nil
            d.referenceProvisional = bundled?.provisional == true
            d.gateVersion = bundled?.gate_version
            return d
        }
        d.running = true
        let app = file.app_pid.flatMap(Self.appBundle(pid:))
        let bundled = reference(appBundle: app)
        d.referenceAvailable = bundled != nil
        d.referenceProvisional = bundled?.provisional == true
        d.appVersion = Self.version(of: app)
        let before: [String: Any]
        do { before = try await statusObject(port) } catch {
            d.statusError = (error as? CLIError)?.message ?? error.localizedDescription
            return d
        }
        d.api = (before["api"] as? NSNumber)?.intValue
        if d.appVersion == nil { d.appVersion = before["version"] as? String }
        d.dictation = before["dictation"] as? String
        let current = before["dictation_model"] as? [String: Any]
        d.dictationModel = current?["id"] as? String
        let status = Self.workerStatus(before)

        var timed = status.models.filter { $0.value.mode != .streaming }.keys.sorted()
        if load, let id = d.dictationModel, status.models[id] == nil {
            timed.append(id); d.loadedForDiagnosis = id
        }
        var runs: [String: Result<[Diagnosis.Clip], CLIError>] = [:]
        var passes: [String: [Double]] = [:]
        var skip: String?
        let clips = clipFiles(appBundle: app)
        if d.dictation.map({ $0 != "idle" }) ?? false {
            skip = "a dictation was in progress; run `vella diagnose` again when it is done"
        } else if clips == nil {
            skip = "the self-test clips are missing from this installation"
        }
        if skip == nil, let clips {
            for id in timed {
                do {
                    let (texts, seconds) = try await time(id, clips: clips, port: port)
                    runs[id] = .success(texts); passes[id] = seconds
                } catch {
                    runs[id] = .failure((error as? CLIError) ?? CLIError(error.localizedDescription))
                }
            }
        }
        // Read again: a runtime fallback to stock during the timed run shows up here, and --load's model is now loaded.
        let afterObject = (try? await statusObject(port)) ?? before
        let after = Self.workerStatus(afterObject)
        d.statusError = after.error.flatMap { $0.isEmpty ? nil : $0 }
        d.refused = after.refused?.message
        if let chip = after.gpu?.chip, !chip.isEmpty { d.host.chip = chip }
        if let family = after.gpu?.family, !family.isEmpty { d.host.gpuFamily = family }
        d.switches = Array((after.test_hooks ?? [:]).keys).sorted()
        // A --load that failed loaded nothing: its reason is the model's "not timed" line.
        if let id = d.loadedForDiagnosis, after.models[id] == nil { d.loadedForDiagnosis = nil }
        let audio = Diagnose.clips.map { $0.seconds }.reduce(0, +)
        let ids = Set(after.models.keys).union(timed).sorted()
        d.models = ids.map { id -> Diagnosis.Model in
            let m = after.models[id] ?? status.models[id]
            var report = Diagnosis.Model(
                id: id, name: m?.name, mode: m?.mode?.rawValue, precision: m?.precision, engine: m?.engine,
                engineReason: m?.engine_reason, optimizations: m?.optimizations ?? [:], residency: m?.residency,
                workerVersion: m?.worker_version)
            report.selection = m?.selection
            if m?.mode == .streaming {
                report.notTimed = "streaming models are not served by the API"
            } else if let skip {
                report.notTimed = skip
            } else if let result = runs[id] {
                switch result {
                case .success(let clips):
                    let ref = bundled?.run(model: id, precision: m?.precision, engine: m?.engine, selection: m?.selection)
                    report.run = Diagnosis.Run(
                        clips: Diagnose.compare(clips, with: ref), passSeconds: passes[id] ?? [], audioSeconds: audio,
                        reference: ref.flatMap { _ in bundled.map { Diagnose.referenceLabel($0, engine: m?.engine, selection: m?.selection) } },
                        referenceSpeedX: bundled?.method == "api" ? ref?.speed_x : nil)
                case .failure(let error): report.notTimed = error.message
                }
            } else {
                report.notTimed = "loaded while the diagnosis ran"
            }
            return report
        }
        d.gateVersion = d.models.compactMap(\.workerVersion).first ?? bundled?.gate_version
        return d
    }

    // MARK: API

    func statusObject(_ port: Int) async throws -> [String: Any] {
        let data = try await client.request("GET", "/status", port: port, timeout: 30)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CLIError("Vella answered /status with something other than JSON") }
        return object
    }
    static func workerStatus(_ object: [String: Any]) -> WorkerStatus {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(WorkerStatus.self, from: $0) } ?? WorkerStatus()
    }

    /// One warm-up pass (its transcripts are the ones compared), then `Diagnose.timedPasses` timed passes over the clips.
    func time(_ id: String, clips: [(name: String, url: URL)], port: Int) async throws -> ([Diagnosis.Clip], [Double]) {
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        var texts: [Diagnosis.Clip] = [], passes: [Double] = []
        for pass in 0...Diagnose.timedPasses {
            var total = 0.0
            for clip in clips {
                let start = clock.now
                let data = try await client.request(
                    "POST", "/v1/audio/transcriptions",
                    json: ["path": clip.url.path, "model": id, "response_format": "json"],
                    port: port, timeout: clipTimeout)
                total += seconds(clock.now - start)
                if pass == 0 {
                    let text = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["text"] as? String ?? ""
                    texts.append(Diagnosis.Clip(name: clip.name, text: text))
                }
            }
            if pass > 0 { passes.append(total) }
        }
        return (texts, passes)
    }

    // MARK: Files

    /// The worker's persisted verdicts: VELLA_WORKER_DATA_DIR/FastPath, else <support>/Worker/FastPath.
    var gateStorage: URL {
        if let dir = environment["VELLA_WORKER_DATA_DIR"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir).appendingPathComponent("FastPath") }
        return client.supportDirectory.appendingPathComponent("Worker/FastPath")
    }
    static func gateVerdicts(in dir: URL) -> [Diagnosis.GateVerdict] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let status = o["status"] as? String
            else { return nil }
            return Diagnosis.GateVerdict(
                status: status, model: o["model"] as? String, reason: o["reason"] as? String,
                workerVersion: o["workerVersion"] as? String, gpuFamily: o["gpuFamily"] as? String, osBuild: o["osBuild"] as? String)
        }
    }

    /// Resources of the running app, then of the app this command ships in, then of the source checkout.
    func resourceDirectories(appBundle: URL?) -> [URL] {
        var out = [appBundle, VellaClient.containingApp].compactMap { $0?.appendingPathComponent("Contents/Resources") }
        out.append(Self.sourceRoot.appendingPathComponent("Resources"))
        return out
    }
    func reference(appBundle: URL?) -> DiagnoseReference? {
        for dir in resourceDirectories(appBundle: appBundle) {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("diagnose-reference.json")) { return DiagnoseReference.decode(data) }
        }
        return nil
    }
    /// The five clips from the first place that has all of them.
    func clipFiles(appBundle: URL?) -> [(name: String, url: URL)]? {
        var dirs: [URL] = []
        for resources in [appBundle, VellaClient.containingApp].compactMap({ $0?.appendingPathComponent("Contents/Resources") }) {
            let bundle = resources.appendingPathComponent("VellaWorker_VellaWorker.bundle")
            dirs += [bundle, bundle.appendingPathComponent("Contents/Resources")]
        }
        dirs.append(Self.sourceRoot.appendingPathComponent("Worker/Sources/VellaWorker/Resources"))
        for dir in dirs {
            let files = Diagnose.clips.map { (name: $0.name, url: dir.appendingPathComponent("\($0.name).wav")) }
            if files.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) { return files }
        }
        return nil
    }
    /// Sources/VellaCLI/Diagnose.swift → the checkout root (a development build).
    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static let bundleIdentifier = "dev.vella.dictation"
    /// The Vella.app that contains the process `pid` (the running app); nil for anything else.
    static func appBundle(pid: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: buffer))
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension == "app" {
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                return info?["CFBundleIdentifier"] as? String == bundleIdentifier ? url : nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
    /// "2.0.0 (35)" from an app's Info.plist.
    static func version(of app: URL?) -> String? {
        guard let app, let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let short = info["CFBundleShortVersionString"] as? String
        else { return nil }
        return (info["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    // MARK: This Mac

    static func sysctlString(_ name: String) -> String? { HostInfo.sysctlString(name).flatMap { $0.isEmpty ? nil : $0 } }
    /// Chip, model, memory, macOS and its build, and the Metal family the optimized kernels are gated on.
    static func localHost() -> Diagnosis.Host {
        var memory: UInt64 = 0, size = MemoryLayout<UInt64>.size
        let gb = sysctlbyname("hw.memsize", &memory, &size, nil, 0) == 0 ? Int((Double(memory) / 1_073_741_824).rounded()) : nil
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macos = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        let device = MTLCreateSystemDefaultDevice()
        let family = device?.supportsFamily(.apple9) == true ? "apple9" : device?.supportsFamily(.apple8) == true ? "apple8" : "unsupported"
        return Diagnosis.Host(
            chip: sysctlString("machdep.cpu.brand_string"), hardware: sysctlString("hw.model"), memoryGB: gb,
            macos: macos, osBuild: sysctlString("kern.osversion"), gpuFamily: family, gpuCores: HostInfo.gpuCoreCount)
    }
}
