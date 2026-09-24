import Foundation
import Darwin
@main struct SystemChecks {
    static func main() {
        precondition(installOfflineSandbox(), "Sandbox must install")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(result == -1 && errno == EPERM, "Network denial must be EPERM")
        close(fd)
        let memory = processMemory()
        precondition(memory.count == 4 && memory["processFootprintBytes"]! > 0)
        print("System checks passed: network EPERM; all four process metrics")
    }
}
