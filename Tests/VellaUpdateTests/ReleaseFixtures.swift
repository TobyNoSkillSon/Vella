import Foundation
import XCTest
import VellaCore
@testable import VellaUpdate

/// A fake release server: URLSession requests are answered from `routes` (URL → status and body) and never leave
/// the process. Anything not routed answers 404, so a test can never reach the real GitHub.
final class FakeReleaseServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { routes = [:]; requests = [] } }
    static func serve(_ url: String, _ body: Data, status: Int = 200) { lock.withLock { routes[url] = (status, body) } }
    static var requested: [String] { lock.withLock { requests } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let route = Self.lock.withLock { () -> (status: Int, body: Data)? in
            Self.requests.append(url.absoluteString); return Self.routes[url.absoluteString]
        }
        let (status, body) = route ?? (404, Data("not found".utf8))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Release fixtures built like scripts/build.sh and scripts/package-release.sh lay them out: a Vella.app with every
/// executable (copies of /usr/bin/true), the Metal library, an Info.plist, ad-hoc signed inside out; zipped without
/// extended attributes; SHA256SUMS in `shasum -a 256` format.
enum ReleaseFixture {
    static let api = "https://releases.invalid/latest"
    static let base = "https://releases.invalid/download"

    static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-update-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    static func app(at app: URL, version: String, identifier: String = "dev.vella.dictation", signingIdentifier: String? = nil,
                    sign: Bool = true) throws -> URL {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        for file in Updater.requiredExecutables {
            let path = contents.appendingPathComponent(file)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: path)
        }
        let metallib = contents.appendingPathComponent(Updater.metallib)
        try fm.createDirectory(at: metallib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture shader".utf8).write(to: metallib)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Vella", "CFBundleName": "Vella",
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        guard sign else { return app }
        let helpers = Updater.requiredExecutables.filter { $0 != "MacOS/Vella" }.map { contents.appendingPathComponent($0).path }
        try codesign(["--force", "--sign", "-"] + helpers)
        try codesign(["--force", "--sign", "-"] + (signingIdentifier.map { ["--identifier", $0] } ?? []) + [app.path])
        return app
    }

    static func codesign(_ arguments: [String]) throws {
        let result = Updater.run("/usr/bin/codesign", arguments)
        guard result.status == 0 else { throw UpdateError("codesign failed: \(result.output)") }
    }

    /// Zips `app` as release-zip.sh does and returns the archive's bytes.
    static func zip(_ app: URL, name: String, in directory: URL) throws -> Data {
        let zip = directory.appendingPathComponent(name)
        let result = Updater.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", app.path, zip.path])
        guard result.status == 0 else { throw UpdateError("ditto failed: \(result.output)") }
        return try Data(contentsOf: zip)
    }

    static func sums(_ entries: [(String, Data)]) -> Data {
        Data(entries.map { "\(sha($0.1))  \($0.0)\n" }.joined().utf8)
    }
    static func sha(_ data: Data) -> String {
        let dir = try! Updater.makeWorkDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f"); try! data.write(to: file)
        return try! Updater.sha256(of: file)
    }

    static func releaseJSON(_ tag: String, body: String = "Faster loads.") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "name": "Vella \(tag)", "draft": false, "prerelease": false, "body": body,
                                                     "assets": [["name": "SHA256SUMS"], ["name": "Vella-\(tag.dropFirst())-arm64.zip"]]])
    }

    /// Serves release `version` (an app built by `build`) with a correct or custom SHA256SUMS.
    static func publish(version: String, root: URL, sums custom: Data? = nil, build: ((URL) throws -> Void)? = nil) throws -> ReleaseInfo {
        let staging = root.appendingPathComponent("release-\(UUID().uuidString)")
        let app = staging.appendingPathComponent("Vella.app")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        if let build { try build(app) } else { try Self.app(at: app, version: version) }
        let name = "Vella-\(version)-arm64.zip"
        let zip = try zip(app, name: name, in: staging)
        FakeReleaseServer.serve(api, releaseJSON("v\(version)"))
        FakeReleaseServer.serve("\(base)/\(name)", zip)
        FakeReleaseServer.serve("\(base)/SHA256SUMS", custom ?? sums([(name, zip)]))
        return ReleaseInfo(tag: "v\(version)", version: SemanticVersion(version)!)
    }

    static func client() -> UpdateClient {
        UpdateClient(source: UpdateSource(apiURL: URL(string: api)!, baseURL: URL(string: base)!), protocolClasses: [FakeReleaseServer.self])
    }

    /// Work directories the updater left in the temporary directory.
    static func workDirectories() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("vella-update.") })
    }
}
