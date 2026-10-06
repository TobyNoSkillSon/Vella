import XCTest
import VellaTestSupport

/// The public documents: community files, the standalone installer and benchmark kit, and what they must not contain.
final class DocsTests: XCTestCase {
    static let root = Repository.root
    func text(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(path).path) }
    var version: String {
        get throws {
            let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist")))
            return try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        }
    }

    func testCommunityFilesExist() {
        for path in [
            "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SECURITY.md", "CHANGELOG.md",
            ".github/ISSUE_TEMPLATE/bug_report.yml", ".github/ISSUE_TEMPLATE/feature_request.yml",
            ".github/ISSUE_TEMPLATE/new_model.yml", ".github/ISSUE_TEMPLATE/config.yml",
            ".github/pull_request_template.md", ".github/FUNDING.yml", ".github/CODEOWNERS"
        ] {
            XCTAssertTrue(exists(path), path)
        }
        XCTAssertFalse(exists("BENCHMARKS.md"), "the benchmark table lives in the README")
    }

    /// The bug form asks for `vella diagnose`, with the field ids the prefilled issue link fills in.
    func testBugFormAsksForDiagnose() throws {
        let form = try text(".github/ISSUE_TEMPLATE/bug_report.yml")
        XCTAssertTrue(form.contains("`vella diagnose`"))
        for id in ["id: diagnose", "id: chip", "id: macos", "id: version", "id: what-happened"] { XCTAssertTrue(form.contains(id), id) }
        let config = try text(".github/ISSUE_TEMPLATE/config.yml")
        XCTAssertTrue(config.contains("blank_issues_enabled: false"))
        XCTAssertTrue(config.contains("https://github.com/TobyNoSkillSon/Vella/security/advisories/new"))
        XCTAssertTrue(try text("SECURITY.md").contains("https://github.com/TobyNoSkillSon/Vella/security/advisories/new"))
        XCTAssertTrue(try text("CODE_OF_CONDUCT.md").contains("https://github.com/TobyNoSkillSon/Vella/security/advisories/new"))
    }

    /// FUNDING.yml names the same GitHub Sponsors account as the README's Support button and the app's Support item.
    func testFundingMatchesTheSupportLink() throws {
        XCTAssertEqual(try text(".github/FUNDING.yml"), "github: [TobyNoSkillSon]\n")
        XCTAssertTrue(try text("README.md").contains("https://github.com/sponsors/TobyNoSkillSon"))
        XCTAssertTrue(try text("Sources/Vella/App/AppDelegate.swift").contains("https://github.com/sponsors/TobyNoSkillSon"))
    }

    /// The standalone installer (the raw GitHub URL) installs this version's prebuilt release with the repository installer's
    /// checks, from main() so a truncated download runs nothing; it never builds from source or needs Python.
    func testPublicInstallerInstallsThisRelease() throws {
        let pages = try text("scripts/install-public.sh")
        XCTAssertTrue(pages.contains("VERSION=\"${VELLA_VERSION:-\(try version)}\""), "scripts/install-public.sh installs the version in Info.plist")
        XCTAssertTrue(pages.hasSuffix("main \"$@\"\n"))
        let release = try text("scripts/install-release.sh"), prepared = try text("scripts/install-prepared.sh")
        for step in [
            "https://github.com/TobyNoSkillSon/Vella/releases/download/v$VERSION", "ZIP=\"Vella-$VERSION-arm64.zip\"",
            "awk -v name=\"$ZIP\" '$2 == name { print $1 }' \"$TEMP/SHA256SUMS\"", "shasum -a 256 \"$TEMP/$ZIP\"",
            "$0 !~ /^Vella\\.app(\\/|$)/", "ditto -x -k \"$TEMP/$ZIP\" \"$TEMP/unpacked\"",
            "MacOS/Vella MacOS/VellaWorker MacOS/VellaStreamingWorker Helpers/VellaInstallTool",
            "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib", "Print :CFBundleShortVersionString",
            "codesign --verify --deep --strict \"$APP\"", "--proto '=https,file' --proto-redir '=https' --tlsv1.2"
        ] {
            XCTAssertTrue(release.contains(step), "scripts/install-release.sh: \(step)")
            XCTAssertTrue(pages.contains(step), "scripts/install-public.sh: \(step)")
        }
        for step in [
            "install --app \"$APP\" --destination \"$DEST\" --support \"$SUPPORT\" --keep-previous",
            "ready --app \"$DEST\" --support \"$SUPPORT\" --timeout \"${VELLA_READY_TIMEOUT:-1800}\"",
            "ln -sfn \"$DEST/Contents/Helpers/vella\" \"$BIN/vella\"", "VELLA_ACCEPT_DEGRADED"
        ] {
            XCTAssertTrue(prepared.contains(step), "scripts/install-prepared.sh: \(step)")
            XCTAssertTrue(pages.contains(step), "scripts/install-public.sh: \(step)")
        }
        for stale in ["python", "Python", "source.tar.gz", "swift build", "install_app"] { XCTAssertFalse(pages.contains(stale), stale) }
    }

    /// The legacy Pages installer and website are retired; the raw GitHub installer is canonical.
    func testRetiredPagesFilesDoNotExist() {
        for retired in ["docs/install.sh", "docs/.nojekyll", "docs/index.html", "docs/data.js", "docs/table.js", "scripts/pages-data.sh"] {
            XCTAssertFalse(exists(retired), retired)
        }
    }

    /// Every image the README and the user guide show is in the repository.
    func testDocumentImagesExist() throws {
        let image = try NSRegularExpression(pattern: #"<img src="([^"]+)""#)
        for (doc, base) in [("README.md", ""), ("docs/USAGE.md", "docs/")] {
            let body = try text(doc)
            let sources = image.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
            XCTAssertFalse(sources.isEmpty, doc)
            for source in sources where !source.hasPrefix("http") { XCTAssertTrue(exists(base + source), "\(doc): \(source)") }
        }
        XCTAssertTrue(try text("README.md").contains("docs/images/models-current.png") && text("README.md").contains("docs/images/menu-current.png"))
    }

    /// Public documents carry no local paths or internal notes.
    func testPublicDocumentsHaveNoInternalReferences() throws {
        let documents = [
            "README.md", "AGENTS.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "NOTICE",
            "THIRD_PARTY_NOTICES.md", "docs/USAGE.md", "scripts/install-public.sh",
            ".github/pull_request_template.md", ".github/ISSUE_TEMPLATE/bug_report.yml",
            ".github/ISSUE_TEMPLATE/feature_request.yml", ".github/ISSUE_TEMPLATE/new_model.yml",
            "scripts/third-party-notices.sh", "Resources/benchmarks.json"
        ]
        for path in documents {
            let body = try text(path)
            for needle in ["/Users/", "Vault/", "lab/"] {
                XCTAssertFalse(body.contains(needle), "\(path) mentions \(needle)")
            }
        }
    }

    /// The user guide's Menu section lists the family block order (VFamily menu alignment, 28 Sep 2026): header and
    /// fact line; Models, Keep Hot, Memory; the app section; agent, files, worker, login; Support, Update, Quit.
    func testUserGuideMenuFollowsTheFamilyBlockOrder() throws {
        let guide = try text("docs/USAGE.md")
        let section = try XCTUnwrap(guide.components(separatedBy: "## Menu\n").dropFirst().first?.components(separatedBy: "\n## ").first)
        let blocks = section.components(separatedBy: "\n").filter { $0.first?.isNumber == true }
        XCTAssertEqual(blocks.count, 5, section)
        let expected: [[String]] = [
            ["**Status**", "current state"],
            ["**Models…**", "**Keep Hot**", "**Memory**"],
            ["**Start Dictation**", "**Mode**", "**Microphone**", "**Shortcuts**", "**Copy Last Transcript**", "**Recover Saved Recording…**", "**Open Saved Recordings**"],
            ["**Copy Skill for Your Agent**", "**Open Vella Files**", "**Launch at Login**"],
            ["**Support the Developer…**", "**Update to X…**", "**Quit Vella**"]
        ]
        for (block, titles) in zip(blocks, expected) {
            let positions = titles.map { block.range(of: $0)?.lowerBound }
            XCTAssertFalse(positions.contains(nil), "\(titles) in \(block)")
            let found = positions.compactMap { $0 }
            XCTAssertEqual(found, found.sorted(), "order within: \(block)")
        }
    }
}
