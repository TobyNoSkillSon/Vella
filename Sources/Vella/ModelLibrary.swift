import AppKit
import Foundation
import Darwin
import CryptoKit
import VellaCore

@MainActor final class ModelLibrary: ObservableObject {
    let mode: RecognitionMode
    var catalogName: String { mode == .dictation ? "models.json" : "streaming-models.json" }
    func supports(_ architecture: String) -> Bool {
        mode == .streaming ? ["nemotron_asr", "voxtral_realtime"].contains(architecture) : ["whisper", "qwen3_asr", "parakeet", "sensevoice", "granite_speech"].contains(architecture)
    }
    @Published var models: [ModelRecommendation] = []
    @Published var installed: [String: InstalledModel] = [:]
    @Published var references: [String: BenchmarkResult] = [:]
    @Published var selectedID = "Qwen3-ASR-1.7B-bf16"
    @Published var message = "Choose a model. Compare it on the same audio."
    @Published var busy = false
    @Published var progress: Double? = nil
    @Published var downloadingID: String?
    @Published var downloadError: String?
    @Published var activeModelPath = ""
    let calibration: CalibrationStore
    private let automaticallyCalibrates: Bool
    @Published var calibratingID: String?
    var workerPython: () throws -> URL = {
        URL(fileURLWithPath: try Backend().configuration(requiresModel: false).executable)
    }
    private var worker: Process?
    private var deadline: DispatchWorkItem?
    private var buffer = Data()
    private var receivedResult = false
    private var pendingInstallation: (String, InstalledModel)?
    private var failureMessage: String?
    var mayChangeModel: () -> Bool = { true }
    var onUse: (() -> Void)?
    var beforeHeavyWork: (() -> Void)?
    var prepareForCalibration: (() async throws -> Void)?
    private var calibrationLaunch: Task<Void, Never>?
    let resources: URL
    let registryURL: URL
    // Injectable filesystem operations keep deletion tests away from real models/Trash.
    var currentModelPath: () throws -> String = { try Backend().configuration(requiresModel: false).model }
    var protectedModelPaths: () throws -> [String] = {
        let config = try Backend().configuration(requiresModel: false)
        return [config.model, config.streamingModel]
    }
    var trashModel: (URL) throws -> URL = { source in
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination else { throw VellaError.message("Trash did not return the model's recovery location.") }
        return destination as URL
    }
    var writeRegistryData: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    static var registry: URL { Backend.support.appendingPathComponent("models-installed.json") }
    var modelsDirectory: URL { registryURL.deletingLastPathComponent().appendingPathComponent("Models") }
    func modelFilePath(_ id: String) -> String? {
        if let local = installed[id] { return local.path }
        guard models.contains(where: { $0.id == id }), !id.isEmpty, id != ".", id != "..", !id.contains("/") else { return nil }
        let folder = modelsDirectory.appendingPathComponent(id)
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else { return nil }
        return folder.path // An unfinished download is manageable, but NOT installed.
    }
    init(mode: RecognitionMode = .dictation, resources: URL? = nil, registryURL: URL? = nil, calibration: CalibrationStore? = nil) {
        self.mode = mode
        if registryURL != nil { protectedModelPaths = { [] } }
        // Custom registries are an isolation boundary; callers inject their calibration runner.
        automaticallyCalibrates = mode == .dictation && (registryURL == nil || calibration != nil)
        self.calibration = calibration ?? (resources == nil ? .shared : CalibrationStore(resources: resources))
        self.registryURL = registryURL ?? Self.registry
        self.resources = resources ?? Self.resourceDirectory()
        reload()
    }
    static func resourceDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("models.json").path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    }
    /// Menu-header label for the selected model, e.g. "Parakeet v3 4b"; nil when none is selected.
    var activeModelLabel: String? {
        guard !activeModelPath.isEmpty, let model = models.first(where: { installed[$0.id]?.path == activeModelPath }) else { return nil }
        return "\(model.name.replacingOccurrences(of: " ASR \u{B7}", with: "")) \(model.quantization.replacingOccurrences(of: "-bit", with: "b"))"
    }
    var displayedModels: [ModelRecommendation] {
        var rows = models.filter { $0.recommended == true || modelFilePath($0.id) != nil }
        if rows.isEmpty { return models } // Legacy catalogs without recommendation metadata.
        // Keep a custom active model visible without switching or deleting it.
        if !rows.contains(where: { installed[$0.id]?.path == activeModelPath }),
           let active = models.first(where: { installed[$0.id]?.path == activeModelPath }) {
            rows.append(active)
        }
        return rows
    }
    var selected: ModelRecommendation? { models.first { $0.id == selectedID } }
    static let processor: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown processor" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "Unknown processor" }
        return String(cString: bytes)
    }()
    func referenceDescription(_ result: BenchmarkResult) -> String {
        let matches = result.machine.caseInsensitiveCompare(Self.processor) == .orderedSame
        let path = result.recognitionMode == .streaming ? "Native streaming input; speed is accelerated replay throughput, not microphone-to-text latency. " : "Batch inference. "
        return path + "Measured on \(result.machine)\(matches ? " (matches your processor)" : " (reference; your processor is \(Self.processor))"). \(Int(result.audioSeconds)) seconds of audio, \(result.repeats) passes. Not measured on every user's individual Mac"
    }
    func formattingDescription(_ result: BenchmarkResult) -> String {
        guard let f = result.formatting else { return "Formatting not measured" }
        func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "Not measured" }
        return "Text = case- and punctuation-sensitive character errors. Punctuation F1: \(percent(f.punctuationF1)); casing agreement: \(percent(f.capitalizationAccuracy)), on correctly aligned words. Coverage: words \(percent(f.matchedWordCoverage)), boundaries \(percent(f.boundaryCoverage)), reference punctuation \(percent(f.punctuationCoverage)). Quote F1: \(percent(f.quotationF1)); only \(f.quotedReferenceClips) quote-bearing clips, exploratory. Clean book reading; editorial choices can differ. \(referenceDescription(result))"
    }
    func reload() {
        let decoder = JSONDecoder()
        do {
            models = try decoder.decode([ModelRecommendation].self, from: Data(contentsOf: resources.appendingPathComponent(catalogName))).filter { supports($0.architecture) }
            if let data = try? Data(contentsOf: registryURL), let saved = try? decoder.decode([String: InstalledModel].self, from: data) { installed = saved }
            for (id, local) in installed where !models.contains(where: { $0.id == id }) {
                if let bytes = try? Data(contentsOf: URL(fileURLWithPath: local.path).appendingPathComponent("config.json")),
                   let cfg = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   let architecture = (cfg["model_type"] as? String) ?? ((cfg["target"] as? String == "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel") ? "parakeet" : nil), supports(architecture) {
                    let bits = (cfg["quantization"] as? [String: Any])?["bits"] as? Int
                    models.append(ModelRecommendation(id: id, name: local.name ?? "Imported model", quantization: bits.map { "\($0)-bit" } ?? "Unquantized", repository: "", revision: "", downloadBytes: 0, architecture: architecture, license: "See imported model’s license", recommendation: "Local import · not a pinned Hub recommendation"))
                }
            }
            // Treat configuration-selected models as imported until the user maps/downloads a recommendation.
            if registryURL == Self.registry, let config = try? Backend().configuration(requiresModel: false) {
                activeModelPath = mode == .dictation ? config.model : config.streamingModel
            }
            if !models.contains(where: { $0.id == selectedID }) { selectedID = models.first?.id ?? "" }
            references = [:]
            let streamHash = (try? Data(contentsOf: resources.appendingPathComponent("streaming_worker.py"))).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            let policyData = try Data(contentsOf: resources.appendingPathComponent("benchmark-policy.json"))
            let policy = try JSONDecoder().decode(BenchmarkPolicy.self, from: policyData)
            var candidates: [String: [BenchmarkResult]] = [:]
            for folder in [resources.appendingPathComponent("ReferenceResults"), Backend.support.appendingPathComponent("ReferenceResults")] {
                for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
                    if let data = try? Data(contentsOf: url), let result = try? decoder.decode(BenchmarkResult.self, from: data), result.suiteID == policy.suiteID, result.suiteHash == policy.suiteHash, result.repeats >= policy.minimumRepeats, policy.scorerSHA256 == nil || result.formatting?.scorerSHA256 == policy.scorerSHA256, policy.lexicalNormalizerSHA256 == nil || result.formatting?.lexicalNormalizerSHA256 == policy.lexicalNormalizerSHA256 {
                        guard (result.recognitionMode ?? .dictation) == mode else { continue }
                        if mode == .streaming {
                            guard result.streamingQualified == true, result.complete == true,
                                  result.measurementKind == "timing", let streamHash,
                                  result.streamingWorkerSHA256 == streamHash else { continue }
                        }
                        candidates[result.modelID, default: []].append(result)
                    }
                }
            }
            references = candidates.compactMapValues { preferredBenchmark($0, processor: Self.processor) }
        } catch { message = error.localizedDescription }
    }
    // Merge only explicitly changed IDs into the latest shared registry. The other
    // mode may have installed/deleted entries since this library last reloaded.
    func saveRegistry(updating id: String) throws {
        var latest: [String: InstalledModel] = [:]
        if FileManager.default.fileExists(atPath: registryURL.path) {
            latest = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: registryURL))
        }
        latest[id] = installed[id]
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeRegistryData(encoder.encode(latest), registryURL)
        installed = latest
    }
    func deletionBlockReason(_ id: String) -> String? {
        if busy || calibration.isRunning || !mayChangeModel() { return "Finish dictation, downloading or calibration before deleting a model." }
        guard let path = modelFilePath(id) else { return "This model has no local files." }
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        guard let active = try? currentModelPath() else { return "Cannot verify the active model. Check configuration before deleting." }
        guard let protected = try? protectedModelPaths() else { return "Cannot verify saved model selections. Check configuration before deleting." }
        if protected.contains(where: { !$0.isEmpty && folder.resolvingSymlinksInPath() == URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) {
            return "Switch to another model in that mode before deleting its saved selection."
        }
        if (!active.isEmpty && folder.resolvingSymlinksInPath() == URL(fileURLWithPath: active).resolvingSymlinksInPath()) || path == activeModelPath {
            return "Switch to another model before deleting the one in use."
        }
        let root = registryURL.deletingLastPathComponent().appendingPathComponent("Models").standardizedFileURL
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"),
              folder == root.appendingPathComponent(id).standardizedFileURL,
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return "External, shared or linked model files are protected. Only Vella's own model folders can be deleted here."
        }
        if installed.contains(where: { $0.key != id && URL(fileURLWithPath: $0.value.path).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() }) {
            return "Another model entry shares these files; deletion is blocked."
        }
        return nil
    }
    /// Only called after confirmation. Re-read disk/configuration rather than trusting an old row.
    @discardableResult func deleteModel(_ id: String, expectedPath: String, expectedInstalled: Bool? = nil) -> Bool {
        do {
            let wasInstalled = expectedInstalled ?? (installed[id] != nil)
            if FileManager.default.fileExists(atPath: registryURL.path) {
                installed = try JSONDecoder().decode([String: InstalledModel].self, from: Data(contentsOf: registryURL))
            } else {
                guard !wasInstalled else { throw VellaError.message("The model registry changed. Reopen Models and try again.") }
                installed = [:]
            }
            guard (installed[id] != nil) == wasInstalled, modelFilePath(id) == expectedPath else { throw VellaError.message("The model changed since confirmation. Reopen Models and try again.") }
            if let reason = deletionBlockReason(id) { throw VellaError.message(reason) }
            let old = installed
            let source = URL(fileURLWithPath: expectedPath)
            let trashed = FileManager.default.fileExists(atPath: source.path) ? try trashModel(source) : nil
            installed.removeValue(forKey: id)
            do { if wasInstalled { try saveRegistry(updating: id) } }
            catch {
                installed = old
                if let trashed {
                    do { try FileManager.default.moveItem(at: trashed, to: source) }
                    catch { throw VellaError.message("Registry update failed. Model files remain recoverable at \(trashed.path). Restore them before using this model.") }
                }
                throw error
            }
            downloadError = nil
            message = (wasInstalled ? "Model removed." : "Partial download removed.") + " Empty Trash to reclaim disk space. You can download it again later."
            reload()
            return true
        } catch { downloadError = error.localizedDescription; message = error.localizedDescription; return false }
    }
    func download() {
        guard let selected, !busy, !calibration.isRunning, calibratingID == nil else { return }
        guard mayChangeModel() else { message = "Finish or stop dictation before installing a model."; return }
        beforeHeavyWork?()
        downloadingID = selected.id; downloadError = nil
        run(["download", "--catalog", resources.appendingPathComponent(catalogName).path,
             "--model-id", selected.id, "--models-dir", modelsDirectory.path], timeout: 3600)
    }
    func importModel() {
        guard let selected, !busy, !calibration.isRunning, mayChangeModel() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        panel.message = "Choose existing \(selected.name) \(selected.quantization) weights. Vella validates the architecture and quantization before importing."
        guard panel.runModal() == .OK, let path = panel.url else { return }
        do {
            try validateModel(path, expected: selected)
            installed[selected.id] = InstalledModel(path: path.path)
            try saveRegistry(updating: selected.id)
            message = mode == .dictation ? "Imported locally. Repository revision is unverified; benchmark before choosing." : "Imported locally. Repository revision is unverified; live streaming metrics are not available."
        } catch { message = error.localizedDescription }
    }
    func validateModel(_ folder: URL, expected: ModelRecommendation) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let tokenData = try? Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json")),
           let tokenizer = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any], tokenizer["auto_map"] != nil {
            throw VellaError.message("Custom tokenizer code is not supported.")
        }
        if expected.architecture == "sensevoice" && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("am.mvn").path) {
            throw VellaError.message("SenseVoice normalization file is missing. Reinstall the model.")
        }
        let quant = (config?["quantization"] ?? config?["quantization_config"]) as? [String: Any]
        let bits = quant?["bits"] as? Int
        let expectedBits = Int(expected.quantization.split(separator: "-").first ?? "")
        let architecture = config?["model_type"] as? String ?? ((config?["target"] as? String == "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel") ? "parakeet" : "")
        guard supports(architecture), supports(expected.architecture), architecture == expected.architecture, config?["auto_map"] == nil,
              expectedBits == nil ? bits == nil : bits == expectedBits,
              (try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw VellaError.message("The folder does not match this model architecture/quantization or is missing weights.")
        }
    }
    @discardableResult func useSelected() -> Bool {
        guard !busy, !calibration.isRunning, mayChangeModel() else {
            downloadError = "Finish dictation or the current download before switching models."; return false
        }
        guard let selected, let local = installed[selected.id] else {
            downloadError = "Download this model before choosing Use."; return false
        }
        do {
            try validateModel(URL(fileURLWithPath: local.path), expected: selected)
            var config = try Backend().configuration(requiresModel: false)
            // Keep a reversible local copy; release only Vella's own worker.
            let previous = try (try? Data(contentsOf: Backend.configURL)) ?? JSONEncoder().encode(config)
            try previous.write(to: Backend.support.appendingPathComponent("config.previous.json"), options: .atomic)
            config.selectModel(local.path, for: mode)
            try JSONEncoder().encode(config).write(to: Backend.configURL, options: .atomic)
            activeModelPath = local.path; onUse?()
            message = "Selected for the next \(mode.title.lowercased()). Previous settings saved. Previous Vella workers have been asked to stop."
            downloadError = nil
            // Explicit Use also retries missing/deferred calibration. Capture cancels
            // the calibration worker if the user starts dictating immediately.
            beginCalibration(id: selected.id, path: local.path)
            return true
        } catch { message = error.localizedDescription; downloadError = message; return false }
    }
    var agentRequest: String {
        let docs = resources.appendingPathComponent("AGENT_GUIDE.md").path
        let candidates = [resources.deletingLastPathComponent(), resources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        let checkout = candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("README.md").path) }
        let source = checkout.map { " Source checkout: \($0.path); read its README.md." } ?? ""
        return "Help me install another \(mode.title.lowercased()) transcription model in Vella. First read the local integration guide at \(docs).\(source) Follow its compatibility, download and setup instructions. Preserve my working model and permissions; ask before switching models. Model I want: [describe it here]."
    }
    @discardableResult func copyAgentRequest(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(agentRequest, forType: .string)
    }
    func cancel() {
        if calibratingID != nil {
            calibrationLaunch?.cancel(); calibrationLaunch = nil; calibration.cancel()
            if !calibration.isRunning { calibratingID = nil; busy = false }
            return
        }
        deadline?.cancel(); deadline = nil
        guard busy else { return }
        failureMessage = "Cancelled. Partial downloads may be resumed; no model selection was changed."
        guard let worker, worker.isRunning else { return } // Reject a queued successful-exit callback too.
        worker.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if worker.isRunning { kill(worker.processIdentifier, SIGKILL) } }
    }
    private func run(_ args: [String], timeout: Double) {
        guard !busy else { return }
        do {
            let python = try workerPython()
            guard FileManager.default.isExecutableFile(atPath: python.path) else { throw VellaError.message("Vella's Python runtime is unavailable. Repair the runtime setup before downloading a model.") }
            let child = Process(); child.executableURL = python
            child.arguments = [resources.appendingPathComponent("benchmark_worker.py").path] + args
            var env = ProcessInfo.processInfo.environment; env["PYTHONUNBUFFERED"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            child.environment = env
            let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
            buffer = Data(); receivedResult = false; pendingInstallation = nil; failureMessage = nil
            busy = true; progress = nil; message = "Starting…"
            try child.run(); worker = child
            let deadline = DispatchWorkItem { [weak self] in self?.cancel() }; self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
            Task.detached { [weak self] in
                // availableData returns currently available pipe bytes. read(upToCount:)
                // can wait for 4096 bytes, hiding short progress events until much later.
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    await self?.receive(chunk)
                }
                child.waitUntilExit()
                await self?.finished(code: child.terminationStatus)
            }
        } catch { busy = false; downloadingID = nil; downloadError = error.localizedDescription; message = error.localizedDescription }
    }
    func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = object["event"] as? String else { continue }
            if event == "progress" {
                message = object["message"] as? String ?? "Working…"
                if let done = object["completed"] as? Double, let total = object["total"] as? Double, total > 0 { progress = min(0.99, max(0, done / total)) }
            } else if event == "installed", let id = object["modelID"] as? String, let path = object["path"] as? String {
                guard id == downloadingID,
                      let expected = models.first(where: { $0.id == id }),
                      object["revision"] as? String == expected.revision,
                      URL(fileURLWithPath: path).standardizedFileURL == modelsDirectory.appendingPathComponent(id).standardizedFileURL else {
                    failureMessage = "Download returned an unexpected model or location."; continue
                }
                let model = models.first { $0.id == id }
                pendingInstallation = (id, InstalledModel(path: path, revision: object["revision"] as? String, name: model?.name, quantization: model?.quantization))
                receivedResult = true
            } else if event == "result" { receivedResult = true }
            else if event == "error" { failureMessage = object["message"] as? String }
        }
        if buffer.count > 1_000_000 { buffer.removeAll(); failureMessage = "Worker emitted an oversized response." }
    }
    private func beginCalibration(id: String, path: String) {
        guard automaticallyCalibrates else { return }
        guard mayChangeModel() else {
            message = "Installed. Local calibration deferred while dictation is active. Choose Use when ready."
            return
        }
        busy = true; calibratingID = id
        calibrationLaunch = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepareForCalibration?()
                try Task.checkCancellation()
                guard mayChangeModel() else { throw CancellationError() }
                let started = calibration.calibrate(modelPath: path, status: { [weak self] in self?.message = $0 }, completion: { [weak self] error in
                    self?.calibratingID = nil; self?.busy = false; self?.downloadError = error
                    self?.message = error ?? "Installed and calibrated. Choose Use to select it for dictation."
                })
                if !started { calibratingID = nil; busy = false }
            } catch {
                calibratingID = nil; busy = false
                if !(error is CancellationError) { downloadError = error.localizedDescription }
                message = "Installed. Calibration deferred; the model remains available."
            }
            calibrationLaunch = nil
        }
    }
    func shutdown() {
        calibrationLaunch?.cancel(); calibrationLaunch = nil; deadline?.cancel(); deadline = nil
        calibration.shutdown()
        if let child = worker, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        worker = nil
    }
    func finished(code: Int32) {
        deadline?.cancel(); deadline = nil; worker = nil; busy = false
        downloadingID = nil
        if let failureMessage { message = failureMessage; downloadError = failureMessage }
        else if code == 0 && receivedResult, let (id, local) = pendingInstallation {
            let previous = installed[id]
            do {
                installed[id] = local; try saveRegistry(updating: id)
                reload(); progress = 1; downloadingID = nil
                message = "Downloaded. Choose Use to select it for \(mode.title.lowercased())."
                beginCalibration(id: id, path: local.path)
            } catch {
                installed[id] = previous
                message = error.localizedDescription; downloadError = message
            }
        }
        else { message = "Download stopped (exit \(code)). Retry to resume."; downloadError = message }
    }
}

private struct BenchmarkPolicy: Decodable {
    let suiteID: String
    let suiteHash: String
    let minimumRepeats: Int
    let scorerSHA256: String?
    let lexicalNormalizerSHA256: String?
}
