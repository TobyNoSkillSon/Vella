import Foundation
final class ProtocolFixtureNative: StreamingNative {
    var text = ""
    var serial = 0
    func push(_ samples: [Float], final: Bool) throws {
        if !samples.isEmpty && samples.contains(where: { $0 != 0 }) { serial += 1; text += " w\(serial)" }
    }
    func reset() throws { serial = 0; text = "" }
    func close() {}
}
@main struct Fixture {
    static func main() {
        let session = StreamingSession { _ in ProtocolFixtureNative() }
        while let line = readLine(), !session.done {
            let value = try? JSONSerialization.jsonObject(with: Data(line.utf8))
            let reply = session.reply(value)
            let json = try! JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        }
        session.close()
    }
}
