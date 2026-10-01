import CryptoKit
import XCTest
import VellaTestSupport

/// The app must carry Vella's LICENSE and NOTICE and the licences of every linked package and adapted source
/// (THIRD_PARTY_NOTICES.md, written by scripts/third-party-notices.sh), and build.sh must ship them.
final class NoticesTests: XCTestCase {
    static let root = Repository.root
    func text(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }
    /// Trailing whitespace is not content (the generator strips it).
    func normalized(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed()) }
            .joined(separator: "\n")
    }
    var checkouts: URL { Self.root.appendingPathComponent("Worker/.build/checkouts") }

    func testNoticeNamesVellaAndTheAdaptedCode() throws {
        let notice = try text("NOTICE")
        XCTAssertTrue(notice.hasPrefix("Vella\n"), notice)
        for credit in [
            "mlx-audio-swift", "01dec7c9bdce3088a6b6b7ab9f2e403458195efb", "Prince Canuma", "mlx-audio 0.5.1", "mlx-whisper",
            "LibriSpeech", "THIRD_PARTY_NOTICES.md", "bundles no model weights", "AGPL-3.0-only",
            "Published 0.x releases remain Apache-2.0", "MLX logo", "Copyright © 2023 Apple Inc."
        ] {
            XCTAssertTrue(notice.contains(credit), credit)
        }
        let licence = try Data(contentsOf: Self.root.appendingPathComponent("LICENSE"))
        let hash = SHA256.hash(data: licence).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0", "canonical GNU text, verbatim")
        XCTAssertTrue(try text("LICENSE").contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
    }

    func testThirdPartyNoticesCoverEveryResolvedPackage() throws {
        let notices = try text("THIRD_PARTY_NOTICES.md")
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("Worker/Package.resolved"))) as? [String: Any]
        let pins = try XCTUnwrap(resolved?["pins"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(pins.count, 10)
        for pin in pins {
            let identity = try XCTUnwrap(pin["identity"] as? String)
            let revision = try XCTUnwrap((pin["state"] as? [String: Any])?["revision"] as? String)
            XCTAssertTrue(notices.contains("- package: \(identity) "), identity)
            XCTAssertTrue(notices.contains(revision), "\(identity) at the pinned revision \(revision)")
        }
        // MIT/BSD/zlib copyright lines must be reproduced, including code MLX vendors; the Runtime Library Exception kept.
        for line in [
            "Copyright (c) 2023 ml-explore", "Copyright (c) 2024 ml-explore", "Copyright © 2023 Apple Inc.", "Niels Lohmann",
            "Victor Zverovich", "Max-Planck-Society", "Jakob Progsch", "NVIDIA Corporation", "YaoYuan",
            "Runtime Library Exception", "The SwiftCrypto Project",
            "Copyright © 2018 the V8 project authors.", "Copyright (c) 2015-2023 Norbert Juffa",
            "SPDX-FileCopyrightText: 2009 Florian Loitsch", "Copyright (c) 2009 Florian Loitsch",
            "SPDX-FileCopyrightText: 2008-2009 Björn Hoehrmann", "SPDX-FileCopyrightText: 2016-2021 Evan Nemerson",
            "SPDX-FileCopyrightText: 2018 The Abseil Authors",
            // Adapted into Worker/Sources.
            "Copyright (c) 2025 Prince Canuma", "Copyright (c) 2024 Prince Canuma"
        ] {
            XCTAssertTrue(notices.contains(line), line)
        }
    }

    /// The licence files of the adapted code (Worker/LICENSE-*) and the audio licences are reproduced or referenced.
    func testAdaptedCodeAndAudioAreCovered() throws {
        let notices = normalized(try text("THIRD_PARTY_NOTICES.md"))
        for file in ["Worker/LICENSE-mlx-audio-swift", "Worker/LICENSE-mlx-audio-python", "Worker/LICENSE-mlx-whisper"] {
            let body = normalized(try text(file)).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(notices.contains(body), "\(file) is not reproduced verbatim; rerun scripts/third-party-notices.sh")
        }
        for clip in ["5142-36377-0000", "672-122797-0073", "61-70968-0021", "6930-75918-0000", "121-127105-0022", "260-123286-0000"] {
            XCTAssertTrue(notices.contains(clip), clip)
        }
        let attribution = try text("Worker/Sources/VellaWorker/Resources/ATTRIBUTION.md")
        for clip in ["5142-36377-0000", "672-122797-0073", "61-70968-0021", "6930-75918-0000", "121-127105-0022"] {
            XCTAssertTrue(attribution.contains(clip), "the self-test clips named in the notices are the bundled ones: \(clip)")
        }
        XCTAssertFalse(attribution.contains("Resources/Benchmarks"), "the attribution names no path that is not in the repository")
    }

    /// The MLX logo (the Models table's Standard-row icon, from ml-explore/mlx, MIT): its source, its licence verbatim, and
    /// build.sh and the release archive ship both files.
    func testTheMLXLogoIsCreditedAndShipped() throws {
        let notices = normalized(try text("THIRD_PARTY_NOTICES.md"))
        XCTAssertTrue(notices.contains("### MLX logo"))
        XCTAssertTrue(notices.contains("https://github.com/ml-explore/mlx/blob/9c3d35571ac450a8ecf5c17b4d0e3fac52c08bc8/docs/logo/mlx_logo_dark.svg"))
        let licence = normalized(try text("Resources/LICENSE-mlx")).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(licence.hasPrefix("MIT License\n\nCopyright \u{00a9} 2023 Apple Inc."))
        XCTAssertTrue(notices.contains(licence), "Resources/LICENSE-mlx is not reproduced verbatim; rerun scripts/third-party-notices.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Resources/mlx-logo.pdf").path))
        XCTAssertTrue(try text("scripts/build.sh").contains("cp Resources/mlx-logo.pdf Resources/LICENSE-mlx \"$APP/Contents/Resources/\""))
        XCTAssertTrue(try text("scripts/package-release.sh").contains("Resources/mlx-logo.pdf Resources/LICENSE-mlx"))
    }

    /// Every catalog model is listed with its catalog licence and its download repositories.
    func testEveryCatalogModelIsListed() throws {
        let notices = try text("THIRD_PARTY_NOTICES.md")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("Resources/models.json"))) as? [String: Any]
        let families = try XCTUnwrap(catalog?["families"] as? [[String: Any]])
        for family in families {
            let name = try XCTUnwrap(family["name"] as? String), licence = try XCTUnwrap(family["license"] as? String)
            let row = try XCTUnwrap(notices.split(separator: "\n").first { $0.hasPrefix("| \(name) |") }, "\(name) has no row; rerun scripts/third-party-notices.sh")
            XCTAssertTrue(row.contains("| \(licence) |"), "\(name): \(row)")
            for variant in (family["variants"] as? [String: [String: Any]] ?? [:]).values {
                if let repository = variant["repository"] as? String, !repository.isEmpty { XCTAssertTrue(row.contains("`\(repository)`"), repository) }
            }
        }
    }

    /// When the pinned checkouts are present (any built Worker), each licence file is in the notices verbatim.
    func testNoticesMatchTheCheckouts() throws {
        guard FileManager.default.fileExists(atPath: checkouts.appendingPathComponent("mlx-swift/LICENSE").path) else {
            throw XCTSkip("no Worker/.build/checkouts (run swift package resolve --package-path Worker)")
        }
        let notices = normalized(try text("THIRD_PARTY_NOTICES.md"))
        for file in [
            "mlx-swift/LICENSE", "mlx-swift/Source/Cmlx/mlx/LICENSE", "mlx-swift/Source/Cmlx/mlx-c/LICENSE",
            "mlx-swift/Source/Cmlx/fmt/LICENSE", "mlx-swift/Source/Cmlx/json/LICENSE.MIT", "mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt",
            "swift-numerics/LICENSE.txt", "mlx-swift-lm/LICENSE", "swift-transformers/LICENSE", "swift-jinja/LICENSE", "yyjson/LICENSE",
            "swift-collections/LICENSE.txt", "swift-crypto/NOTICE.txt", "swift-crypto/LICENSE.txt", "swift-asn1/NOTICE.txt",
            "swift-asn1/LICENSE.txt", "swift-syntax/LICENSE.txt"
        ] {
            let licence = try String(contentsOf: checkouts.appendingPathComponent(file), encoding: .utf8)
            let body = normalized(licence).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(notices.contains(body), "\(file) is not reproduced verbatim; rerun scripts/third-party-notices.sh")
        }
    }

    /// Every copyright holder named in a vendored C, C++ or Metal source of the pinned checkouts
    /// (MLX, mlx-c, fmt, nlohmann/json, metal-cpp, the generated JIT kernels, yyjson) is named in the notices. Apple's
    /// own headers are covered by the package licences. Tests, fuzzers and docs are not compiled and are skipped.
    func testEveryVendoredCopyrightHolderIsInTheNotices() throws {
        guard FileManager.default.fileExists(atPath: checkouts.appendingPathComponent("mlx-swift/Source/Cmlx").path) else {
            throw XCTSkip("no Worker/.build/checkouts (run swift package resolve --package-path Worker)")
        }
        // fmt's LICENSE writes "{fmt} contributors", its headers "fmt contributors".
        let notices = try text("THIRD_PARTY_NOTICES.md").replacingOccurrences(of: "{fmt}", with: "fmt")
        // "Copyright (c) 2012 - present, Victor Zverovich" → "Victor Zverovich"; also SPDX-FileCopyrightText lines.
        let line = try NSRegularExpression(pattern: #"(?:Copyright\s*(?:©|\([cC]\)|@)?\s*(?=\d)|SPDX-FileCopyrightText:\s*)([^<\n]*)"#)
        let lead = try NSRegularExpression(pattern: #"^[\d\s,\-–]*(?:present,?\s*)?"#)
        let skipped = ["/test/", "/tests/", "/docs/", "/doc/", "/benchmarks/", "/examples/", "/python/", "/backend/cuda/"]
        var missing: [String: String] = [:], scanned = 0
        for tree in ["mlx-swift/Source/Cmlx", "yyjson/src"] {
            // Resolved paths on both sides, so a symlinked checkouts directory still gives correct relative paths.
            let base = checkouts.appendingPathComponent(tree).resolvingSymlinksInPath()
            let files = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in files where ["h", "hpp", "c", "cc", "cpp", "metal", "m", "mm"].contains(url.pathExtension) {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(base.path + "/") else { continue }
                let rel = tree + "/" + path.dropFirst(base.path.count + 1)
                if skipped.contains(where: rel.contains) { continue }
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                for m in line.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    var holder = String(source[Range(m.range(at: 1), in: source)!])
                    holder = lead.stringByReplacingMatches(in: holder, range: NSRange(holder.startIndex..., in: holder), withTemplate: "")
                    holder = holder.replacingOccurrences(of: "All rights reserved.", with: "").replacingOccurrences(of: "{fmt}", with: "fmt")
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,")))
                    if holder.isEmpty || holder.hasPrefix("Apple") || notices.contains(holder) { continue }
                    missing[holder] = missing[holder] ?? rel
                }
            }
        }
        XCTAssertGreaterThan(scanned, 300, "the scan found the vendored sources")
        XCTAssertEqual(missing, [:], "copyright holders absent from THIRD_PARTY_NOTICES.md (add them to scripts/third-party-notices.sh)")
    }

    /// build.sh copies the three files into Contents/Resources, and the release archive check requires them.
    func testBuildShipsTheNotices() throws {
        XCTAssertTrue(try text("scripts/build.sh").contains("cp LICENSE NOTICE THIRD_PARTY_NOTICES.md \"$APP/Contents/Resources/\""))
        let package = try text("scripts/package-release.sh")
        for f in ["Resources/LICENSE", "Resources/NOTICE", "Resources/THIRD_PARTY_NOTICES.md"] { XCTAssertTrue(package.contains(f), f) }
    }
}
