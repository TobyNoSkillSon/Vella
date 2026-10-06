import AppKit
import Darwin
import Foundation

public enum NativeInstallError: LocalizedError {
    case message(String), signingMigrationRequired(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text), .signingMigrationRequired(let text): return text
        }
    }
}

/// Owns one transactional Vella app replacement. Nothing is downloaded or loaded: a fresh
/// install starts with no model. No models, runtime folders or user recordings are removed.
/// The whole bundle is replaced, so files from older layouts never survive an update.
public final class NativeInstaller {
    public struct Signature: Equatable { public let kind: String; public init(_ kind: String) { self.kind = kind } }
    public let preparedApp: URL
    public let destination: URL
    public let support: URL
    public var verify: (URL) throws -> Signature = NativeInstaller.verifySignedBundle
    public lazy var stop: (URL) throws -> Bool = { [unowned self] in try NativeInstaller.stopOwnedApplication($0, bundleIdentifier: self.bundleIdentifier) }
    public lazy var launch: (URL) throws -> Void = { [unowned self] in try NativeInstaller.launchApplication($0, support: self.support) }
    /// Test-only rollback injection; production never sets this.
    public var beforeSwap: () throws -> Void = {}
    public var afterSwap: () throws -> Void = {}
    /// Previous app, kept beside the destination until the caller has checked readiness.
    public var keepPrevious = false
    /// The committed backup remains discoverable even if launching the replacement throws.
    public private(set) var previousApp: URL?
    /// Explicit opt-in to an older release/build; signing checks remain mandatory.
    public var allowVersionDowngrade = false
    /// Explicit installer-only transition: any verified installed identity -> pinned Vella release signature.
    public var allowSigningMigration = false
    public private(set) var didMigrateSigning = false
    public var signingRetryCommand = "scripts/install.sh --migrate-signing"
    public private(set) var signingMigrationExplanation = NativeInstaller.migrationExplanation
    public var verifyMigrationTarget: (URL) throws -> Void = { app in
        try NativeInstaller.verifyRequirement(app, NativeInstaller.releaseRequirement)
    }
    public static let releaseRequirement = "identifier \"dev.vella.dictation\" and certificate leaf = H\"2ca2587c8b85ef687e68950e405ec58ce31fc1c7\""
    public static let migrationExplanation =
        "This changes your installed signing identity to Vella’s pinned release signature. macOS will ask for Microphone and Accessibility access again. Settings, history, recordings and models are kept. The old app is kept for rollback."

    public static func migrationExplanation(replacing signature: Signature) -> String {
        let identity: String
        if signature.kind == "adhoc" {
            identity = "ad-hoc"
        } else if let range = signature.kind.range(of: #"subject\.CN\] = "([^"]*)""#, options: .regularExpression),
            let name = signature.kind[range].split(separator: "\"").dropFirst().first
        {
            identity = String(name)
        } else {
            identity = signature.kind.replacingOccurrences(of: "designated => ", with: "")
        }
        return "Installed signing identity being replaced: \(identity). " + migrationExplanation
    }

    /// Lab installs of a separately identified candidate use another id; releases never do.
    public var bundleIdentifier = "dev.vella.dictation"
    public var now: () -> Date = Date.init

    public init(preparedApp: URL, destination: URL, support: URL) {
        self.preparedApp = preparedApp; self.destination = destination; self.support = support
    }

    private static func rejectLinkedPath(_ url: URL, until boundary: URL) throws {
        var cursor = url.standardizedFileURL
        while !sameDirectory(cursor, boundary) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
                (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
                    || ((attributes[.type] as? FileAttributeType) == .typeRegular && (attributes[.referenceCount] as? Int ?? 1) > 1)
            {
                throw NativeInstallError.message("Linked/shared destination preserved: \(cursor.path)")
            }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }; cursor = parent
        }
    }
    private func checkBusy() throws {
        let path = support.appendingPathComponent("dictation-status.json")
        if FileManager.default.fileExists(atPath: path.path) {
            guard let state = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
                let phase = state["phase"] as? String
            else { throw NativeInstallError.message("Cannot verify Vella's recording state; installation left unchanged.") }
            if ["preparing", "recording", "transcribing"].contains(phase) {
                throw NativeInstallError.message("Finish dictation before installing; the existing app was not replaced.")
            }
        }
        if let loading = InstallReadiness.loadingModel(statusFile: support.appendingPathComponent(InstallReadiness.statusFileName)) {
            throw NativeInstallError.message("Vella is loading \(loading). Try again in a moment; installation left unchanged.")
        }
    }
    private func verifyPreparedBundle() throws -> Signature {
        if let enumerator = FileManager.default.enumerator(at: preparedApp, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let path as URL in enumerator {
                let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let resolved = path.resolvingSymlinksInPath().standardizedFileURL
                    guard isWithinDirectory(resolved, root: preparedApp) else {
                        throw NativeInstallError.message("Prepared bundle contains an external link: \(path.path)")
                    }
                }
            }
        }
        let info = preparedApp.appendingPathComponent("Contents/Info.plist")
        guard preparedApp.lastPathComponent == "Vella.app",
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == bundleIdentifier,
            FileManager.default.isExecutableFile(atPath: preparedApp.appendingPathComponent("Contents/MacOS/Vella").path),
            FileManager.default.isExecutableFile(atPath: preparedApp.appendingPathComponent("Contents/MacOS/VellaWorker").path),
            FileManager.default.isExecutableFile(atPath: preparedApp.appendingPathComponent("Contents/MacOS/VellaStreamingWorker").path),
            (try preparedApp.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib").resourceValues(forKeys: [.fileSizeKey]).fileSize
                ?? 0) > 0
        else {
            throw NativeInstallError.message("Prepared Vella bundle or native helper is incomplete.")
        }
        return try verify(preparedApp)
    }
    private static func atomic(_ bytes: Data?, to path: URL) throws {
        if let bytes { try bytes.write(to: path, options: .atomic) } else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// Existing settings only: drop the Python-era port. A fresh install writes no config (nothing predefined).
    private func saveConfig() throws {
        let path = support.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw NativeInstallError.message("Existing config.json is invalid; it was preserved")
        }
        guard config.removeValue(forKey: "port") != nil else { return }
        try Self.atomic(JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: path)
    }
    private func checkExistingIdentity(_ replacement: Signature) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        let info = destination.appendingPathComponent("Contents/Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == bundleIdentifier
        else {
            throw NativeInstallError.message("Destination is not an existing Vella installation.")
        }
        let current = try verify(destination)
        guard current != replacement else { return }
        let target = replacement.kind.replacingOccurrences(of: "designated => ", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target == Self.releaseRequirement.lowercased() else {
            throw NativeInstallError.message(
                "The existing signing identity differs; installation left unchanged. Signing migration is allowed only to Vella’s pinned release signature.")
        }
        try verifyMigrationTarget(preparedApp)
        signingMigrationExplanation = Self.migrationExplanation(replacing: current)
        guard allowSigningMigration else {
            throw NativeInstallError.signingMigrationRequired(signingMigrationExplanation + " Nothing changed. To opt in, run: \(signingRetryCommand)")
        }
        keepPrevious = true; didMigrateSigning = true
    }
    /// Refuse older releases (or older builds of the same release) before consent, stopping or swapping.
    /// Manual rollback moves the backup bundle back; it does not use this installer.
    private func checkExistingVersion() throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        func metadata(_ app: URL) throws -> (version: String, components: [Int], build: Int) {
            let info = app.appendingPathComponent("Contents/Info.plist")
            guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
                let version = plist["CFBundleShortVersionString"] as? String
            else { throw NativeInstallError.message("Cannot verify Vella's version; installation left unchanged.") }
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { part in
                !part.isEmpty && part.count <= 9 && part.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(part) : nil
            }
            guard parts.count == 3, numbers.count == 3 else {
                throw NativeInstallError.message("Cannot verify Vella's version; installation left unchanged.")
            }
            guard let build = plist["CFBundleVersion"] as? String, !build.isEmpty, build.count <= 9,
                build.allSatisfy({ $0.isASCII && $0.isNumber }), let buildNumber = Int(build)
            else {
                throw NativeInstallError.message("Cannot verify Vella's build; installation left unchanged.")
            }
            return (version, numbers, buildNumber)
        }
        let current = try metadata(destination), replacement = try metadata(preparedApp)
        let olderVersion = replacement.components.lexicographicallyPrecedes(current.components)
        let olderBuild = replacement.components == current.components && replacement.build < current.build
        guard allowVersionDowngrade || (!olderVersion && !olderBuild) else {
            throw NativeInstallError.message(
                "Refusing to replace Vella \(current.version) (build \(current.build)) with older Vella \(replacement.version) (build \(replacement.build)). Installation left unchanged. To intentionally downgrade, repeat the original command with --allow-downgrade."
            )
        }
    }
    /// Installs the prepared app and launches it. Returns where the previous app was kept when
    /// `keepPrevious` is set (delete it after readiness; restore it by moving it back), else nil.
    @discardableResult
    public func install() throws -> URL? {
        didMigrateSigning = false; previousApp = nil
        signingMigrationExplanation = Self.migrationExplanation
        let manager = FileManager.default
        // The common owner root is HOME in production and a disposable fixture
        // root in isolated tests. System aliases above it (such as /var) are not ours.
        var boundary = destination.standardizedFileURL.deletingLastPathComponent()
        while !isWithinDirectory(support, root: boundary) && boundary.path != "/" {
            boundary.deleteLastPathComponent()
        }
        guard destination.lastPathComponent == "Vella.app" else { throw NativeInstallError.message("Choose a destination named Vella.app") }
        for path in [
            destination, support, support.appendingPathComponent("Models"), support.appendingPathComponent("Runtimes"),
            support.appendingPathComponent("config.json"), support.appendingPathComponent("models-installed.json"),
            support.appendingPathComponent(".installer.lock")
        ] {
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
        try checkExistingVersion()
        try checkExistingIdentity(replacement)
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
        // Recheck immediately before touching the live app.
        try checkBusy()
        let wasRunning = try stop(destination)
        let configURL = support.appendingPathComponent("config.json")
        let oldConfig = try? Data(contentsOf: configURL)
        var movedOld = false, movedNew = false
        do {
            try saveConfig()
            try beforeSwap()
            if manager.fileExists(atPath: destination.path) { try manager.moveItem(at: destination, to: previousPath); movedOld = true }
            try manager.moveItem(at: replacementPath, to: destination); movedNew = true
            try afterSwap()
        } catch {
            if movedNew { try? manager.moveItem(at: destination, to: replacementPath) }
            if movedOld {
                do { try manager.moveItem(at: previousPath, to: destination) } catch {
                    preserveTransaction = true; throw NativeInstallError.message("Rollback failed. The previous app remains at \(previousPath.path); restore it before retrying.")
                }
            }
            try Self.atomic(oldConfig, to: configURL)
            if wasRunning && manager.fileExists(atPath: destination.path) { try? launch(destination) }
            throw error
        }
        var kept: URL?
        if movedOld && keepPrevious {
            let stamp = ISO8601DateFormatter.string(from: now(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            let target = destination.deletingLastPathComponent().appendingPathComponent(".Vella.app.previous.\(stamp).\(getpid())")
            do { try manager.moveItem(at: previousPath, to: target); kept = target } catch { preserveTransaction = true; kept = previousPath }
        }
        // Installation is committed. A launch failure is reported, never rolled back.
        previousApp = kept
        do { try launch(destination) } catch {
            let version =
                (try? PropertyListSerialization.propertyList(
                    from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
                ?? "2.0.1"
            let displayVersion = version.split(separator: ".").prefix(2).joined(separator: ".")
            let message = "Vella \(displayVersion) was installed but didn't start (\(error.localizedDescription))."
            let recovery =
                kept.map {
                    " Your previous version is kept at \($0.path). To go back, quit Vella and run:\n"
                        + Self.rollbackCommand(app: destination, backup: $0)
                } ?? ""
            throw NativeInstallError.message(message + recovery)
        }
        return kept
    }

    /// A repeat paste is harmless. Refuse a running app (or an unverifiable process check),
    /// and retain both bundles: no deletion and no overwriting an existing move target.
    private static func rollbackCommand(app: URL, backup: URL) -> String {
        "(app=\(shellQuote(app.path)); backup=\(shellQuote(backup.path)); "
            + "[ -d \"$backup\" ] || { printf '%s\\n' 'Rollback not performed: previous app backup is missing; nothing changed.' >&2; exit 1; }; "
            + "pgrep -x Vella >/dev/null 2>&1; case $? in 1) ;; 0) printf '%s\\n' 'Rollback not performed: Vella is running. Quit Vella and try again.' >&2; exit 1 ;; "
            + "*) printf '%s\\n' 'Rollback not performed: could not check whether Vella is running; nothing changed.' >&2; exit 1 ;; esac; "
            + "stamp=$(date +%Y%m%d-%H%M%S) || exit 1; failed=\"${app%.app}.failed.$stamp.$$.app\"; "
            + "[ ! -e \"$failed\" ] && [ ! -L \"$failed\" ] && mv -n -- \"$app\" \"$failed\" && [ ! -e \"$app\" ] && [ ! -L \"$app\" ] "
            + "&& mv -n -- \"$backup\" \"$app\" && [ ! -e \"$backup\" ] "
            + "|| { printf '%s\\n' 'Rollback stopped: bundles were kept; check the app and backup paths before retrying.' >&2; exit 1; })"
    }

    /// POSIX shell single-quoting keeps spaces, quotes and metacharacters literal in recovery commands.
    private static func shellQuote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    private static func run(_ args: [String]) throws -> String {
        let (status, text) = try runTool("/usr/bin/codesign", args)
        guard status == 0 else { throw NativeInstallError.message("Bundle signature verification failed: \(text.suffix(1200))") }
        return text
    }
    /// The leading '=' means inline requirement text, not a path to a requirement file.
    public static func verifyRequirement(_ app: URL, _ requirement: String) throws {
        _ = try run(["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path])
    }
    public static func verifySignedBundle(_ app: URL) throws -> Signature {
        _ = try run(["--verify", "--strict", "--deep", app.path])
        let details = try run(["-dv", "--verbose=4", app.path])
        if details.contains("Signature=adhoc") { return Signature("adhoc") }
        // Certificate-signed (team or local self-signed): the designated requirement names the
        // certificate, so equal requirements keep macOS privacy permissions across the update.
        let requirement = try run(["-d", "-r-", app.path]).split(separator: "\n").first { $0.hasPrefix("designated => ") }.map(String.init)
        guard let requirement else { throw NativeInstallError.message("Bundle signing identity is unavailable") }
        return Signature(requirement)
    }
    public static func stopOwnedApplication(_ destination: URL, bundleIdentifier: String = "dev.vella.dictation") throws -> Bool {
        let workspace = NSWorkspace.shared
        func isTarget(_ other: URL?) -> Bool {
            guard let other else { return false }
            if sameDirectory(other, destination) { return true }
            guard let a = try? other.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
                let b = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            else { return false }
            return a.isEqual(b)
        }
        // Another installed copy in an Applications folder would leave two Vellas; build and
        // staging copies elsewhere (which LaunchServices registers on sight) are not installations.
        for known in workspace.urlsForApplications(withBundleIdentifier: bundleIdentifier)
        where !isTarget(known) && isInstallLocation(known) && FileManager.default.fileExists(atPath: known.path) {
            throw NativeInstallError.message("Another Vella copy is installed at \(known.path). Update that copy instead")
        }
        let applications = workspace.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
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
    public static let defaultSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella")
    /// A non-default support folder (isolated installs and tests) is passed to the app, which honours VELLA_SUPPORT_DIR.
    public static func launchArguments(_ app: URL, support: URL?) -> [String] {
        guard let support, support.standardizedFileURL.path != defaultSupport.standardizedFileURL.path else { return [app.path] }
        return ["--env", "VELLA_SUPPORT_DIR=\(support.standardizedFileURL.path)", app.path]
    }
    /// /Applications or ~/Applications (any depth).
    public static func isInstallLocation(_ app: URL) -> Bool {
        let path = app.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/")
    }
    public static func launchApplication(_ app: URL, support: URL? = nil) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/open"); child.arguments = launchArguments(app, support: support)
        try child.run(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw NativeInstallError.message("Installation completed but Vella did not open; use Finder to open \(app.path)") }
    }
}
