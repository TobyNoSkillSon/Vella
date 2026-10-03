import Darwin
import Foundation

/// Stderr is only an output destination. Consent depends on the explicit flag and real terminal input.
public enum SigningMigrationConsent {
    public static func authorize(flag: Bool, stdinFD: Int32 = STDIN_FILENO, retryCommand: String = "scripts/install.sh --migrate-signing", report: (String) -> Void) throws {
        guard flag else { throw NativeInstallError.signingMigrationRequired(NativeInstaller.migrationExplanation + " Nothing changed. To opt in, run: \(retryCommand)") }
        report(NativeInstaller.migrationExplanation + "\n")
        guard isatty(stdinFD) != 0 else {
            report("Signing migration authorized by --migrate-signing.\n")
            return
        }
        report("Migrate the signing identity now? [y/N] ")
        let input = FileHandle(fileDescriptor: stdinFD, closeOnDealloc: false)
        defer { report("\n") }
        var bytes = Data()
        while bytes.count < 16 {
            guard let byte = try? input.read(upToCount: 1), !byte.isEmpty else { break }
            if byte.first == 10 || byte.first == 13 {
                let answer = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if answer == "y" || answer == "yes" { return }
                break
            }
            bytes.append(byte)
        }
        throw NativeInstallError.message("Signing migration declined; existing app and data unchanged. Re-run: \(retryCommand)")
    }
}
