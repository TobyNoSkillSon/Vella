import Foundation
import Darwin
import MLX

// Duplicated descriptor isolates native-library diagnostics from the JSON stream.
@main struct StreamingMain {
    static func main() {
        let output = dup(STDOUT_FILENO)
        let sink = open("/dev/null", O_WRONLY)
        guard output >= 0, sink >= 0 else { exit(1) }
        dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO); Darwin.close(sink)
        guard streamingSandbox() else { exit(1) }
        Memory.cacheLimit = 64 * 1024 * 1024
        let session = StreamingSession { path in try withError { try loadStreamingNative(path) } }
        defer { session.close(); Darwin.close(output) }
        let watchdog = StreamingWatchdog(output: output)
        while !session.done {
            watchdog.arm()
            var line = Data()
            while line.count <= 10000 {
                let c = fgetc(stdin)
                if c == EOF { break }
                line.append(UInt8(c))
                if c == 10 { break }
            }
            if line.isEmpty { watchdog.disarm(); break }
            let value = line.count <= 10000 && line.last == 10 ? try? JSONSerialization.jsonObject(with: line) : nil
            watchdog.identify(streamingIdentifier((value as? [String: Any])?["id"]))
            let reply: [String: Any]
            do { reply = try withError { session.reply(value) } }
            catch { session.done = true; reply = ["id": streamingIdentifier((value as? [String: Any])?["id"]) as Any? ?? NSNull(), "error": "Local streaming transcription failed."] }
            watchdog.disarm()
            watchdog.write(reply)
        }
    }
}
private func streamingSandbox() -> Bool {
    guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "sandbox_init"), let releaseSym = dlsym(handle, "sandbox_free_error") else { return false }
    defer { dlclose(handle) }
    typealias Initialize = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
    let initialize = unsafeBitCast(sym, to: Initialize.self)
    let release = unsafeBitCast(releaseSym, to: Release.self)
    var error: UnsafeMutablePointer<CChar>?
    let result = initialize("(version 1)(allow default)(deny network*)", 0, &error)
    if let error { release(error) }
    return result == 0
}
