import Foundation

/// Runs a tool to completion (standard input empty) and returns its exit status and combined output. The output is
/// read to its end before waiting, so a tool that writes more than a pipe buffer cannot deadlock against us. Throws
/// only when the tool cannot be started.
public func runTool(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
    let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
    child.standardInput = FileHandle.nullDevice
    try child.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    return (child.terminationStatus, String(decoding: data, as: UTF8.self))
}
