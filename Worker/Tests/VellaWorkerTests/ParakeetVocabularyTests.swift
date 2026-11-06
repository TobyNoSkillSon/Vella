import Foundation
import Testing
import MLX
@testable import MLXAudioSTT

extension WorkerTests {
    @Suite struct Vocabulary {
        @Test func boundariesCompletionAndBlank() throws {
            let pieces = ["▁Ze", "ph", "yr", "▁made", "ph", "▁Ż", "an", "eta", "▁Z", "!"]
            let trie = try ParakeetVocabularyTrie(.init(words: ["Zephyr", "Żaneta"]), pieces: pieces)
            func next(_ node: Int, _ token: Int) -> Int { Int(trie.next[node * trie.width + token]) }
            let ze = next(0, 0), zeph = next(ze, 1), done = next(zeph, 2)
            #expect(ze != 0 && zeph != 0 && done != 0)
            #expect(trie.bonus[0] == 1)
            #expect(trie.bonus[ze * trie.width + 1] == 4)
            #expect(trie.bonus[zeph * trie.width + 2] == 8)
            #expect(trie.complete[zeph * trie.width + 2])
            #expect(next(ze, pieces.count) == ze)
            #expect(next(done, 3) == 0)
            #expect(next(0, 4) == 0)
            #expect(next(next(next(0, 5), 6), 7) != 0)
            #expect(trie.bonus[8] == 0)
            #expect(next(ze, 9) == 0)
        }
        @Test func acousticEntriesAndShortWordGuard() throws {
            let pieces = ["▁Se", "ph", "yr", "▁Ż", "an", "▁eta", "▁Ab", "c", "def"]
            let config = ParakeetVocabulary(words: ["Zephyr", "Żaneta", "Abc"], entries: [.init(word: "Zephyr", surface: "se", prefix: "ze")])
            let trie = try ParakeetVocabularyTrie(config, pieces: pieces)
            let se = Int(trie.next[0]), seph = Int(trie.next[se * trie.width + 1])
            #expect(trie.complete[seph * trie.width + 2])
            let ab = Int(trie.next[6])
            #expect(!trie.complete[ab * trie.width + 7])
            #expect(trie.bonus[ab * trie.width + 7] == 4)
            func format(_ ids: [Int], gap: Double = 0.08) -> String {
                let tokens = ids.enumerated().map {
                    ParakeetAlignedToken(id: $0.element, text: ParakeetTokenizer.decode(tokens: [$0.element], vocabulary: pieces), start: Double($0.offset) * gap, duration: 0.08)
                }
                return trie.format(tokens, pieces: pieces, frameSeconds: 0.08).map(\.text).joined()
            }
            #expect(format([0, 1, 2]) == " Zephyr")
            #expect(format([0, 1]) == " Seph") // incomplete entries do not rewrite spelling
            #expect(format([0, 1, 2], gap: 0.8) == " Sephyr")
            #expect(format([3, 4, 5]) == " Żaneta")
            #expect(format([6, 7, 8]) == " Abcdef")
        }
        @Test func entryFragmentsAndExactVariants() throws {
            let pieces = ["▁S", "e", "ph", "yr", "▁Se", "ir", "▁Ze", "▁Sephir"]
            let trie = try ParakeetVocabularyTrie(
                .init(
                    words: ["Zephyr"],
                    entries: [.init(word: "Zephyr", surface: "se", prefix: "ze")],
                    variants: [.init(word: "Zephyr", spelling: "sephir")]), pieces: pieces)
            let s = Int(trie.next[0]), se = Int(trie.next[s * trie.width + 1])
            #expect(trie.bonus[0] == 0)
            #expect(trie.bonus[s * trie.width + 1] == 0)
            #expect(trie.bonus[se * trie.width + 2] == 4)
            #expect(trie.bonus[4] == 2)
            #expect(trie.bonus[6] == 1)
            let suppressed = try ParakeetVocabularyTrie(
                .init(
                    words: ["Zephyr"],
                    entries: [.init(word: "Zephyr", surface: "se", prefix: "ze", boostStart: false)]), pieces: pieces)
            #expect(suppressed.bonus[4] == 0)
            let tokens = [4, 2, 5].enumerated().map {
                ParakeetAlignedToken(
                    id: $0.element,
                    text: ParakeetTokenizer.decode(tokens: [$0.element], vocabulary: pieces), start: Double($0.offset) * 0.08, duration: 0.08)
            }
            #expect(trie.format(tokens, pieces: pieces, frameSeconds: 0.08).map(\.text).joined() == " Zephyr")
        }
        @Test func completedWordsKeepWholeSuffixesAndSplitJoinedWords() throws {
            func format(_ pieces: [String], word: String) throws -> String {
                let trie = try ParakeetVocabularyTrie(.init(words: [word]), pieces: pieces)
                let tokens = pieces.indices.map {
                    ParakeetAlignedToken(
                        id: $0,
                        text: ParakeetTokenizer.decode(tokens: [$0], vocabulary: pieces), start: Double($0) * 0.08, duration: 0.08)
                }
                let output = trie.format(tokens, pieces: pieces, frameSeconds: 0.08)
                #expect(output.map(\.id) == tokens.map(\.id))
                #expect(output.map(\.start) == tokens.map(\.start))
                #expect(output.map(\.duration) == tokens.map(\.duration))
                return output.map(\.text).joined()
            }
            #expect(try format(["▁har", "ness", "e", "s"], word: "harness") == " harnesses")
            #expect(try format(["▁optimization", "s"], word: "optimization") == " optimizations")
            for suffix in ["s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "'s", "’s"] {
                #expect(try format(["▁ze", "ph", "yr"] + suffix.map(String.init) + [","], word: "Zephyr") == " Zephyr" + suffix + ",")
            }
            #expect(try format(["▁ze", "ph", "yr", "s", "ystem"], word: "Zephyr") == " Zephyr system")
            #expect(try format(["▁ze", "ph", "yr", "s", "ystem", "▁works"], word: "Zephyr") == " Zephyr system works")
            #expect(try format(["▁ze", "ph", "yr", "▁s"], word: "Zephyr") == " Zephyr s")
            #expect(try format(["▁ze", "ph", "yr", "e", "s", "▁work"], word: "Zephyr") == " Zephyres work")
            #expect(try format(["▁ze", "ph", "yr", "b", "ug"], word: "Zephyr") == " Zephyr bug")
        }
        @Test func validationAndBoundedFiles() throws {
            for value in [
                ParakeetVocabulary(words: ["two words"]), .init(words: ["a-b"]),
                .init(words: [""]), .init(words: [String(repeating: "a", count: 65)]),
                .init(words: Array(repeating: "word", count: 129)), .init(boost: .nan), .init(boost: 9)
            ] {
                #expect(throws: (any Error).self) { try value.validate() }
            }
            let scratch = try Scratch("vocabulary")
            let url = scratch.url.appendingPathComponent("vocabulary.json")
            #expect(try ParakeetVocabulary.read(from: url).words.isEmpty)
            try Data("{\"words\":[\"Zephyr\"],\"boost\":4}".utf8).write(to: url)
            #expect(try ParakeetVocabulary.read(from: url).words == ["Zephyr"])
            try Data(repeating: 32, count: 65537).write(to: url)
            #expect(throws: (any Error).self) { try ParakeetVocabulary.read(from: url) }
            let words = (0..<128).map { String(repeating: "a", count: 9) + String(UnicodeScalar(0x400 + $0)!) + String(repeating: "b", count: 20) }
            #expect(throws: (any Error).self) { try ParakeetVocabularyTrie(.init(words: words), pieces: ["▁a"]) }
        }
        @Test(.enabled(if: ProcessInfo.processInfo.environment["VELLA_TEST_VOCABULARY_GPU"] == "1"))
        func compiledBlankGateExpiryAndDuration() throws {
            if let path = ProcessInfo.processInfo.environment["VELLA_TEST_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
            let trie = try ParakeetVocabularyTrie(.init(words: ["Zephyr"]), pieces: ["▁Ze", "ph", "yr", "▁other"])
            let ze = Int(trie.next[0]), zeph = Int(trie.next[ze * trie.width + 1])
            let run = MLX.compile { a in
                let selected = ParakeetVocabularyGPU.select(a[0], time: a[1], lastFrame: a[2], prefix: a[3], bonus: a[4], complete: a[5], blank: 4)
                return [selected.0, selected.1]
            }
            func select(_ acoustic: [Float], node: Int, frame: Int) -> [Float] {
                let output = run([MLXArray(acoustic), MLXArray([Int32(frame)]), MLXArray([Int32(0)]), MLXArray([Int32(node)]), MLXArray(trie.bonus), MLXArray(trie.complete)])
                return output[0].asArray(Float.self)
            }
            // Blank wins: continuation gets no boost; completion may override it.
            let continuing = select([0, 3, 0, 0, 5, 7, 9], node: ze, frame: 8)
            #expect(continuing == [0, 3, 0, 0, 5, 7, 9])
            let completing = select([0, 0, 3, 0, 5, 7, 9], node: zeph, frame: 8)
            #expect(completing == [0, 0, 11, 0, 5, 7, 9])
            #expect(select([0, 0, 3, 0, 5, 7, 9], node: zeph, frame: 9) == [0, 0, 3, 0, 5, 7, 9])
            // Acoustic speech permits prefix entry/continuation, while duration logits remain original.
            #expect(select([3, 0, 0, 0, 2, 7, 9], node: 0, frame: 0) == [4, 0, 0, 0, 2, 7, 9])
            #expect(select([0, 3, 0, 0, 2, 7, 9], node: ze, frame: 0) == [1, 7, 0, 0, 2, 7, 9])
        }
        @Test func formattingPreservesTimingAndSpelling() throws {
            let trie = try ParakeetVocabularyTrie(.init(words: ["Zephyr", "Żaneta"]), pieces: ["▁ze", "ph", "yr", "bug", ",", "▁ż", "an", "eta", ".", "▁zeffer"])
            let texts = [" ze", "ph", "yr", "bug", ",", " ż", "an", "eta", ".", " zeffer"]
            let tokens = texts.enumerated().map { ParakeetAlignedToken(id: $0.offset, text: $0.element, start: Double($0.offset) * 0.08, duration: 0.1) }
            let output = trie.format(tokens, pieces: ["▁ze", "ph", "yr", "bug", ",", "▁ż", "an", "eta", ".", "▁zeffer"], frameSeconds: 0.08)
            #expect(output.map(\.text).joined() == " Zephyr bug, Żaneta. zeffer")
            #expect(output.map(\.start) == tokens.map(\.start))
            #expect(output.map(\.duration) == tokens.map(\.duration))
            #expect(output.map(\.id) == tokens.map(\.id))
            let empty = try ParakeetVocabularyTrie(.init(), pieces: [])
            #expect(empty.format(tokens, pieces: [], frameSeconds: 0.08).map(\.text) == texts)
        }
    }
}
