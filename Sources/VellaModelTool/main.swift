import Foundation
import VellaCore

@main struct VellaModelTool {
    static func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields; object["event"] = event
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line); fflush(stdout)
        }
    }
    static func argument(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "download", let catalog = argument("--catalog", in: args),
              let id = argument("--model-id", in: args), let directory = argument("--models-dir", in: args),
              let entries = try? JSONDecoder().decode([ModelRecommendation].self, from: Data(contentsOf: URL(fileURLWithPath: catalog))),
              let entry = entries.first(where: { $0.id == id }) else {
            emit("error", ["message": "Only curated models can be downloaded"]); exit(2)
        }
        let client = NativeModelDownload(catalogURL: URL(fileURLWithPath: catalog)) { message, completed, total in
            var fields: [String: Any] = ["message": message]
            if let completed, let total { fields["completed"] = completed; fields["total"] = total }
            emit("progress", fields)
        }
        do {
            let path = try await client.download(entry, modelsDirectory: URL(fileURLWithPath: directory))
            emit("installed", ["modelID": entry.id, "path": path.path, "revision": entry.revision])
        } catch {
            emit("error", ["message": error.localizedDescription]); exit(1)
        }
    }
}
