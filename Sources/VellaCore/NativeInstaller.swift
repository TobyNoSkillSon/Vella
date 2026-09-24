import AppKit
import Darwin
import Foundation

public enum NativeInstallError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Owns one transactional Vella app replacement. No runtime folders or user recordings are removed.
public final class NativeInstaller {
    public struct Signature: Equatable { public let kind: String; public init(_ kind: String) { self.kind = kind } }
    public let preparedApp: URL
    public let destination: URL
    public let support: URL
    public let catalog: URL
    public let downloader: URL
    public var verify: (URL) throws -> Signature = NativeInstaller.verifySignedBundle
    public var stop: (URL) throws -> Bool = NativeInstaller.stopOwnedApplication
    public var launch: (URL) throws -> Void = NativeInstaller.launchApplication
    public var download: ((ModelRecommendation, URL) throws -> URL)?
    /// Test-only rollback injection; production never sets this.
    public var beforeSwap: () throws -> Void = {}
    public var afterSwap: () throws -> Void = {}
    public static let defaultModelID = "parakeet-tdt-0.6b-v3-mlx-4bit"

    public init(preparedApp: URL, destination: URL, support: URL, catalog: URL, downloader: URL) {
        self.preparedApp = preparedApp; self.destination = destination; self.support = support
        self.catalog = catalog; self.downloader = downloader
    }

    private static func rejectLinkedPath(_ url: URL, until boundary: URL) throws {
        var cursor = url.standardizedFileURL
        while cursor != boundary.standardizedFileURL {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
               (attributes[.type] as? FileAttributeType) == .typeSymbolicLink ||
                ((attributes[.type] as? FileAttributeType) == .typeRegular && (attributes[.referenceCount] as? Int ?? 1) > 1) {
                throw NativeInstallError.message("Linked/shared destination preserved: \(cursor.path)")
            }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }; cursor = parent
        }
    }
    private func validateModelDestination(_ folder: URL) throws {
        try Self.rejectLinkedPath(folder, until: support.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: folder.path),
           let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
                if values.isSymbolicLink == true || (values.isRegularFile == true && (attributes[.referenceCount] as? Int ?? 1) > 1) {
                    throw NativeInstallError.message("Linked/shared model asset preserved: \(item.path)")
                }
            }
        }
    }
    private func checkBusy() throws {
        let path = support.appendingPathComponent("dictation-status.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard let state = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
              let phase = state["phase"] as? String else { throw NativeInstallError.message("Cannot verify Vella's recording state; installation left unchanged.") }
        if ["preparing", "recording", "transcribing"].contains(phase) {
            throw NativeInstallError.message("Finish dictation before installing; the existing app was not replaced.")
        }
    }
    private func verifyPreparedBundle() throws -> Signature {
        if let enumerator = FileManager.default.enumerator(at: preparedApp, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let path as URL in enumerator {
                let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let resolved = path.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(preparedApp.standardizedFileURL.path + "/") else {
                        throw NativeInstallError.message("Prepared bundle contains an external link: \(path.path)")
                    }
                }
            }
        }
        let info = preparedApp.appendingPathComponent("Contents/Info.plist")
        guard preparedApp.lastPathComponent == "Vella.app",
              let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "dev.vella.dictation",
              FileManager.default.isExecutableFile(atPath: preparedApp.appendingPathComponent("Contents/MacOS/Vella").path),
              FileManager.default.isExecutableFile(atPath: preparedApp.appendingPathComponent("Contents/MacOS/VellaWorker").path),
              FileManager.default.isExecutableFile(atPath: preparedApp.appendingPathComponent("Contents/MacOS/VellaModelTool").path) else {
            throw NativeInstallError.message("Prepared Vella bundle or native helper is incomplete.")
        }
        return try verify(preparedApp)
    }
    private static func atomic(_ bytes: Data?, to path: URL) throws {
        if let bytes { try bytes.write(to: path, options: .atomic) }
        else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    private func saveConfig(initialModel: URL?, firstInstall: Bool) throws {
        let path = support.appendingPathComponent("config.json")
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
                throw NativeInstallError.message("Existing config.json is invalid; it was preserved")
            }
            config = existing
        }
        config["executable"] = destination.appendingPathComponent("Contents/MacOS/VellaWorker").path
        config.removeValue(forKey: "port")
        if firstInstall, let initialModel {
            config["model"] = initialModel.path
            config["streamingModel"] = ""
            config["preferredMicrophone"] = "MacBook Pro Microphone"
            config["fallbackMicrophone"] = "MacBook Pro Microphone"
        }
        if !FileManager.default.fileExists(atPath: path.path) {
            config["model"] = initialModel?.path ?? ""
            config["streamingModel"] = ""
            config["preferredMicrophone"] = "MacBook Pro Microphone"
            config["fallbackMicrophone"] = "MacBook Pro Microphone"
        }
        try Self.atomic(JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: path)
    }
    private func register(_ model: ModelRecommendation, at path: URL) throws {
        let registry = support.appendingPathComponent("models-installed.json")
        var records: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: registry.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any] else {
                throw NativeInstallError.message("Existing models-installed.json is invalid; it was preserved")
            }
            records = existing
        }
        records[model.id] = ["path": path.path, "revision": model.revision, "name": model.name, "quantization": model.quantization]
        try Self.atomic(JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]), to: registry)
    }
    private func checkExistingIdentity(_ replacement: Signature) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        let info = destination.appendingPathComponent("Contents/Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "dev.vella.dictation" else {
            throw NativeInstallError.message("Destination is not an existing Vella installation.")
        }
        let current = try verify(destination)
        guard current == replacement else { throw NativeInstallError.message("The existing signing identity differs; installation left unchanged. An explicit signing migration is required.") }
    }
    public func install() throws {
        let manager = FileManager.default
        // The common owner root is HOME in production and a disposable fixture
        // root in isolated tests. System aliases above it (such as /var) are not ours.
        var boundary = destination.standardizedFileURL.deletingLastPathComponent()
        while !support.standardizedFileURL.path.hasPrefix(boundary.path + "/") && boundary.path != "/" {
            boundary.deleteLastPathComponent()
        }
        guard destination.lastPathComponent == "Vella.app" else { throw NativeInstallError.message("Choose a destination named Vella.app") }
        for path in [destination, support, support.appendingPathComponent("Models"), support.appendingPathComponent("Runtimes"),
                     support.appendingPathComponent("config.json"), support.appendingPathComponent("models-installed.json"),
                     support.appendingPathComponent(".installer.lock")] {
            try Self.rejectLinkedPath(path, until: boundary)
        }
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        let lockPath = support.appendingPathComponent(".installer.lock").path
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NativeInstallError.message("Could not open Vella's installer lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NativeInstallError.message("Another Vella installer is running") }
        try checkBusy()
        let replacement = try verifyPreparedBundle()
        try checkExistingIdentity(replacement)
        let firstInstall = !manager.fileExists(atPath: destination.path) &&
            !manager.fileExists(atPath: support.appendingPathComponent("config.json").path) &&
            !manager.fileExists(atPath: support.appendingPathComponent("models-installed.json").path)
        let model = try JSONDecoder().decode([ModelRecommendation].self, from: Data(contentsOf: catalog)).first { $0.id == Self.defaultModelID }
        guard let model else { throw NativeInstallError.message("Pinned Parakeet Q4 is missing from the catalog") }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let transaction = destination.deletingLastPathComponent().appendingPathComponent(".vella-update-\(UUID().uuidString)")
        try manager.createDirectory(at: transaction, withIntermediateDirectories: true)
        let replacementPath = transaction.appendingPathComponent("replacement.app")
        let previousPath = transaction.appendingPathComponent("previous.app")
        var preserveTransaction = false
        defer {
            if !preserveTransaction && manager.fileExists(atPath: transaction.path) { try? manager.removeItem(at: transaction) }
        }
        try manager.copyItem(at: preparedApp, to: replacementPath)
        guard try verify(replacementPath) == replacement else { throw NativeInstallError.message("Staged Vella bundle signature changed") }
        let modelPath = support.appendingPathComponent("Models").appendingPathComponent(model.id)
        if firstInstall {
            try validateModelDestination(modelPath)
            let result = try (download ?? downloadWithNativeTool)(model, support.appendingPathComponent("Models"))
            guard result.standardizedFileURL == modelPath.standardizedFileURL else { throw NativeInstallError.message("Default model returned the wrong destination") }
            try validateModelDestination(modelPath)
            try NativeModelDownload.validate(modelPath, expected: model)
        }
        // Recheck after a potentially long download, immediately before touching the live app.
        try checkBusy()
        let wasRunning = try stop(destination)
        let configURL = support.appendingPathComponent("config.json")
        let registryURL = support.appendingPathComponent("models-installed.json")
        let oldConfig = try? Data(contentsOf: configURL), oldRegistry = try? Data(contentsOf: registryURL)
        var movedOld = false, movedNew = false
        do {
            try saveConfig(initialModel: firstInstall ? modelPath : nil, firstInstall: firstInstall)
            if firstInstall { try register(model, at: modelPath) }
            try beforeSwap()
            if manager.fileExists(atPath: destination.path) { try manager.moveItem(at: destination, to: previousPath); movedOld = true }
            try manager.moveItem(at: replacementPath, to: destination); movedNew = true
            try afterSwap()
        } catch {
            if movedNew { try? manager.moveItem(at: destination, to: replacementPath) }
            if movedOld {
                do { try manager.moveItem(at: previousPath, to: destination) }
                catch { preserveTransaction = true; throw NativeInstallError.message("Rollback failed. The previous app remains at \(previousPath.path); restore it before retrying.") }
            }
            try Self.atomic(oldConfig, to: configURL)
            try Self.atomic(oldRegistry, to: registryURL)
            if wasRunning && manager.fileExists(atPath: destination.path) { try? launch(destination) }
            throw error
        }
        // Installation is committed. A launch failure is reported, never rolled back.
        if wasRunning || firstInstall { try launch(destination) }
    }

    private func downloadWithNativeTool(_ model: ModelRecommendation, _ models: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: downloader.path) else { throw NativeInstallError.message("Native model downloader is missing") }
        let child = Process(); child.executableURL = downloader
        child.arguments = ["download", "--catalog", catalog.path, "--model-id", model.id, "--models-dir", models.path]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.standardError
        try child.run()
        let reader = DispatchSemaphore(value: 0)
        var result: [String: Any]?, failure: String?, buffer = Data()
        DispatchQueue.global().async {
            defer { reader.signal() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 1_000_000 {
                    failure = "Oversized download protocol output"
                    if child.isRunning { child.terminate() }
                    return
                }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { failure = "Malformed downloader response"; continue }
                    switch event["event"] as? String {
                    case "installed":
                        if result != nil { failure = "Duplicate model installation result" }; result = event
                    case "error": failure = event["message"] as? String ?? "Download failed"
                    case "progress":
                        let message = event["message"] as? String ?? "Downloading…"
                        if let completed = event["completed"] as? Double, let total = event["total"] as? Double, total > 0 {
                            print("\(message) \(min(99, Int(100 * completed / total)))%")
                        } else { print(message) }
                        fflush(stdout)
                    default: failure = "Unknown downloader response"
                    }
                }
            }
            if !buffer.isEmpty { failure = "Incomplete download protocol line" }
        }
        let deadline = Date().addingTimeInterval(1800)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let timedOut = child.isRunning
        if timedOut {
            child.terminate()
            let grace = Date().addingTimeInterval(2)
            while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        guard reader.wait(timeout: .now() + 10) == .success else { throw NativeInstallError.message("Downloader output did not close cleanly") }
        if timedOut { throw NativeInstallError.message("Download timed out. Rerun to resume retained partial files") }
        if let failure { throw NativeInstallError.message(failure) }
        guard child.terminationStatus == 0,
              result?["modelID"] as? String == model.id, result?["revision"] as? String == model.revision,
              result?["path"] as? String == models.appendingPathComponent(model.id).path else {
            throw NativeInstallError.message("Native downloader exited without a matching verified result")
        }
        return models.appendingPathComponent(model.id)
    }

    private static func run(_ args: [String]) throws -> String {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); child.arguments = args
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
        try child.run(); child.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard child.terminationStatus == 0 else { throw NativeInstallError.message("Bundle signature verification failed: \(text.suffix(1200))") }
        return text
    }
    public static func verifySignedBundle(_ app: URL) throws -> Signature {
        _ = try run(["--verify", "--strict", "--deep", app.path])
        let details = try run(["-dv", "--verbose=4", app.path])
        let team = details.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map(String.init)
        if details.contains("Signature=adhoc") { return Signature("adhoc") }
        guard let team, team != "TeamIdentifier=not set" else { throw NativeInstallError.message("Bundle signing identity is unavailable") }
        return Signature(team)
    }
    public static func stopOwnedApplication(_ destination: URL) throws -> Bool {
        let workspace = NSWorkspace.shared
        func isTarget(_ other: URL?) -> Bool {
            guard let other else { return false }
            if other.standardizedFileURL == destination.standardizedFileURL { return true }
            guard let a = try? other.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
                  let b = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject else { return false }
            return a.isEqual(b)
        }
        if let known = workspace.urlForApplication(withBundleIdentifier: "dev.vella.dictation"),
           !isTarget(known),
           FileManager.default.fileExists(atPath: known.path) {
            throw NativeInstallError.message("Another Vella copy is registered at \(known.path). Update that copy instead")
        }
        let applications = workspace.runningApplications.filter { $0.bundleIdentifier == "dev.vella.dictation" }
        for app in applications where !isTarget(app.bundleURL) {
            throw NativeInstallError.message("Another Vella installation is running; it was not stopped")
        }
        guard applications.count <= 1 else { throw NativeInstallError.message("Multiple Vella instances are running") }
        applications.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while applications.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard applications.allSatisfy(\.isTerminated) else { throw NativeInstallError.message("Vella did not quit; existing installation was not replaced") }
        return !applications.isEmpty
    }
    public static func launchApplication(_ app: URL) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/open"); child.arguments = [app.path]
        try child.run(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw NativeInstallError.message("Installation completed but Vella did not open; use Finder to open \(app.path)") }
    }
}
