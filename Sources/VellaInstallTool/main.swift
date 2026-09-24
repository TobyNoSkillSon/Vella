import Foundation
import VellaCore

@main struct VellaInstallTool {
    static func value(_ key: String, in args: [String]) -> URL? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "install", let app = value("--app", in: args),
              let destination = value("--destination", in: args),
              let support = value("--support", in: args),
              let catalog = value("--catalog", in: args),
              let downloader = value("--downloader", in: args) else {
            fputs("Usage: VellaInstallTool install --app <prepared Vella.app> --destination <Vella.app> --support <Vella support> --catalog <models.json> --downloader <VellaModelTool>\n", stderr)
            exit(2)
        }
        do {
            try NativeInstaller(preparedApp: app, destination: destination, support: support,
                                catalog: catalog, downloader: downloader).install()
            print("Installed \(destination.path). Existing models, recordings and microphone choices were preserved.")
            print("Legacy Runtimes folders remain untouched; remove them only after the native app is verified and you approve cleanup.")
        } catch {
            fputs("Vella installation stopped: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
