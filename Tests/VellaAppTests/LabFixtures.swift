import XCTest
import Foundation
@testable import Vella

/// Benchmark corpora and raw reference results live in the gitignored lab
/// (`lab/overlay/` mirrors their former repository paths). Tests that need them
/// skip, rather than fail, on a checkout without the lab.
enum LabFixtures {
    /// `VELLA_LAB_DIR`, else `<checkout>/lab`, else the main checkout's lab for a linked worktree.
    static var lab: URL? {
        let fm = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["VELLA_LAB_DIR"] { return URL(fileURLWithPath: explicit) }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if fm.fileExists(atPath: cwd.appendingPathComponent("lab/overlay").path) { return cwd.appendingPathComponent("lab") }
        // A linked worktree's .git is a file: "gitdir: <main>/.git/worktrees/<name>".
        if let text = try? String(contentsOf: cwd.appendingPathComponent(".git"), encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir: ") }) {
            var main = URL(fileURLWithPath: String(line.dropFirst("gitdir: ".count)))
            while main.lastPathComponent != ".git" && main.path != "/" { main.deleteLastPathComponent() }
            let lab = main.deletingLastPathComponent().appendingPathComponent("lab")
            if fm.fileExists(atPath: lab.appendingPathComponent("overlay").path) { return lab }
        }
        return nil
    }

    /// A former repository path (e.g. `Resources/Benchmarks/v1/...`) inside `lab/overlay`, or skip.
    static func require(_ relativePath: String) throws -> URL {
        guard let lab, case let url = lab.appendingPathComponent("overlay").appendingPathComponent(relativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Lab fixture \(relativePath) is not available (lab/overlay).")
        }
        return url
    }

    /// Old per-run reference results no longer ship; skip tests of that path when none load.
    @MainActor static func requireReferences(_ library: ModelLibrary) throws {
        if library.references.isEmpty { throw XCTSkip("No bundled ReferenceResults; raw results live in lab/overlay/Resources/ReferenceResults.") }
    }
}
