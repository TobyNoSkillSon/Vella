import CryptoKit
import XCTest
@testable import VellaUpdate

final class VersionTests: XCTestCase {
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testParses() {
        XCTAssertEqual(v("0.3.1").description, "0.3.1")
        XCTAssertEqual(v("v0.3.1").description, "0.3.1")
        XCTAssertEqual(v("1.2.3-rc.1+abc").description, "1.2.3-rc.1+abc")
        XCTAssertTrue(v("0.3.0-ci1").isPrerelease)
        for bad in ["", "0.3", "0.3.1.2", "a.b.c", "0.3.x", "0.3.1-", "0.3.1+", "0..1", "-1.0.0", "0.3.1-rc..1", "0.3.1 beta", "01.0.0", "1.00.0"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testOrdersNumerically() {
        XCTAssertLessThan(v("0.3.0"), v("0.3.1"))
        XCTAssertLessThan(v("0.3.9"), v("0.3.10")) // not string order
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertLessThan(v("0.3.99"), v("1.0.0"))
        XCTAssertFalse(v("0.3.1") < v("0.3.1"))
        XCTAssertEqual(v("v0.3.1"), v("0.3.1"))
    }

    func testPrereleaseOrder() {
        XCTAssertLessThan(v("0.3.0-ci1"), v("0.3.0"))
        XCTAssertGreaterThan(v("0.3.1-rc.1"), v("0.3.0"))
        // SemVer 2.0 §11 example chain.
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (a, b) in zip(chain, chain.dropFirst()) { XCTAssertLessThan(v(a), v(b), "\(a) < \(b)") }
        XCTAssertEqual(v("1.0.0+build.1"), v("1.0.0+build.2")) // build metadata is ignored
    }
}

final class ReleaseTests: XCTestCase {
    let latest = #"""
        {"url":"https://api.github.com/repos/TobyNoSkillSon/Vella/releases/1","tag_name":"v0.3.1","name":"Vella 0.3.1",
         "draft":false,"prerelease":false,"created_at":"2026-09-30T10:00:00Z",
         "body":"## 0.3.1\n\n**Faster loads.** Models load in `half` the time; see [the notes](https://example.com).\n- Fixes a *crash* at quit.\n\n### Verify\n\n    gh attestation verify …",
         "assets":[{"name":"SHA256SUMS","browser_download_url":"https://x/SHA256SUMS"},{"name":"Vella-0.3.1-arm64.zip"}]}
        """#

    func testParsesGitHubRelease() throws {
        let r = try ReleaseInfo.parse(Data(latest.utf8))
        XCTAssertEqual(r.tag, "v0.3.1"); XCTAssertEqual(r.version.description, "0.3.1"); XCTAssertEqual(r.name, "Vella 0.3.1")
        XCTAssertFalse(r.draft); XCTAssertFalse(r.prerelease)
        XCTAssertEqual(r.assets, ["SHA256SUMS", "Vella-0.3.1-arm64.zip"])
        XCTAssertEqual(r.zipName, "Vella-0.3.1-arm64.zip")
    }

    func testShortNotesArePlainText() throws {
        let r = try ReleaseInfo.parse(Data(latest.utf8))
        XCTAssertEqual(r.shortNotes(), "Faster loads. Models load in half the time; see the notes.\n• Fixes a crash at quit.")
        let long = ReleaseInfo(tag: "v1.0.0", version: SemanticVersion("1.0.0")!, body: String(repeating: "word ", count: 200))
        let notes = long.shortNotes(maxCharacters: 50)
        XCTAssertLessThanOrEqual(notes.count, 51); XCTAssertTrue(notes.hasSuffix("word…"))
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data(#"{"name":"x"}"#.utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data(#"{"tag_name":"nightly"}"#.utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("not json".utf8)))
    }

    func testOffersOnlyNewerPublishedReleases() throws {
        let current = SemanticVersion("0.3.0")!
        func release(_ tag: String, draft: Bool = false, pre: Bool = false) -> ReleaseInfo {
            ReleaseInfo(tag: tag, version: SemanticVersion(tag)!, draft: draft, prerelease: pre)
        }
        XCTAssertEqual(release("v0.3.1").offer(to: current)?.tag, "v0.3.1")
        XCTAssertNil(release("v0.3.0").offer(to: current))
        XCTAssertNil(release("v0.2.0").offer(to: current))
        XCTAssertNil(release("v0.4.0", draft: true).offer(to: current))
        XCTAssertNil(release("v0.4.0", pre: true).offer(to: current))
        XCTAssertNil(release("v0.4.0-rc.1").offer(to: current)) // a prerelease version even when not flagged
        XCTAssertEqual(release("v0.3.0").offer(to: SemanticVersion("0.3.0-ci1")!)?.tag, "v0.3.0")
    }
}

final class ChecksumTests: XCTestCase {
    let digest = String(repeating: "ab", count: 32)

    func testExpectedSHA256() {
        XCTAssertEqual(expectedSHA256(sums: "\(digest)  Vella-0.3.1-arm64.zip\n", name: "Vella-0.3.1-arm64.zip"), digest)
        XCTAssertEqual(expectedSHA256(sums: "\(digest.uppercased()) *Vella-0.3.1-arm64.zip", name: "Vella-0.3.1-arm64.zip"), digest)
        XCTAssertEqual(expectedSHA256(sums: "\(String(repeating: "0", count: 64))  other.zip\n\(digest)  Vella-0.3.1-arm64.zip", name: "Vella-0.3.1-arm64.zip"), digest)
        XCTAssertNil(expectedSHA256(sums: "\(digest)  other.zip", name: "Vella-0.3.1-arm64.zip")) // missing
        XCTAssertNil(expectedSHA256(sums: "\(digest)  a.zip\n\(digest)  a.zip", name: "a.zip")) // ambiguous
        XCTAssertNil(expectedSHA256(sums: "abc  a.zip", name: "a.zip")) // not a SHA-256
        XCTAssertNil(expectedSHA256(sums: "\(String(repeating: "zz", count: 32))  a.zip", name: "a.zip"))
        XCTAssertNil(expectedSHA256(sums: "", name: "a.zip"))
    }

    func testFileHash() throws {
        let dir = try Updater.makeWorkDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f")
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) }) // spans several read blocks
        try bytes.write(to: file)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try Updater.sha256(of: file), expected)
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try Updater.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testQuarantineIsRemoved() throws {
        let dir = try Updater.makeWorkDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("A.app/Contents"); try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let file = inner.appendingPathComponent("x"); try Data("x".utf8).write(to: file)
        let value = "0081;00000000;Test;"
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        XCTAssertTrue(Updater.isQuarantined(dir.appendingPathComponent("A.app")))
        try Updater.removeQuarantine(dir.appendingPathComponent("A.app"))
        XCTAssertFalse(Updater.isQuarantined(dir.appendingPathComponent("A.app")))
    }

    func testSourceRequiresHTTPS() throws {
        XCTAssertThrowsError(try UpdateSource.fromEnvironment(["VELLA_UPDATE_API_URL": "http://127.0.0.1/latest"]))
        XCTAssertThrowsError(try UpdateSource.fromEnvironment(["VELLA_RELEASE_BASE_URL": "http://127.0.0.1/"]))
        XCTAssertThrowsError(try UpdateSource.fromEnvironment(["VELLA_RELEASE_BASE_URL": "ftp://127.0.0.1/"]))
        XCTAssertEqual(try UpdateSource.fromEnvironment(["VELLA_RELEASE_BASE_URL": "file:///tmp/release"]).baseURL?.isFileURL, true)
        let source = try UpdateSource.fromEnvironment([:])
        XCTAssertEqual(source.apiURL.absoluteString, "https://api.github.com/repos/TobyNoSkillSon/Vella/releases/latest")
        let r = ReleaseInfo(tag: "v0.3.1", version: SemanticVersion("0.3.1")!)
        XCTAssertEqual(source.downloadBase(for: r).absoluteString, "https://github.com/TobyNoSkillSon/Vella/releases/download/v0.3.1")
        let custom = try UpdateSource.fromEnvironment(["VELLA_RELEASE_BASE_URL": "https://127.0.0.1:8443/good"])
        XCTAssertEqual(custom.downloadBase(for: r).appendingPathComponent(r.zipName).absoluteString, "https://127.0.0.1:8443/good/Vella-0.3.1-arm64.zip")
    }
}

final class StateMachineTests: XCTestCase {
    let r = ReleaseInfo(tag: "v0.3.1", version: SemanticVersion("0.3.1")!)
    let s = ReleaseInfo(tag: "v0.3.2", version: SemanticVersion("0.3.2")!)

    func testHappyPath() {
        var m = UpdateMachine()
        XCTAssertNil(m.phase.menuTitle)
        XCTAssertTrue(m.handle(.checked(r))); XCTAssertEqual(m.phase, .available(r)); XCTAssertEqual(m.phase.menuTitle, "Update to 0.3.1…")
        XCTAssertTrue(m.handle(.confirmed)); XCTAssertEqual(m.phase, .downloading(r)); XCTAssertTrue(m.phase.busy)
        XCTAssertTrue(m.handle(.verified(busy: false))); XCTAssertEqual(m.phase, .installing(r))
    }

    func testWaitsUntilIdle() {
        var m = UpdateMachine(phase: .downloading(r))
        XCTAssertTrue(m.handle(.verified(busy: true))); XCTAssertEqual(m.phase, .waitingForIdle(r))
        XCTAssertFalse(m.handle(.confirmed))
        XCTAssertTrue(m.handle(.becameIdle)); XCTAssertEqual(m.phase, .installing(r))
    }

    func testFailureKeepsTheOfferAndTheReason() {
        for start in [UpdatePhase.downloading(r), .waitingForIdle(r), .installing(r)] {
            var m = UpdateMachine(phase: start)
            XCTAssertTrue(m.handle(.failed("SHA-256 mismatch")))
            XCTAssertEqual(m.phase, .available(r)); XCTAssertEqual(m.lastError, "SHA-256 mismatch")
            XCTAssertTrue(m.handle(.confirmed)); XCTAssertNil(m.lastError) // retry clears it
        }
    }

    func testChecks() {
        var m = UpdateMachine()
        m.handle(.checked(nil)); XCTAssertEqual(m.phase, .idle)
        m.handle(.checked(r)); m.handle(.checked(s)); XCTAssertEqual(m.phase, .available(s)) // a newer release replaces the offer
        m.handle(.checkFailed("offline")); XCTAssertEqual(m.phase, .available(s)) // a failed check keeps it
        m.handle(.checked(nil)); XCTAssertEqual(m.phase, .idle) // e.g. updated elsewhere
        var busy = UpdateMachine(phase: .downloading(r))
        XCTAssertFalse(busy.handle(.checked(s))); XCTAssertEqual(busy.phase, .downloading(r)) // never interrupts an update
    }

    func testRefusalKeepsTheOffer() {
        var m = UpdateMachine(phase: .available(r))
        XCTAssertTrue(m.handle(.failed("Vella is recording")))
        XCTAssertEqual(m.phase, .available(r)); XCTAssertEqual(m.lastError, "Vella is recording")
        XCTAssertEqual(m.phase.menuTitle, "Update to 0.3.1…")
        XCTAssertEqual(UpdatePhase.waitingForIdle(r).menuTitle, "Update to 0.3.1 when idle…")
    }

    func testRejectsOutOfOrderEvents() {
        var m = UpdateMachine()
        XCTAssertFalse(m.handle(.confirmed)); XCTAssertFalse(m.handle(.verified(busy: false)))
        XCTAssertFalse(m.handle(.becameIdle)); XCTAssertFalse(m.handle(.failed("x")))
        XCTAssertEqual(m.phase, .idle)
        var available = UpdateMachine(phase: .available(r))
        XCTAssertFalse(available.handle(.verified(busy: false))); XCTAssertEqual(available.phase, .available(r))
    }

    func testCheckInterval() {
        let now = Date()
        XCTAssertTrue(updateCheckDue(last: nil, now: now))
        XCTAssertFalse(updateCheckDue(last: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(updateCheckDue(last: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(updateCheckDue(last: now.addingTimeInterval(3600), now: now)) // clock went back
    }

    func testResultRoundTrip() throws {
        let dir = try Updater.makeWorkDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let result = UpdateResult(ok: false, from: "0.3.0", to: "0.3.1", message: "SHA-256 mismatch", at: 1)
        try JSONEncoder().encode(result).write(to: UpdateResult.url(support: dir))
        XCTAssertEqual(UpdateResult.take(support: dir), result)
        XCTAssertNil(UpdateResult.take(support: dir)) // read once
    }
}

/// Update traffic trusts only the system roots: no environment variable can replace them.
final class UpdateTrustTests: XCTestCase {
    func testCertificateOverrideIsIgnored() throws {
        let source = try UpdateSource.fromEnvironment(["VELLA_UPDATE_CA_CERT": "/nonexistent/ca.pem"])
        XCTAssertEqual(source.apiURL, UpdateSource.defaultAPI)
        XCTAssertNil(source.baseURL)
        // No server-trust challenge handler: URLSession's default evaluation (system roots, host name) applies.
        XCTAssertFalse(UpdateClient.instancesRespond(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))))
        XCTAssertTrue(UpdateClient.instancesRespond(to: #selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))))
    }
}

/// VellaModelTool is retired: a release without it passes the bundle check (it still ships as a stub for 1.0.x).
final class RetiredModelToolTests: XCTestCase {
    func testBundleWithoutTheModelToolPasses() throws {
        let root = try ReleaseFixture.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try ReleaseFixture.app(at: root.appendingPathComponent("Vella.app"), version: "9.9.9", sign: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/VellaModelTool").path))
        XCTAssertNoThrow(try Updater.checkBundle(app, version: try XCTUnwrap(SemanticVersion("9.9.9"))))
        XCTAssertFalse(Updater.requiredExecutables.contains("MacOS/VellaModelTool"))
    }
}

/// Invocation-path checks are separate from the retired-tool compatibility fixture.
final class StreamingAliasTests: XCTestCase {
    func testRelativeStreamingAliasPassesBundleCheckButBrokenAliasFails() throws {
        let root = try ReleaseFixture.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try ReleaseFixture.app(at: root.appendingPathComponent("Vella.app"), version: "9.9.9", sign: false)
        let alias = app.appendingPathComponent("Contents/MacOS/VellaStreamingWorker")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "VellaWorker")
        let version = try XCTUnwrap(SemanticVersion("9.9.9"))
        XCTAssertNoThrow(try Updater.checkBundle(app, version: version))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "missing-worker")
        XCTAssertThrowsError(try Updater.checkBundle(app, version: version))
    }

}
