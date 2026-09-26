import Foundation
import VellaCore

// install: transactional swap of a verified, prepared Vella.app; launches it; prints
//          `previous: <path>` when --keep-previous kept the old app for rollback.
// ready:   waits until the installed app reports ready (see InstallReadiness); prints `ready: …`.
@main struct VellaInstallTool {
    static let usage = """
    Usage: VellaInstallTool install --app <prepared Vella.app> --destination <Vella.app> --support <Vella support> [--keep-previous]
           VellaInstallTool ready --app <installed Vella.app> --support <Vella support> [--timeout seconds] [--interval seconds]

    """
    static func value(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    static func url(_ key: String, in args: [String]) -> URL? { value(key, in: args).map { URL(fileURLWithPath: $0) } }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "install":
            guard let app = url("--app", in: args), let destination = url("--destination", in: args),
                  let support = url("--support", in: args) else { fputs(usage, stderr); exit(2) }
            let installer = NativeInstaller(preparedApp: app, destination: destination, support: support)
            installer.keepPrevious = args.contains("--keep-previous")
            if let id = value("--bundle-id", in: args) { installer.bundleIdentifier = id } // lab candidates only
            do {
                let previous = try installer.install()
                print("installed \(destination.path)")
                if let previous { print("previous: \(previous.path)") }
            } catch {
                fputs("Vella installation stopped: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        case "ready":
            guard let app = url("--app", in: args), let support = url("--support", in: args) else { fputs(usage, stderr); exit(2) }
            let timeout = value("--timeout", in: args).flatMap(Double.init) ?? 1800
            let interval = value("--interval", in: args).flatMap(Double.init) ?? 5
            let file = support.appendingPathComponent(InstallReadiness.statusFileName)
            let deadline = Date().addingTimeInterval(timeout)
            var state = InstallReadiness.State.waiting("not checked")
            repeat {
                state = InstallReadiness.evaluate(status: try? Data(contentsOf: file)) { InstallReadiness.runs($0, app: app) }
                if case .ready(let line) = state { print("ready: \(line)"); exit(0) }
                Thread.sleep(forTimeInterval: interval)
            } while Date() < deadline
            if case .waiting(let reason) = state {
                fputs("not ready after \(Int(timeout)) s: \(reason). Status: \(file.path)\n", stderr)
            }
            exit(1)
        default:
            fputs(usage, stderr); exit(2)
        }
    }
}
