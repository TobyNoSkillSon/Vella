import Foundation
import Darwin
@main struct WireChecks {
    static func main() throws {
        let input = tmpfile()!; defer { fclose(input) }
        let bytes = Data((String(repeating: "x", count: maximumLine*10)+"\n{}\n").utf8)
        bytes.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, input) }
        rewind(input)
        precondition(readBoundedLine(input)!.count == maximumLine+1)
        precondition(readBoundedLine(input) == Data("{}\n".utf8))
        precondition(readBoundedLine(input) == nil)
        alarm(0)
        let response: [String: Any] = ["text": "Zażółć 🐈 / \n", "id": NSNull()]
        let encoded = try responseBytes(response)
        precondition(encoded.allSatisfy { $0 < 128 })
        let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(decoded["text"] as? String == response["text"] as? String)
        print("Wire checks passed: bounded drain, recovery, EOF, Unicode round trip")
    }
}
