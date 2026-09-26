import CryptoKit
import Foundation
import Security
import VellaCore

/// Why an update did not happen, in words for the popup and the log.
public struct UpdateError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Where updates come from. Defaults: the GitHub releases API for TobyNoSkillSon/Vella and the release's download
/// directory, the same files scripts/install-release.sh downloads. Overrides (tests, local QA of a packaged release):
///   VELLA_UPDATE_API_URL      the "latest release" JSON
///   VELLA_RELEASE_BASE_URL    the directory holding Vella-X.Y.Z-arm64.zip and SHA256SUMS (as install-release.sh)
///   VELLA_UPDATE_CA_CERT      a PEM certificate to trust as the only root (a local test server's CA)
/// Both URLs must be HTTPS, or file:// for a release packaged on this Mac (scripts/package-release.sh), as
/// install-release.sh allows.
public struct UpdateSource: Sendable {
    public static let defaultAPI = URL(string: "https://api.github.com/repos/TobyNoSkillSon/Vella/releases/latest")!
    public var apiURL: URL
    public var baseURL: URL?
    public var anchorDER: Data?

    public init(apiURL: URL = defaultAPI, baseURL: URL? = nil, anchorDER: Data? = nil) {
        self.apiURL = apiURL; self.baseURL = baseURL; self.anchorDER = anchorDER
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> UpdateSource {
        var source = UpdateSource()
        func allowed(_ url: URL) -> Bool { url.scheme == "https" || url.scheme == "file" }
        if let api = env["VELLA_UPDATE_API_URL"], !api.isEmpty {
            guard let url = URL(string: api), allowed(url) else { throw UpdateError("VELLA_UPDATE_API_URL must use HTTPS") }
            source.apiURL = url
        }
        if let base = env["VELLA_RELEASE_BASE_URL"], !base.isEmpty {
            guard let url = URL(string: base), allowed(url) else { throw UpdateError("Release base URL must use HTTPS") }
            source.baseURL = url
        }
        if let path = env["VELLA_UPDATE_CA_CERT"], !path.isEmpty {
            guard let pem = try? String(contentsOfFile: path, encoding: .utf8), let der = Self.der(fromPEM: pem) else {
                throw UpdateError("VELLA_UPDATE_CA_CERT is not a PEM certificate: \(path)")
            }
            source.anchorDER = der
        }
        return source
    }

    /// The download directory for a release: the override, else github.com/…/releases/download/v<version>.
    public func downloadBase(for release: ReleaseInfo) -> URL {
        baseURL ?? URL(string: "https://github.com/TobyNoSkillSon/Vella/releases/download/v\(release.version)")!
    }

    static func der(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard pem.contains("BEGIN CERTIFICATE"), let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return data
    }
}

/// HTTPS client for the release check and downloads. Redirects must stay on HTTPS (GitHub redirects release assets
/// to its object storage). No cookies, no cache, no credentials; the only headers are Accept and a User-Agent GitHub
/// requires. `protocolClasses` lets tests answer requests from fixtures (no network).
public final class UpdateClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let source: UpdateSource
    private var session: URLSession!

    public init(source: UpdateSource, protocolClasses: [AnyClass] = []) {
        self.source = source
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        config.httpAdditionalHeaders = ["User-Agent": "Vella-Updater"]
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses + (config.protocolClasses ?? []) }
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    deinit { session?.finishTasksAndInvalidate() }

    /// The latest published release (GitHub's releases/latest already skips drafts and prereleases).
    public func latest() async throws -> ReleaseInfo {
        let data: Data
        if source.apiURL.isFileURL {
            guard let local = try? Data(contentsOf: source.apiURL) else { throw UpdateError("No release file at \(source.apiURL.path)") }
            data = local
        } else {
            var request = URLRequest(url: source.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (body, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError("No answer from \(source.apiURL.host ?? "the release server")") }
            switch http.statusCode {
            case 200: break
            case 404: throw UpdateError("No published release found")
            case 403, 429: throw UpdateError("GitHub refused the update check (rate limit); try again later")
            default: throw UpdateError("The release check answered HTTP \(http.statusCode)")
            }
            data = body
        }
        do { return try ReleaseInfo.parse(data) } catch let error as ReleaseInfo.ParseError { throw UpdateError(error.description) }
    }

    /// The update to offer: the latest release when it is newer than `current`, else nil.
    public func check(current: SemanticVersion) async throws -> ReleaseInfo? {
        try await latest().offer(to: current)
    }

    /// Downloads `name` from the release's directory to `destination`.
    public func download(_ name: String, of release: ReleaseInfo, to destination: URL) async throws {
        let url = source.downloadBase(for: release).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        if url.isFileURL {
            do { try FileManager.default.copyItem(at: url, to: destination) }
            catch { throw UpdateError("Download of \(name) failed: no file at \(url.path)") }
            return
        }
        let (temporary, response): (URL, URLResponse)
        do { (temporary, response) = try await session.download(for: URLRequest(url: url)) }
        catch { throw UpdateError("Download of \(name) failed: \(error.localizedDescription)") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError("Download of \(name) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw UpdateError("Could not reach \(request.url?.host ?? "the release server"): \(error.localizedDescription)") }
    }

    // MARK: URLSessionTaskDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let der = source.anchorDER else {
            completionHandler(.performDefaultHandling, nil); return
        }
        // Test servers: the configured CA is the only root; host name and validity are still checked.
        guard let anchor = SecCertificateCreateWithData(nil, der as CFData) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

/// A downloaded release, checked and unpacked, ready to be installed.
public struct StagedUpdate: Codable, Equatable, Sendable {
    public let version: String
    /// Private working directory (the archive, SHA256SUMS and the unpacked app); removed after installing.
    public let directory: String
    /// The unpacked, verified Vella.app inside `directory`.
    public let app: String
    public let sha256: String
    public init(version: String, directory: String, app: String, sha256: String) {
        self.version = version; self.directory = directory; self.app = app; self.sha256 = sha256
    }
}

/// The downloaded app must be signed like the running one, so macOS privacy permissions (Accessibility, Microphone)
/// carry over and nobody else's code replaces Vella. The rule the installer applies at the swap (NativeInstaller),
/// checked before the app quits:
/// - certificate-signed: the same designated requirement, and the downloaded code satisfies the running app's
///   designated requirement (Security framework, strict, nested code included);
/// - ad-hoc (no certificate): the download is ad-hoc too and its signing identifier is Vella's. An ad-hoc signature
///   proves no origin; the SHA-256 from the release and HTTPS are then the only guards.
public struct IdentityCheck {
    /// `codesign --verify --deep --strict`, then "adhoc" or the designated requirement (NativeInstaller's comparison).
    public var signature: (URL) throws -> NativeInstaller.Signature = NativeInstaller.verifySignedBundle
    /// Throws unless the code at the URL satisfies the requirement text.
    public var satisfies: (URL, String) throws -> Void = IdentityCheck.codeSatisfies
    public var bundleIdentifier = "dev.vella.dictation"
    public init() {}

    static let designatedPrefix = "designated => "

    public func check(downloaded: URL, running: URL) throws {
        let current: NativeInstaller.Signature
        do { current = try signature(running) }
        catch { throw UpdateError("This Vella's own signature does not verify, so the download cannot be matched to it; reinstall with scripts/install.sh") }
        let replacement: NativeInstaller.Signature
        do { replacement = try signature(downloaded) }
        catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw UpdateError("Code signature check failed: \(detail.split(separator: "\n").first.map(String.init) ?? detail)")
        }
        let mismatch = UpdateError("The download is signed by a different identity than this Vella (\(Self.describe(replacement)), this app: \(Self.describe(current))); nothing installed")
        if current.kind == "adhoc" {
            guard replacement.kind == "adhoc" else { throw mismatch }
            do { try satisfies(downloaded, "identifier \"\(bundleIdentifier)\"") } catch { throw mismatch }
        } else {
            guard replacement == current, current.kind.hasPrefix(Self.designatedPrefix) else { throw mismatch }
            do { try satisfies(downloaded, String(current.kind.dropFirst(Self.designatedPrefix.count))) } catch { throw mismatch }
        }
    }

    static func describe(_ signature: NativeInstaller.Signature) -> String {
        if signature.kind == "adhoc" { return "ad-hoc" }
        // designated => identifier "…" and anchor apple generic and certificate leaf[subject.CN] = "Name" …
        if let range = signature.kind.range(of: #"subject\.CN\] = "([^"]*)""#, options: .regularExpression) {
            let cn = signature.kind[range].split(separator: "\"").dropFirst().first.map(String.init)
            if let cn { return cn }
        }
        // A self-signed identity: certificate root = H"<sha1>" (or leaf).
        if let range = signature.kind.range(of: #"certificate (root|leaf) = H"[0-9a-fA-F]{8}"#, options: .regularExpression) {
            return "certificate " + signature.kind[range].suffix(8)
        }
        if signature.kind.contains("anchor apple\n") || signature.kind.hasSuffix("anchor apple") { return "Apple" }
        return "another certificate"
    }

    /// SecStaticCodeCheckValidity with the requirement: all architectures, strict, nested code.
    public static func codeSatisfies(_ app: URL, _ requirementText: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw UpdateError("Cannot read the code signature of \(app.lastPathComponent)")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("Unreadable signing requirement")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError("\(app.lastPathComponent) does not satisfy the signing requirement (\(status))") }
    }
}

public enum Updater {
    /// Executables every release bundle carries (scripts/install-release.sh's list).
    public static let requiredExecutables = ["MacOS/Vella", "MacOS/VellaWorker", "MacOS/VellaStreamingWorker", "MacOS/VellaModelTool",
                                             "Helpers/VellaInstallTool"]
    public static let metallib = "Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

    /// Download the release zip and SHA256SUMS, check the SHA-256 and the archive's entries, unpack, check the bundle,
    /// its identifier and version, and verify its code signature against the running app (`runningApp`): the checks
    /// scripts/install-release.sh makes, plus the identity match. Leaves nothing behind on failure.
    public static func prepare(_ release: ReleaseInfo, client: UpdateClient, runningApp: URL, identity: IdentityCheck = IdentityCheck(),
                               log: (String) -> Void = { _ in }) async throws -> StagedUpdate {
        let directory = try makeWorkDirectory()
        do {
            let zip = directory.appendingPathComponent(release.zipName), sums = directory.appendingPathComponent("SHA256SUMS")
            try await client.download("SHA256SUMS", of: release, to: sums)
            try await client.download(release.zipName, of: release, to: zip)
            log("downloaded \(release.zipName)")
            guard let text = try? String(contentsOf: sums, encoding: .utf8), let expected = expectedSHA256(sums: text, name: release.zipName) else {
                throw UpdateError("Missing or ambiguous SHA-256 for \(release.zipName)")
            }
            let actual = try sha256(of: zip)
            guard actual == expected else { throw UpdateError("SHA-256 mismatch for \(release.zipName)") }
            log("verified SHA-256: \(actual)  \(release.zipName)")
            let listing = run("/usr/bin/zipinfo", ["-1", zip.path])
            guard listing.status == 0, archiveEntriesAreSafe(listing.output.split(whereSeparator: \.isNewline).map(String.init)) else {
                throw UpdateError("Unsafe or unexpected archive entries in \(release.zipName)")
            }
            let unpacked = directory.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else { throw UpdateError("Could not unpack \(release.zipName)") }
            let app = unpacked.appendingPathComponent("Vella.app")
            try checkBundle(app, version: release.version, bundleIdentifier: identity.bundleIdentifier)
            try identity.check(downloaded: app, running: runningApp)
            try removeQuarantine(app)
            log("verified signature: Vella.app \(release.version)")
            return StagedUpdate(version: release.version.description, directory: directory.path, app: app.path, sha256: actual)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func makeWorkDirectory() throws -> URL {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("vella-update.XXXXXX").utf8CString)
        guard let path = mkdtemp(&template) else { throw UpdateError("Could not create a temporary directory") }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// Lowercase hex SHA-256 of a file, read in 1 MB blocks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The app, its workers, model tool, installer tool and Metal library are present, and the bundle is Vella at `version`.
    public static func checkBundle(_ app: URL, version: SemanticVersion, bundleIdentifier: String = "dev.vella.dictation") throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        for file in requiredExecutables where !fm.isExecutableFile(atPath: contents.appendingPathComponent(file).path) {
            throw UpdateError("Release archive lacks Contents/\(file)")
        }
        let size = ((try? fm.attributesOfItem(atPath: contents.appendingPathComponent(metallib).path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw UpdateError("Release archive lacks the Metal library") }
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier else { throw UpdateError("Release archive does not hold Vella (\(bundleIdentifier))") }
        guard let bundled = info?["CFBundleShortVersionString"] as? String, bundled == version.description else {
            throw UpdateError("Version in app does not match the release")
        }
    }

    public static func bundleVersion(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Removes com.apple.quarantine from every file of `root`. URLSession downloads are not quarantined (only apps that
    /// opt in with LSFileQuarantineEnabled are), and the release zip carries no extended attributes; this is a guarantee,
    /// not a repair: an ad-hoc signed app must never be installed quarantined.
    public static func removeQuarantine(_ root: URL) throws {
        for path in allPaths(root) where getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 else { throw UpdateError("Could not clear quarantine on \(path)") }
        }
    }

    /// True when any file of `root` carries com.apple.quarantine.
    public static func isQuarantined(_ root: URL) -> Bool {
        allPaths(root).contains { getxattr($0, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    private static func allPaths(_ root: URL) -> [String] {
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker { paths.append((root.path as NSString).appendingPathComponent(relative)) }
        }
        return paths
    }

    /// Runs a tool to completion; output is stdout and stderr together.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
