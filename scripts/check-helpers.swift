// Build-time smoke for the bundled stdio helpers. Not shipped.
// For VellaWorker and VellaStreamingWorker: the running process owns no window and is
// not registered as an app (lsappinfo), answers one request on its own pipe, and exits 0
// when its stdin reaches EOF (the app closing or dying). No model is loaded.
// Usage: check-helpers <Vella.app>
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never { fputs("check-helpers: \(message)\n", stderr); exit(1) }

func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot run \(tool)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func headless(_ pid: pid_t, _ name: String) {
    let listing = run("/usr/bin/lsappinfo", ["list"])
    if listing.range(of: "pid = \(pid)\\b", options: .regularExpression) != nil { fail("\(name) registered as an app (lsappinfo)") }
    guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { fail("cannot enumerate windows") }
    let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
    if !own.isEmpty { fail("\(name) created \(own.count) window(s)") }
}

/// Reads JSON lines until one carries `id`, up to `timeout`. Returns every line seen.
func replies(_ handle: FileHandle, id: String, timeout: TimeInterval) -> [[String: Any]] {
    var buffer = Data(), seen: [[String: Any]] = []
    let deadline = Date().addingTimeInterval(timeout)
    let fd = handle.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var chunk = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
        let n = read(fd, &chunk, chunk.count)
        if n > 0 { buffer.append(contentsOf: chunk[0..<n]) } else if n == 0 { break } else { usleep(20_000) }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer = Data(buffer[(newline + 1)...])
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                seen.append(object)
                if object["id"] as? String == id { return seen }
            }
        }
    }
    return seen
}

func waitExit(_ process: Process, _ seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning && Date() < deadline { usleep(50_000) }
    return !process.isRunning
}

guard CommandLine.arguments.count == 2 else { fail("usage: check-helpers <Vella.app>") }
let app = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, sendsRequest) in [("VellaWorker", true), ("VellaStreamingWorker", false)] {
    let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { fail("\(name) missing") }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("vella-helper-smoke-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let process = Process(); process.executableURL = executable
    var environment = ProcessInfo.processInfo.environment
    environment["VELLA_STUB_MODELS"] = "1"; environment["VELLA_SUPPORT_DIR"] = support.path
    process.environment = environment
    let input = Pipe(), output = Pipe()
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot launch \(name)") }
    usleep(500_000)
    guard process.isRunning else { fail("\(name) exited at start (status \(process.terminationStatus))") }
    headless(process.processIdentifier, name)
    var pidNote = "pid not reported"
    if sendsRequest {
        let id = UUID().uuidString.lowercased()
        input.fileHandleForWriting.write(Data("{\"id\":\"\(id)\",\"op\":\"status\"}\n".utf8))
        let lines = replies(output.fileHandleForReading, id: id, timeout: 20)
        guard lines.last?["id"] as? String == id else { process.terminate(); fail("\(name) did not answer a status request") }
        let reported = lines.compactMap { ($0["status"] as? [String: Any])?["pid"] as? Int } + lines.compactMap { $0["pid"] as? Int }
        if let pid = reported.first {
            guard pid == Int(process.processIdentifier) else { process.terminate(); fail("\(name) reported pid \(pid), child is \(process.processIdentifier)") }
            pidNote = "pid \(pid) == child"
        }
        headless(process.processIdentifier, name)
    }
    try? input.fileHandleForWriting.close() // stdin EOF: the app quit or died
    guard waitExit(process, 10) else { process.terminate(); fail("\(name) ignored stdin EOF for 10 s") }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { fail("\(name) exited with status \(process.terminationStatus) on EOF") }
    print("\(name): headless, \(sendsRequest ? "answered status (\(pidNote)), " : "")exit 0 on stdin EOF")
}
