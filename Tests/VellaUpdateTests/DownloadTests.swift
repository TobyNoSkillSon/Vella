import Foundation
import XCTest
import VellaCore
@testable import VellaUpdate

/// Check, download and verification against the fake release server (no network).
final class DownloadTests: XCTestCase {
    var root: URL!
    var running: URL!

    override func setUpWithError() throws {
        FakeReleaseServer.reset()
        root = try ReleaseFixture.temporaryRoot()
        running = try ReleaseFixture.app(at: root.appendingPathComponent("installed/Vella.app"), version: "1.0.0")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        XCTAssertTrue(FakeReleaseServer.requested.allSatisfy { $0.hasPrefix("https://releases.invalid/") }, "only the fake server is asked")
        FakeReleaseServer.reset()
    }

    private func prepare(_ release: ReleaseInfo, identity: IdentityCheck = IdentityCheck()) async throws -> StagedUpdate {
        try await Updater.prepare(release, client: ReleaseFixture.client(), runningApp: running, identity: identity)
    }

    /// Runs `body`, expecting an UpdateError whose message contains `text`, and no work directory left behind.
    private func assertRefused(_ text: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        let before = ReleaseFixture.workDirectories()
        do { try await body(); XCTFail("expected a refusal: \(text)", file: file, line: line) } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), "\(error.localizedDescription)", file: file, line: line)
        }
        XCTAssertEqual(ReleaseFixture.workDirectories().subtracting(before), [], "nothing left behind", file: file, line: line)
    }

    func testCheckOffersANewerRelease() async throws {
        FakeReleaseServer.serve(ReleaseFixture.api, ReleaseFixture.releaseJSON("v1.0.1"))
        let offer = try await ReleaseFixture.client().check(current: SemanticVersion("1.0.0")!)
        XCTAssertEqual(offer?.tag, "v1.0.1"); XCTAssertEqual(offer?.zipName, "Vella-1.0.1-arm64.zip")
        let none = try await ReleaseFixture.client().check(current: SemanticVersion("1.0.1")!)
        XCTAssertNil(none)
        XCTAssertEqual(FakeReleaseServer.requested, [ReleaseFixture.api, ReleaseFixture.api])
    }

    func testCheckFailuresAreWords() async {
        for (status, text) in [(404, "No published release found"), (403, "rate limit"), (500, "HTTP 500")] {
            FakeReleaseServer.serve(ReleaseFixture.api, Data(), status: status)
            do { _ = try await ReleaseFixture.client().latest(); XCTFail("\(status)") } catch {
                XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
            }
        }
    }

    func testPreparesAVerifiedRelease() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root)
        let staged = try await prepare(release)
        defer { try? FileManager.default.removeItem(atPath: staged.directory) }
        XCTAssertEqual(staged.version, "1.0.1")
        XCTAssertEqual(Updater.bundleVersion(URL(fileURLWithPath: staged.app)), "1.0.1")
        XCTAssertFalse(Updater.isQuarantined(URL(fileURLWithPath: staged.app)))
        XCTAssertEqual(URL(fileURLWithPath: staged.app).lastPathComponent, "Vella.app")
        XCTAssertEqual(FakeReleaseServer.requested, ["\(ReleaseFixture.base)/SHA256SUMS", "\(ReleaseFixture.base)/Vella-1.0.1-arm64.zip"])
    }

    func testTamperedChecksumInstallsNothing() async throws {
        let wrong = Data("\(String(repeating: "0", count: 64))  Vella-1.0.1-arm64.zip\n".utf8)
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root, sums: wrong)
        await assertRefused("SHA-256 mismatch for Vella-1.0.1-arm64.zip") { _ = try await self.prepare(release) }
    }

    func testMissingOrAmbiguousChecksumInstallsNothing() async throws {
        let digest = String(repeating: "a", count: 64)
        for sums in ["\(digest)  other.zip\n", "\(digest)  Vella-1.0.1-arm64.zip\n\(digest)  Vella-1.0.1-arm64.zip\n", ""] {
            let release = try ReleaseFixture.publish(version: "1.0.1", root: root, sums: Data(sums.utf8))
            await assertRefused("Missing or ambiguous SHA-256") { _ = try await self.prepare(release) }
        }
    }

    func testMissingAssetInstallsNothing() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root)
        FakeReleaseServer.serve("\(ReleaseFixture.base)/Vella-1.0.1-arm64.zip", Data(), status: 404)
        await assertRefused("Download of Vella-1.0.1-arm64.zip failed (HTTP 404)") { _ = try await self.prepare(release) }
    }

    /// A file changed after signing, re-zipped with a matching checksum: the hash passes, the signature does not.
    func testModifiedAppFailsTheSignatureCheck() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root) { app in
            try ReleaseFixture.app(at: app, version: "1.0.1")
            try Data("patched".utf8).write(to: app.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"))
        }
        await assertRefused("Code signature check failed") { _ = try await self.prepare(release) }
    }

    func testUnsignedAppIsRefused() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root) { try ReleaseFixture.app(at: $0, version: "1.0.1", sign: false) }
        await assertRefused("Code signature check failed") { _ = try await self.prepare(release) }
    }

    /// Ad-hoc signed like this app but under another signing identifier: an identity mismatch.
    func testOtherSigningIdentifierIsAnIdentityMismatch() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root) {
            try ReleaseFixture.app(at: $0, version: "1.0.1", signingIdentifier: "com.example.other")
        }
        await assertRefused("signed by a different identity") { _ = try await self.prepare(release) }
    }

    /// This app certificate-signed, the download ad-hoc: refused before anything is unpacked into place.
    func testCertificateSignedAppRefusesAnAdHocDownload() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root)
        var identity = IdentityCheck()
        let running = self.running!
        identity.signature = { url in
            if url.standardizedFileURL == running.standardizedFileURL {
                return .init(#"designated => identifier "dev.vella.dictation" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Vella""#)
            }
            return try NativeInstaller.verifySignedBundle(url)
        }
        await assertRefused("signed by a different identity than this Vella (ad-hoc, this app: Apple Development: Vella)") {
            _ = try await self.prepare(release, identity: identity)
        }
    }

    func testWrongVersionOrIdentifierIsRefused() async throws {
        let older = try ReleaseFixture.publish(version: "1.0.1", root: root) { try ReleaseFixture.app(at: $0, version: "1.0.0") }
        await assertRefused("Version in app does not match the release") { _ = try await self.prepare(older) }
        let other = try ReleaseFixture.publish(version: "1.0.1", root: root) { try ReleaseFixture.app(at: $0, version: "1.0.1", identifier: "com.example.app") }
        await assertRefused("does not hold Vella") { _ = try await self.prepare(other) }
    }

    func testIncompleteAppIsRefused() async throws {
        let release = try ReleaseFixture.publish(version: "1.0.1", root: root) { app in
            try ReleaseFixture.app(at: app, version: "1.0.1", sign: false)
            try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/VellaStreamingWorker"))
        }
        await assertRefused("Release archive lacks Contents/MacOS/VellaStreamingWorker") { _ = try await self.prepare(release) }
    }

    func testArchiveWithAnythingBesidesTheAppIsRefused() async throws {
        let staging = root.appendingPathComponent("extra")
        try ReleaseFixture.app(at: staging.appendingPathComponent("Vella.app"), version: "1.0.1")
        try Data("x".utf8).write(to: staging.appendingPathComponent("README"))
        let zip = staging.appendingPathComponent("z.zip")
        XCTAssertEqual(Updater.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", staging.path, zip.path]).status, 0)
        let bytes = try Data(contentsOf: zip)
        FakeReleaseServer.serve("\(ReleaseFixture.base)/Vella-1.0.1-arm64.zip", bytes)
        FakeReleaseServer.serve("\(ReleaseFixture.base)/SHA256SUMS", ReleaseFixture.sums([("Vella-1.0.1-arm64.zip", bytes)]))
        await assertRefused("Unsafe or unexpected archive entries") {
            _ = try await self.prepare(ReleaseInfo(tag: "v1.0.1", version: SemanticVersion("1.0.1")!))
        }
    }

    func testArchiveEntryRules() {
        XCTAssertTrue(archiveEntriesAreSafe(["Vella.app/", "Vella.app/Contents/", "Vella.app/Contents/Info.plist"]))
        XCTAssertFalse(archiveEntriesAreSafe([]))
        XCTAssertFalse(archiveEntriesAreSafe(["Vella.app/", "Other.app/x"]))
        XCTAssertFalse(archiveEntriesAreSafe(["Vella.app/../evil"]))
        XCTAssertFalse(archiveEntriesAreSafe(["Vella.app/Contents/._Info.plist"]))
        XCTAssertFalse(archiveEntriesAreSafe(["__MACOSX/Vella.app/x"]))
        XCTAssertFalse(archiveEntriesAreSafe(["Vella.app\\x"]))
        XCTAssertFalse(archiveEntriesAreSafe(["Vella.appx/y"]))
        XCTAssertFalse(archiveEntriesAreSafe(Array(repeating: "Vella.app/x", count: 20_001)))
    }
}

/// The signing-identity rule on its own: real Security framework checks on ad-hoc fixtures, and the certificate
/// cases with the signature reader replaced.
final class IdentityTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = try ReleaseFixture.temporaryRoot() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testRequirementCheckUsesTheRealSignature() throws {
        let app = try ReleaseFixture.app(at: root.appendingPathComponent("a/Vella.app"), version: "1.0.0")
        XCTAssertNoThrow(try IdentityCheck.codeSatisfies(app, #"identifier "dev.vella.dictation""#))
        XCTAssertThrowsError(try IdentityCheck.codeSatisfies(app, #"identifier "com.example.other""#))
        XCTAssertThrowsError(try IdentityCheck.codeSatisfies(app, "anchor apple generic")) // ad-hoc has no certificate
        XCTAssertEqual(try NativeInstaller.verifySignedBundle(app), .init("adhoc"))
    }

    func testAdHocMatchesAdHocWithVellasIdentifier() throws {
        let running = try ReleaseFixture.app(at: root.appendingPathComponent("a/Vella.app"), version: "1.0.0")
        let download = try ReleaseFixture.app(at: root.appendingPathComponent("b/Vella.app"), version: "1.0.1")
        XCTAssertNoThrow(try IdentityCheck().check(downloaded: download, running: running))
    }

    func testCertificatePolicy() throws {
        let dr = #"designated => identifier "dev.vella.dictation" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: A""#
        let other = #"designated => identifier "dev.vella.dictation" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: B""#
        let running = URL(fileURLWithPath: "/running/Vella.app"), download = URL(fileURLWithPath: "/download/Vella.app")
        func check(running r: String, download d: String, satisfied: Bool = true) throws {
            var identity = IdentityCheck()
            var asked: [String] = []
            identity.signature = { $0 == running ? .init(r) : .init(d) }
            identity.satisfies = { _, requirement in
                asked.append(requirement); if !satisfied { throw UpdateError("no") }
            }
            try identity.check(downloaded: download, running: running)
            if r != "adhoc" { XCTAssertEqual(asked, [String(dr.dropFirst("designated => ".count))]) }
        }
        XCTAssertNoThrow(try check(running: dr, download: dr))
        XCTAssertThrowsError(try check(running: dr, download: other)) { XCTAssertTrue($0.localizedDescription.contains("(Apple Development: B, this app: Apple Development: A)")) }
        XCTAssertThrowsError(try check(running: dr, download: "adhoc"))
        XCTAssertThrowsError(try check(running: "adhoc", download: dr))
        // Same requirement text, but the code does not satisfy it (a copied requirement on someone else's certificate).
        XCTAssertThrowsError(try check(running: dr, download: dr, satisfied: false)) { XCTAssertTrue($0.localizedDescription.contains("different identity")) }
    }

    /// The certificate path end to end on real certificate-signed code (macOS's own apps): the same designated
    /// requirement matches and is satisfied; another app's requirement is a mismatch.
    func testCertificatePathOnSystemApps() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app"), chess = URL(fileURLWithPath: "/System/Applications/Chess.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path) && FileManager.default.fileExists(atPath: chess.path))
        var identity = IdentityCheck()
        identity.bundleIdentifier = "com.apple.calculator"
        XCTAssertNoThrow(try identity.check(downloaded: calculator, running: calculator))
        XCTAssertThrowsError(try identity.check(downloaded: chess, running: calculator)) {
            XCTAssertTrue($0.localizedDescription.contains("signed by a different identity"))
        }
        XCTAssertNoThrow(try IdentityCheck.codeSatisfies(chess, "anchor apple"))
        XCTAssertThrowsError(try IdentityCheck.codeSatisfies(chess, #"identifier "com.apple.calculator" and anchor apple"#))
    }

    func testDescribesSelfSignedIdentities() {
        XCTAssertEqual(
            IdentityCheck.describe(.init(#"designated => identifier "dev.vella.dictation" and certificate root = H"0a1b2c3d4e5f60718293a4b5c6d7e8f901234567""#)),
            "certificate 0a1b2c3d")
        XCTAssertEqual(IdentityCheck.describe(.init("adhoc")), "ad-hoc")
    }

    func testUnverifiableRunningAppSaysSo() throws {
        var identity = IdentityCheck()
        identity.signature = { url in
            if url.path.hasPrefix("/running") { throw NativeInstallError.message("broken") }; return .init("adhoc")
        }
        XCTAssertThrowsError(try identity.check(downloaded: URL(fileURLWithPath: "/d/Vella.app"), running: URL(fileURLWithPath: "/running/Vella.app"))) {
            XCTAssertTrue($0.localizedDescription.contains("This Vella's own signature does not verify"))
        }
    }
}
