import AppKit
import Foundation
import Darwin
import VellaCore

@MainActor final class ModelLibrary: ObservableObject {
    let mode: RecognitionMode
    /// One catalog (models.json v2) for both modes; each library keeps its mode's variants.
    let catalogName = "models.json"
    func supports(_ architecture: String) -> Bool {
        ModelRegistry.descriptor(architecture: architecture)?.mode == mode
    }
    @Published var models: [ModelRecommendation] = []
    @Published var installed: [String: InstalledModel] = [:]
    @Published var selectedID = "Qwen3-ASR-1.7B-bf16"
    @Published var message = "Choose a model. Compare it on the same audio."
    @Published var busy = false
    @Published var progress: Double?
    @Published var downloadingID: String?
    @Published var downloadError: String?
    @Published var activeModelPath = ""
    /// False when the installed-model registry exists but could not be read or decoded: `installed` is then not a
    /// complete record of which Models folders are Vella's, and nothing may be deleted on its strength.
    private(set) var registryReadable = false
    let calibration: CalibrationStore
    private let automaticallyCalibrates: Bool
    @Published var calibratingID: String?
    var downloadBaseURL = URL(string: "https://huggingface.co")!
    var downloadConfiguration: URLSessionConfiguration = .default
    private var downloadClient: NativeModelDownload?
    private var downloadTask: Task<Void, Never>?
    private var downloadTimeout: Task<Void, Never>?
    private var downloadToken: UUID?
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
    /// Menu-header label for the selected model, e.g. "Parakeet v3 4-bit"; nil when none is selected.
    var activeModelLabel: String? {
        guard !activeModelPath.isEmpty, let model = models.first(where: { installed[$0.id]?.path == activeModelPath }) else { return nil }
        return "\(model.name.replacingOccurrences(of: " ASR \u{B7}", with: "")) \(precisionInProse(precisionLabel(legacyQuantization: model.quantization)))"
    }
    var selected: ModelRecommendation? { models.first { $0.id == selectedID } }
    static let processor = HostInfo.cpuBrand ?? "Unknown processor"
    func reload() {
        let decoder = JSONDecoder()
        registryReadable = false
        do {
            models = try catalogVariants(contentsOf: resources.appendingPathComponent(catalogName)).filter { supports($0.architecture) }
            if let data = try? Data(contentsOf: registryURL), let saved = try? decoder.decode([String: InstalledModel].self, from: data) {
                installed = saved; registryReadable = true
            } else {
                registryReadable = !FileManager.default.fileExists(atPath: registryURL.path)
            }
            if registryURL == Self.registry, let config = try? Backend().configuration(requiresModel: false) {
                activeModelPath = mode == .dictation ? config.model : config.streamingModel
            }
            if !models.contains(where: { $0.id == selectedID }) { selectedID = models.first?.id ?? "" }
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
    /// Launch migration of the shared registry (registry only; files are never touched): an entry under an earlier id
    /// that the catalog maps to a variant (`legacyIDs`) is re-keyed to that variant when its config.json has exactly
    /// the variant's format; then every entry whose id the catalog no longer has is dropped (a removed model). Returns
    /// the (re-keyed, dropped) ids. Nothing is written when the registry is unreadable or nothing changes.
    @discardableResult
    func migrateRegistry(catalog: ModelCatalog) -> (rekeyed: [String: String], dropped: [String]) {
        guard let data = try? Data(contentsOf: registryURL),
              var entries = try? JSONDecoder().decode([String: InstalledModel].self, from: data) else { return ([:], []) }
        var rekeyed: [String: String] = [:]
        for (id, entry) in entries.sorted(by: { $0.key < $1.key }) where catalog.locate(variant: id) == nil {
            guard let family = catalog.families.first(where: { $0.precision(ofLegacyID: id) != nil }),
                  let precision = family.precision(ofLegacyID: id), let variant = family.variants[precision],
                  entries[variant.id] == nil, checkpointMatches(URL(fileURLWithPath: entry.path), family: family, precision: precision) else { continue }
            entries[variant.id] = InstalledModel(path: entry.path, revision: entry.revision, name: family.name, quantization: legacyQuantization(precision))
            entries[id] = nil
            rekeyed[id] = variant.id
        }
        let dropped = entries.keys.filter { catalog.locate(variant: $0) == nil }.sorted()
        for id in dropped { entries[id] = nil }
        guard !rekeyed.isEmpty || !dropped.isEmpty else { return ([:], []) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(entries), (try? writeRegistryData(bytes, registryURL)) != nil else { return ([:], []) }
        reload()
        return (rekeyed, dropped)
    }
    /// Whether the checkpoint at `folder` is this precision's exact format: architecture, and for 8b/4b affine
    /// quantization at the catalog's bits and group size; for 16-bit, unquantized.
    func checkpointMatches(_ folder: URL, family: ModelFamily, precision: String) -> Bool {
        guard let variant = family.variants[precision],
              let bytes = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              checkpointArchitecture(config) == variant.architecture else { return false }
        let quant = (config["quantization"] ?? config["quantization_config"]) as? [String: Any]
        guard let bits = variant.bits else { return quant == nil }
        let mode = quant?["mode"] as? String
        return quant?["bits"] as? Int == bits && quant?["group_size"] as? Int == (variant.groupSize ?? 64) && (mode == nil || mode == "affine")
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
        // A selected precision made on this Mac reads these weights; deleting them would leave the selection pointing
        // at a model that can no longer load.
        let selections = Set(([active, activeModelPath] + protected).filter { !$0.isEmpty })
        if selections.contains(where: { selection in
            derivedModelManifest(at: URL(fileURLWithPath: selection)).map {
                URL(fileURLWithPath: $0.source).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath()
            } ?? false
        }) {
            return "Switch to another model in that mode before deleting the weights its selected precision is made from."
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
    /// Paths a partial-download clean-up must never remove: installed models and the configured ones.
    var keptModelPaths: Set<String> {
        Set(installed.values.map(\.path) + [activeModelPath] + ((try? protectedModelPaths()) ?? []))
    }
    /// Whether `keptModelPaths` is complete: the registry and the saved selections were both readable.
    var ownershipVerified: Bool { registryReadable && (try? protectedModelPaths()) != nil }
    /// Removes a cancelled or failed download's files (the whole `Models/<id>` folder of a model that is not installed).
    private func removePartialDownload(_ id: String) {
        guard installed[id] == nil, downloadingID != id else { return }
        removeUnfinishedDownload(id: id, modelsDirectory: modelsDirectory, keep: keptModelPaths)
    }
    /// `Parakeet v3 FP32`, for the footer's download and error lines.
    private func downloadLabel(_ model: ModelRecommendation) -> String {
        "\(model.name) \(precisionInProse(precisionLabel(legacyQuantization: model.quantization)))"
    }

    /// Downloads the selected variant. `approval` comes only from the confirmation popup (DownloadGate) and must name
    /// this variant: nothing downloads without the user's Download. Returns false (with `downloadError` set) when the
    /// download did not start. `completion` runs once when it ends: true = installed.
    /// `pendingRecording`: the first-dictation Get row. The app is deliberately busy then (it holds the saved
    /// recording in `.preparing` until the model arrives), so that one download is authorized explicitly instead of
    /// relaxing the general "not while dictating" guard. Busy/calibration guards still apply.
    /// `calibrate: false` skips local calibration afterwards (the model loads right away instead).
    @discardableResult
    func download(approval: DownloadApproval, pendingRecording: Bool = false, calibrate: Bool = true,
                  completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let selected, approval.variantID == selected.id else {
            downloadError = "This download was not confirmed."; return false
        }
        guard !busy, !calibration.isRunning, calibratingID == nil else {
            downloadError = "Another download or calibration is running. Try again when it finishes."; return false
        }
        guard pendingRecording || mayChangeModel() else {
            message = "Finish or stop dictation before installing a model."; downloadError = message; return false
        }
        beforeHeavyWork?()
        let label = downloadLabel(selected)
        downloadingID = selected.id; downloadError = nil
        busy = true; progress = nil; message = "\(label) \u{00b7} Starting…"
        downloadCompletion = completion
        let token = UUID(); downloadToken = token
        let client = NativeModelDownload(baseURL: downloadBaseURL, configuration: downloadConfiguration,
            catalogURL: resources.appendingPathComponent(catalogName)) { [weak self] text, done, total in
            Task { @MainActor [weak self] in
                guard let self, self.downloadToken == token else { return }
                var line = "\(label) \u{00b7} \(text)"
                if let done, let total, total > 0 {
                    self.progress = min(0.99, max(0, Double(done) / Double(total)))
                    line += " \(formatBytes(done)) of \(formatBytes(total))"
                }
                self.message = line
            }
        }
        downloadClient = client
        downloadTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            guard !Task.isCancelled, let self, self.downloadToken == token else { return }
            self.cancel()
            self.message = "\(label) download timed out after 1 hour; partial files removed."; self.downloadError = self.message
        }
        downloadTask = Task { [weak self] in
            do {
                guard let self else { return }
                let folder = try await client.download(selected, modelsDirectory: self.modelsDirectory)
                guard self.downloadToken == token, !Task.isCancelled,
                      selected.id == self.downloadingID, folder.standardizedFileURL == self.modelsDirectory.appendingPathComponent(selected.id).standardizedFileURL else { return }
                try NativeModelDownload.validate(folder, expected: selected)
                // A stored conversion (Parakeet v3: the FP32 download becomes BF16 once, only BF16 is kept).
                if let (family, precision) = self.catalog?.locate(variant: selected.id), let variant = family.variants[precision], variant.isStored {
                    self.message = "\(label) \u{00b7} Converting to \(precisionInProse(precision))\u{2026}"
                    try await Self.convertStored(folder, family: family, precision: precision, repository: selected.repository, revision: selected.revision)
                    guard self.downloadToken == token, !Task.isCancelled else { return }
                    try NativeModelDownload.validate(folder, expected: selected)
                }
                let previous = self.installed[selected.id]
                do {
                    self.installed[selected.id] = InstalledModel(path: folder.path, revision: selected.revision, name: selected.name, quantization: selected.quantization)
                    try self.saveRegistry(updating: selected.id)
                    self.reload(); self.progress = 1; self.message = "\(label) downloaded."
                    self.downloadTimeout?.cancel(); self.downloadTimeout = nil
                    self.downloadToken = nil; self.downloadTask = nil; self.downloadClient = nil; self.downloadingID = nil; self.busy = false
                    if calibrate { self.beginCalibration(id: selected.id, path: folder.path) }
                    self.finishDownload(true)
                } catch { self.installed[selected.id] = previous; throw error }
            } catch {
                guard let self else { return }
                let current = self.downloadToken == token   // false: cancel() already reported and completed it
                if current {
                    self.downloadTimeout?.cancel(); self.downloadTimeout = nil
                    self.downloadingID = nil; self.busy = false; self.downloadToken = nil; self.downloadTask = nil; self.downloadClient = nil
                }
                // A cancelled or failed download leaves no partial files (unless a newer download of it is running).
                self.removePartialDownload(selected.id)
                guard current else { return }
                self.message = error is CancellationError ? "\(label) download cancelled; partial files removed."
                    : "\(label) download failed: \(Self.reason(error)) Partial files removed."
                self.downloadError = self.message
                self.finishDownload(false)
            }
        }
        return true
    }
    /// The bundled catalog (families), for stored conversions and the registry migration; nil when unreadable.
    var catalog: ModelCatalog? { (try? Data(contentsOf: resources.appendingPathComponent(catalogName))).flatMap { try? decodeCatalog($0) } }
    /// Runs the fp32 → bf16 conversion off the main thread.
    nonisolated static func convertStored(_ folder: URL, family: ModelFamily, precision: String, repository: String, revision: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try convertFolderToBF16(folder, family: family.id, precision: precision, sourceRepository: repository, sourceRevision: revision)
        }.value
    }
    private func finishDownload(_ installed: Bool) {
        let completion = downloadCompletion; downloadCompletion = nil
        completion?(installed)
    }
    /// A failure's reason as one sentence for the footer; a stall (no data within the 120 s request timeout) says so.
    static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut { return "it stalled (no data from Hugging Face for 2 minutes)." }
        let trimmed = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? trimmed : trimmed + "."
    }
    /// The running download's completion, so cancel() can end it.
    private var downloadCompletion: ((Bool) -> Void)?
    func validateModel(_ folder: URL, expected: ModelRecommendation) throws {
        guard supports(expected.architecture) else { throw VellaError.message("The folder does not match this model architecture/quantization or is missing weights.") }
        try NativeModelDownload.validate(folder, expected: expected)
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
        guard busy else { return }
        let id = downloadingID
        let label = models.first { $0.id == id }.map(downloadLabel) ?? "Model"
        downloadToken = nil; downloadTimeout?.cancel(); downloadTimeout = nil
        downloadClient?.cancel(); downloadTask?.cancel(); downloadTask = nil; downloadClient = nil
        downloadingID = nil; busy = false
        // Its partial files go now; the download task removes anything it wrote while stopping.
        if let id { removePartialDownload(id) }
        message = "\(label) download cancelled; partial files removed."; downloadError = message
        let completion = downloadCompletion; downloadCompletion = nil
        completion?(false)
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
        calibrationLaunch?.cancel(); calibrationLaunch = nil
        calibration.shutdown()
        downloadToken = nil; downloadTimeout?.cancel(); downloadTimeout = nil
        downloadClient?.cancel(); downloadTask?.cancel(); downloadTask = nil; downloadClient = nil
    }
}
