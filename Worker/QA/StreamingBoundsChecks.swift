import Foundation
final class CountingNative: StreamingNative {
    var text = ""; var calls = 0; var resets = 0; var finalCalls = 0
    var fail = false; var oversized = false
    func push(_ samples: [Float], final: Bool) throws {
        calls += 1
        if fail { throw StreamingFailure.inference }
        if final { finalCalls += 1 }
        else { text += oversized ? String(repeating: "x", count: 8193) : " word" }
    }
    func reset() throws { resets += 1; text = "" }
    func close() { text = "" }
}
@main struct Bounds {
    static func main() throws {
        let id = "12345678-1234-1234-1234-123456789abc"
        let voiced = [Float](repeating: 0.1, count: 320)
        let quiet = [Float](repeating: 0, count: 320)
        let native = CountingNative(), session = StreamingSession { _ in native }
        session.native = native
        var drains = 0, maximumText = 0
        for _ in 0..<10000 {
            if !(try session.block(voiced)).isEmpty { drains += 1 }
            maximumText = max(maximumText, native.text.utf8.count)
            assert(native.text.utf8.count < 2048 && session.preroll.count <= 15)
        }
        assert(native.calls == 10000 && native.resets == 0 && native.finalCalls == 0 && drains > 20)
        for _ in 0..<40 { _ = try session.block(quiet) }
        assert(native.resets == 1 && native.finalCalls == 1 && !session.active)
        for _ in 0..<1000 { _ = try session.block(quiet); assert(session.preroll.count <= 15) }
        assert(native.resets == 1 && native.calls == 10041)
        let framed = StreamingSession { _ in CountingNative() }; framed.native = CountingNative()
        let raw = [Float](repeating: 0, count: 1599).withUnsafeBytes { Data($0).base64EncodedString() }
        for _ in 0..<1000 {
            _ = try framed.handle(["id": id, "op": "audio", "pcm": raw])
            assert(framed.pending.count < 320 && framed.preroll.count <= 15)
        }
        assert(framed.frames == 1599000)
        for oversized in [false, true] {
            let bad = CountingNative(); bad.fail = !oversized; bad.oversized = oversized
            let failed = StreamingSession { _ in bad }; failed.native = bad
            let pcm = voiced.withUnsafeBytes { Data($0).base64EncodedString() }
            let first = failed.reply(["id": id, "op": "audio", "pcm": pcm])
            assert(first["error"] as? String == "Local streaming transcription failed." && failed.done)
            let calls = bad.calls
            _ = failed.reply(["id": id, "op": "audio", "pcm": pcm])
            assert(bad.calls == calls)
        }
        // Integer-state simulation of the actual bounded frontend arithmetic.
        // This verifies frame-count bounds, not GPU graph/allocation retention.
        var total = 0, bufferStart = 0, next = 0, pendingMel = 0, seed: UInt64 = 42
        var peakPCM = 0, peakPendingMel = 0
        for _ in 0..<100000 {
            seed = seed &* 6364136223846793005 &+ 1
            total += Int(seed % 320) + 1
            let end = total >= 256 ? (total - 256) / 160 + 1 : 0
            if end > next {
                pendingMel += end - next; next = end
                bufferStart = max(next - 2, 0) * 160
                pendingMel %= 32
            }
            peakPCM = max(peakPCM, total - bufferStart); peakPendingMel = max(peakPendingMel, pendingMel)
            assert(total - bufferStart <= 575 && pendingMel < 32)
        }
        print("PASS bounds: 10000 voiced blocks, \(drains) drains, no context reset; max text \(maximumText) B; PCM accounting/preroll bounded; sticky injected failures")
        print("PASS frontend integer-state simulation: max retained PCM \(peakPCM), pending mel \(peakPendingMel); GPU allocation test deferred")
    }
}
