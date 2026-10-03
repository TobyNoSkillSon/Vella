import Foundation
import VellaCore
import VellaUpdate

// install: transactional swap of a verified, prepared Vella.app; launches it; prints
//          `previous: <path>` when --keep-previous kept the old app for rollback.
// ready:   waits until the installed app reports ready (see InstallReadiness); prints `ready: …` (exit 0), or
//          `degraded: …` (exit 3) when it runs but a configured-hot model is not loaded; exit 1 when not ready.
// update:  the app's in-app update hand-off (UpdateInstaller): waits for the app to quit, installs the staged release,
//          relaunches it and rolls back when it does not become ready. Progress goes to update.log, a failure to
//          update-result.json, which the relaunched app reports.
@main struct VellaInstallTool {
    static let usage = """
        Usage: VellaInstallTool install --app <prepared Vella.app> --destination <Vella.app> --support <Vella support> [--keep-previous] [--migrate-signing]
               VellaInstallTool ready --app <installed Vella.app> --support <Vella support> [--timeout seconds] [--interval seconds] [--settle seconds]
               VellaInstallTool update --plan <plan.json>

        """
    static func value(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    static func url(_ key: String, in args: [String]) -> URL? { value(key, in: args).map { URL(fileURLWithPath: $0) } }

    static var signingRetryCommand: String {
        ProcessInfo.processInfo.environment["VELLA_INSTALL_RETRY_COMMAND"] ?? "scripts/install.sh --migrate-signing"
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        #if DEBUG
            // Tests exercise the exact tool consent dispatch with PTY/pipe descriptors; no app is touched.
            if args.first == "--signing-consent-fixture" {
                do {
                    try SigningMigrationConsent.authorize(flag: args.contains("--migrate-signing"), retryCommand: signingRetryCommand) { fputs($0, stderr) }
                    return
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
        #endif
        switch args.first {
        case "install":
            guard let app = url("--app", in: args), let destination = url("--destination", in: args),
                let support = url("--support", in: args)
            else { fputs(usage, stderr); exit(2) }
            let installer = NativeInstaller(preparedApp: app, destination: destination, support: support)
            installer.keepPrevious = args.contains("--keep-previous")
            installer.allowSigningMigration = false // consent is resolved only after the migration disclosure
            if let id = value("--bundle-id", in: args) { installer.bundleIdentifier = id } // lab candidates only
            do {
                _ = try NativeInstaller.verifySignedBundle(app)
                try Updater.removeQuarantine(app)
                let previous: URL?
                do { previous = try installer.install() } catch NativeInstallError.signingMigrationRequired {
                    try SigningMigrationConsent.authorize(flag: args.contains("--migrate-signing"), retryCommand: signingRetryCommand) { fputs($0, stderr) }
                    installer.allowSigningMigration = true
                    previous = try installer.install()
                }
                if installer.didMigrateSigning { print("signing-migrated: previous app kept; permissions must be re-granted") }
                print("installed \(destination.path)")
                if let previous { print("previous: \(previous.path)") }
            } catch {
                let prefix = installer.previousApp == nil ? "Vella installation stopped: " : ""
                fputs(prefix + error.localizedDescription + "\n", stderr)
                exit(1)
            }
        case "ready":
            guard let app = url("--app", in: args), let support = url("--support", in: args) else { fputs(usage, stderr); exit(2) }
            let timeout = value("--timeout", in: args).flatMap(Double.init) ?? 1800
            let interval = value("--interval", in: args).flatMap(Double.init) ?? 5
            let file = support.appendingPathComponent(InstallReadiness.statusFileName)
            let settle = value("--settle", in: args).flatMap(Double.init) ?? 60
            // Degraded (a configured-hot model not loaded) is never reported as ready: the caller keeps its
            // rollback copy.
            let result = InstallReadiness.wait(
                read: { try? Data(contentsOf: file) }, isInstalledApp: { InstallReadiness.runs($0, app: app) },
                timeout: timeout, interval: interval, settle: settle)
            if result.status == InstallReadiness.readyExit || result.status == InstallReadiness.degradedExit {
                print(result.line)
            } else {
                fputs("\(result.line). Status: \(file.path)\n", stderr)
            }
            exit(result.status)
        case "update":
            guard let path = value("--plan", in: args), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let plan = try? JSONDecoder().decode(InstallPlan.self, from: data)
            else { fputs(usage, stderr); exit(2) }
            let support = URL(fileURLWithPath: plan.supportDirectory, isDirectory: true)
            let log: (String) -> Void = { UpdateInstaller.appendLog($0, support: support) }
            log("update \(plan.from) -> \(plan.staged.version) at \(plan.destination)")
            do {
                try UpdateInstaller(plan: plan, log: log).run()
                log("updated to \(plan.staged.version)")
            } catch {
                fputs("Vella update stopped: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        default:
            fputs(usage, stderr); exit(2)
        }
    }
}
