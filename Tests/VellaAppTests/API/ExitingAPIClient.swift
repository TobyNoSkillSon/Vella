import Foundation

/// A separate client sends a complete request, then exits normally (FIN, no SO_LINGER/RST) when released.
struct ExitingAPIClient {
    let process: Process
    private let input: Pipe
    init(port: Int, request: Data) throws {
        input = Pipe(); process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import socket,sys,base64; s=socket.create_connection(('127.0.0.1',int(sys.argv[1]))); s.sendall(base64.b64decode(sys.argv[2])); sys.stdin.buffer.read(1); s.close()",
            String(port), request.base64EncodedString()
        ]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice
        try process.run()
    }
    func exitNormally() { try? input.fileHandleForWriting.close() }
}
