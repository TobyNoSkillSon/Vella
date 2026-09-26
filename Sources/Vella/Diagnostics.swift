import Foundation
import VellaCore

/// Copy Diagnostics: runs the bundled `vella diagnose` (Contents/Helpers/vella), the same report the command prints,
/// off the main thread. The report reaches Vella's API like any client, so a dictation still goes first.
@MainActor final class DiagnosticsCopier {
    struct Report: Equatable {
        /// The whole output, issue link included: what the menu copies.
        var text: String
        /// The prefilled GitHub bug report.
        var issue: URL?
    }
    private(set) var running = false
    var helper: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vella")
    var environment: [String: String] = ProcessInfo.processInfo.environment

    /// Runs the report once at a time; `completion` runs on the main actor.
    func run(_ completion: @escaping @MainActor (Result<Report, Error>) -> Void) {
        guard !running else { return }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            completion(.failure(VellaError.message("The vella command is missing from this copy of Vella; reinstall it to copy diagnostics.")))
            return
        }
        running = true
        // Never let the report start a second Vella.
        let environment = self.environment.merging(["VELLA_NO_LAUNCH": "1"]) { $1 }
        Task { @MainActor in
            let result = await Task.detached { Result { try Self.execute(helper, environment: environment) } }.value
            self.running = false
            completion(result)
        }
    }

    nonisolated static func execute(_ helper: URL, environment: [String: String]) throws -> Report {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = helper
        process.arguments = ["diagnose"]
        process.environment = environment
        process.standardOutput = out; process.standardError = err
        try process.run()
        // Both outputs are a screen at most, far below a pipe's buffer: reading one after the other cannot stall.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw VellaError.message(message.isEmpty ? "vella diagnose failed (exit \(process.terminationStatus))." : message)
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The output as copied, and the issue link from its last line.
    nonisolated static func parse(_ output: String) -> Report {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = text.components(separatedBy: "\n").last { $0.contains(Diagnose.repository + "/issues/new") }
        let issue = link.flatMap { line in line.range(of: "https://").flatMap { URL(string: String(line[$0.lowerBound...])) } }
        return Report(text: text, issue: issue)
    }
}
