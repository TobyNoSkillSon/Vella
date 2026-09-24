import Foundation
final class FakeNative: StreamingNative {
    var text = ""; var pushes: [[Float]] = []; var finals = 0; var resets = 0; var closed = false
    func push(_ samples: [Float], final: Bool) throws { pushes.append(samples); if final { finals += 1 }; if samples.contains(where: { $0 != 0 }) { text += " word" } }
    func reset() throws { resets += 1; text = "" }
    func close() { closed = true }
}
@main struct Checks {
    static func main() throws {
        let native = FakeNative(), session = StreamingSession { _ in native }
        session.native = native
        let id = "12345678-1234-1234-1234-123456789abc"
        func send(_ samples: [Float]) throws -> [String: Any] {
            let data = samples.withUnsafeBytes { Data($0) }
            return try session.handle(["id": id, "op": "audio", "pcm": data.base64EncodedString()])
        }
        for _ in 0..<20 { _ = try send(Array(repeating: 0, count: 320)) }
        assert(native.pushes.isEmpty && session.preroll.count == 15)
        _ = try send(Array(repeating: 0.1, count: 320))
        assert(native.pushes.count == 15 && session.active)
        for _ in 0..<39 { _ = try send(Array(repeating: 0, count: 320)) }
        assert(session.active && native.finals == 0)
        let end = try send(Array(repeating: 0, count: 320))
        assert(!session.active && native.resets == 1 && native.finals == 1 && end["committed"] as? String == "word")
        _ = try send([0.1])
        let finish = try session.handle(["id": id, "op": "finish"])
        assert(finish["done"] as? Bool == true && native.resets == 2 && finish["frames"] as? Int == 19521)
        assert(session.reply(["id": id, "op": "finish"])["error"] != nil)
        session.close(); assert(native.closed)
        let text = FakeNative()
        text.text = String(repeating: "word ", count: 600)
        let before = text.text
        let drained = try text.drain()
        assert(drained + text.text == before && text.text.utf8.count < 2048)
        text.text = String(repeating: "é", count: 5000)
        do { _ = try text.drain(); assertionFailure("missing boundary must fail") } catch {}
        text.text = String(repeating: "é ", count: 1000)
        _ = try text.drain(); assert(text.text.utf8.count < 2048)
        for value in ["", "AAAA", "AA==", "!!!!", Data([0,0,128,127]).base64EncodedString(), Array(repeating: Float(17), count: 1).withUnsafeBytes { Data($0).base64EncodedString() }] {
            do { _ = try streamingPCM(value); assertionFailure("accepted invalid PCM") } catch {}
        }
        let overshoot = try streamingPCM([Float(1.5)].withUnsafeBytes { Data($0).base64EncodedString() }); assert(overshoot == [1.5])
        assert(streamingIdentifier("urn:uuid:{12345678123412341234123456789abc}") != nil)
        assert(streamingIdentifier("not-uuid") == nil)
        let failed = StreamingSession { _ in FakeNative() }
        assert(failed.reply(["id": id, "op": "audio", "pcm": "AA=="])["error"] != nil && failed.done)
        print("PASS streaming: pre-roll, trailing endpoint, short finish, frame count, sticky errors, text drains, PCM bounds")
    }
}
