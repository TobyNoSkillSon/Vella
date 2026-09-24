import Foundation
import MLX
import MLXAudioSTT
final class DiagnosticNative: StreamingNative {
    var text = ""
    var model: NemotronASRModel?
    var session: VellaNemotronSession?
    init(_ path: URL) throws {
        model = try NemotronASRModel.fromDirectory(path)
        VellaNemotronDiagnostics.useReferencePositionTable(model!)
        try reset()
    }
    func reset() throws { session = nil; text = ""; session = try VellaNemotronSession(model: model!); Memory.clearCache() }
    func push(_ samples: [Float], final: Bool) throws { text += try session!.push(samples, final: final) }
    func close() { session = nil; model = nil; Stream.gpu.synchronize(); Memory.clearCache() }
}
@main struct Main {
    static func main() throws {
        Memory.cacheLimit = 64 * 1024 * 1024
        if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--dump-front" {
            let a = CommandLine.arguments
            try VellaNemotronDiagnostics.dump(configURL: URL(fileURLWithPath: a[2]), pcmURL: URL(fileURLWithPath: a[3]), lengthsURL: URL(fileURLWithPath: a[4]), output: URL(fileURLWithPath: a[5])); return
        }
        var resident: DiagnosticNative?
        var path: URL?
        func fresh() -> StreamingSession {
            StreamingSession { p in
                if path != p { resident?.close(); resident = try DiagnosticNative(p); path = p }
                else { try resident?.reset() }
                return resident!
            }
        }
        var session = fresh(); defer { resident?.close() }
        while let line = readLine() {
            let reply = try withError { session.reply(try? JSONSerialization.jsonObject(with: Data(line.utf8))) }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: reply) + Data([10]))
            if session.done {
                guard reply["done"] as? Bool == true else { break }
                session.native = nil; session.close(); session = fresh()
            }
        }
    }
}
