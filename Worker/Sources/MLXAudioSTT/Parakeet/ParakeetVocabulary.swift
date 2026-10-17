import Foundation

/// Private per-user context, separate from the model's SentencePiece vocabulary.
/// Missing configuration is deliberately empty in every public/source install.
public struct ParakeetVocabulary: Codable, Equatable, Sendable {
    public var words: [String]
    public var boost: Float
    /// Optional acoustic entry spellings; these stay in the same private file as the words.
    public var entries: [Entry] = []
    public var variants: [Variant] = []
    public struct Variant: Codable, Equatable, Sendable {
        public var word: String
        public var spelling: String
        public init(word: String, spelling: String) { self.word = word; self.spelling = spelling }
    }
    public struct Entry: Codable, Equatable, Sendable {
        public var word: String
        public var surface: String
        public var prefix: String
        public var boostStart: Bool
        public init(word: String, surface: String, prefix: String, boostStart: Bool = true) {
            self.word = word; self.surface = surface; self.prefix = prefix; self.boostStart = boostStart
        }
        enum CodingKeys: String, CodingKey { case word, surface, prefix, boostStart }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            word = try values.decode(String.self, forKey: .word)
            surface = try values.decode(String.self, forKey: .surface)
            prefix = try values.decode(String.self, forKey: .prefix)
            boostStart = try values.decodeIfPresent(Bool.self, forKey: .boostStart) ?? true
        }
    }
    public init(words: [String] = [], boost: Float = 4, entries: [Entry] = [], variants: [Variant] = []) {
        self.words = words; self.boost = boost; self.entries = entries; self.variants = variants
    }
    enum CodingKeys: String, CodingKey { case words, boost, entries, variants }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        words = try values.decode([String].self, forKey: .words)
        boost = try values.decode(Float.self, forKey: .boost)
        entries = try values.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        variants = try values.decodeIfPresent([Variant].self, forKey: .variants) ?? []
    }

    public func validate() throws {
        guard words.count <= 128, boost.isFinite, (0...8).contains(boost),
              words.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.allSatisfy(\.isLetter) }),
              entries.count <= 128, entries.allSatisfy({ entry in
                  words.contains(where: { $0.lowercased() == entry.word.lowercased() })
                      && !entry.prefix.isEmpty && entry.word.lowercased().hasPrefix(entry.prefix.lowercased())
                      && !entry.surface.isEmpty && entry.surface.count <= 64
                      && entry.surface.contains(where: \.isLetter)
                      && entry.surface.allSatisfy({ $0.isLetter || $0 == "'" })
              }), variants.count <= 128, variants.allSatisfy({ variant in
                  words.contains(where: { $0.lowercased() == variant.word.lowercased() })
                      && !variant.spelling.isEmpty && variant.spelling.count <= 64
                      && variant.spelling.contains(where: \.isLetter)
                      && variant.spelling.allSatisfy({ $0.isLetter || $0 == "'" })
              }) else {
            throw Invalid.configuration
        }
    }
    public enum Invalid: Error { case configuration, prefixes, fileSize }

    public static var localURL: URL {
        let support = ProcessInfo.processInfo.environment["VELLA_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vella")
        return support.appendingPathComponent("vocabulary.json")
    }
    public static func read(from url: URL = localURL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw Invalid.fileSize }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

/// Dense rows are bounded to 1,024 prefixes; no model weights enter the table.
struct ParakeetVocabularyTrie {
    let width: Int
    let next: [Int32]
    let bonus: [Float]
    let complete: [Bool]
    let configuration: ParakeetVocabulary
    let prefixes: [String]
    let indices: [String: Int]
    let completedWords: [Int: String]

    init(_ config: ParakeetVocabulary, pieces: [String]) throws {
        try config.validate()
        configuration = config
        width = pieces.count + 1
        var prefixes = [""]
        var indices = [String: Int]()
        var completedWords = [Int: String]()
        var canonicalPrefixes = Set<String>(), entryPrefixes = Set<String>(), entryStarts = Set<String>()
        func addPrefixes(_ text: String, to set: inout Set<String>) {
            var prefix = ""
            for letter in text { prefix.append(letter); set.insert(prefix) }
        }
        for canonical in config.words {
            let word = canonical.lowercased()
            addPrefixes(word, to: &canonicalPrefixes)
            var spellings = [word]
            for entry in config.entries where entry.word.lowercased() == word {
                let surface = entry.surface.lowercased()
                spellings.append(surface + word.dropFirst(entry.prefix.lowercased().count))
                addPrefixes(surface, to: &entryPrefixes)
                if entry.boostStart { entryStarts.insert(surface) }
            }
            spellings += config.variants.filter { $0.word.lowercased() == word }.map { $0.spelling.lowercased() }
            for spelling in spellings {
                var prefix = ""
                for letter in spelling {
                    prefix.append(letter)
                    if indices[prefix] == nil {
                        guard prefixes.count < 1024 else { throw ParakeetVocabulary.Invalid.prefixes }
                        indices[prefix] = prefixes.count
                        prefixes.append(prefix)
                    }
                }
                if let node = indices[spelling], completedWords[node] == nil { completedWords[node] = canonical }
            }
        }
        self.prefixes = prefixes; self.indices = indices; self.completedWords = completedWords
        var next = [Int32](repeating: 0, count: prefixes.count * width)
        var bonus = [Float](repeating: 0, count: next.count)
        var complete = [Bool](repeating: false, count: next.count)
        for node in prefixes.indices {
            for (token, piece) in pieces.enumerated() {
                let (target, start) = Self.transition(node, piece: piece, prefixes: prefixes, indices: indices)
                guard target != 0 else { continue }
                let offset = node * width + token
                next[offset] = Int32(target)
                let longCompletion = (completedWords[target]?.count ?? 0) >= 4
                complete[offset] = longCompletion
                if start {
                    if piece.filter(\.isLetter).count >= 2 {
                        if canonicalPrefixes.contains(prefixes[target]) { bonus[offset] = config.boost * 0.25 }
                        else if entryStarts.contains(prefixes[target]) { bonus[offset] = min(config.boost * 0.5, 2) }
                    }
                } else if completedWords[node] == nil
                            && !(entryPrefixes.contains(prefixes[target]) && !canonicalPrefixes.contains(prefixes[target])) {
                    bonus[offset] = config.boost * (longCompletion ? 2 : 1)
                }
            }
            next[node * width + pieces.count] = Int32(node)
        }
        self.next = next; self.bonus = bonus; self.complete = complete
    }

    private static func transition(_ node: Int, piece raw: String, prefixes: [String], indices: [String: Int]) -> (Int, Bool) {
        let boundary = raw.hasPrefix(" ") || raw.hasPrefix("▁")
        let piece = String(raw.drop(while: { $0 == " " || $0 == "▁" })).lowercased()
        guard !piece.isEmpty else { return (0, false) }
        if node != 0, let next = indices[prefixes[node] + piece] { return (next, false) }
        if boundary, let next = indices[piece] { return (next, true) }
        return (0, false)
    }

    /// Format only completed long decoder paths (including configured acoustic entries).
    /// Keep IDs and timestamps; shorter words cannot split an ordinary joined word.
    func format(_ tokens: [ParakeetAlignedToken], pieces: [String], frameSeconds: Double) -> [ParakeetAlignedToken] {
        var spans: [(Int, Int, String)] = []
        var node = 0, first = 0, lastFrame = 0
        for (index, token) in tokens.enumerated() {
            let frame = Int((token.start / frameSeconds).rounded())
            if frame > lastFrame + 8 { node = 0 }
            guard pieces.indices.contains(token.id) else { node = 0; continue }
            let (next, start) = Self.transition(node, piece: pieces[token.id], prefixes: prefixes, indices: indices)
            if start { first = index }
            node = next; lastFrame = frame
            if let word = completedWords[node], word.count >= 4 {
                if spans.last?.0 == first { spans.removeLast() }
                spans.append((first, index, word))
            }
        }
        var result = tokens
        func replace(_ index: Int, _ text: String) {
            let old = result[index]
            result[index] = ParakeetAlignedToken(id: old.id, text: text, start: old.start, duration: old.duration)
        }
        for (first, last, word) in spans {
            let leading = String(result[first].text.prefix(while: \.isWhitespace))
            var remaining = word[...]
            for index in first...last {
                let count = index == last ? remaining.count : min(remaining.count, result[index].text.filter { !$0.isWhitespace }.count)
                replace(index, (index == first ? leading : "") + remaining.prefix(count))
                remaining = remaining.dropFirst(count)
            }
            if last + 1 < result.count, result[last + 1].text.first?.isLetter == true,
               !isSuffix(tokens[(last + 1)...], pieces: pieces) {
                replace(last + 1, " " + result[last + 1].text)
            }
        }
        return result
    }

    /// Read the whole joined tail: `e` + `s` is a suffix, but `s` + `ystem` is a word.
    /// An explicit SentencePiece boundary or punctuation ends the tail.
    private func isSuffix(_ tokens: ArraySlice<ParakeetAlignedToken>, pieces: [String]) -> Bool {
        var tail = ""
        scan: for token in tokens {
            guard pieces.indices.contains(token.id) else { break }
            for character in pieces[token.id] {
                guard character.isLetter || character == "'" || character == "’" else { break scan }
                tail += character.lowercased()
                if tail.count > 4 { return false }
            }
        }
        return ["s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "'s", "’s"].contains(tail)
    }
}
