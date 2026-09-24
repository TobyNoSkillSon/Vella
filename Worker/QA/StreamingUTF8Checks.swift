import Foundation
@main struct Check {
    static func main() {
        var decoder = VoxtralRealtimeTranscriptText()
        for byte in [UInt8(0xf0),0x9f,0x98] { decoder.append([byte]); assert(decoder.drainStable(final: false).isEmpty) }
        decoder.append([0x80]); assert(decoder.drainStable(final: false) == "😀")
        decoder.append([0xe0,0x80]); assert(decoder.drainStable(final: false) == "��")
        decoder.append([0xed,0xa0]); assert(decoder.drainStable(final: false) == "��")
        decoder.append([0xc3]); assert(decoder.drainStable(final: false).isEmpty)
        assert(decoder.drainStable(final: true) == "�")
        decoder.append(Array("a\u{0301} 漢字".utf8)); assert(decoder.drainStable(final: false) == "a\u{0301} 漢字")
        assert(decoder.text.isEmpty)
        print("PASS bounded UTF-8 scalar completion, invalid prefixes, final replacement, combining text")
    }
}
