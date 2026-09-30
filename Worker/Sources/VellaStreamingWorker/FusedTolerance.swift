import Foundation

/// The fused conformer layer's self-test tolerance: the optimized stream against the stock (unfused) stream of the
/// same self-test audio, reply by reply. Foundation only, so a lab test compiles it standalone.
enum FusedTolerance {
    /// Relative RMS ||fused - unfused|| / ||unfused|| of the chunk encoder output over the self-test stream.
    /// M5 Max, Float32 activations: 0.7e-3 (4b), 1.2e-3 (8b), 1.8e-3 (BF16) — most of it from the 1×1 convs as
    /// matmuls, the rest from summation order; injected kernel bugs (wrong position bias, dropped conv cache) give 0.69-1.42.
    /// BF16 with its Linears on the BF16 small-M kernel (`VELLA_NEMO_BF16LINEAR`, 28 Sep): 6.0e-3.
    static let maxFusedDeviation: Float = 1e-2
    /// Committed words of the whole stream may differ by at most one edit (a near-tie token).
    static let maxWordEdits = 1
    /// Reply timing. Commits (replies carrying committed text) pair up one to one with stock's, each at most this many
    /// 100-ms packets earlier or later.
    static let maxCommitShift = 1
    /// Replies whose partial text differs from stock's (a word shown a packet earlier or later). Whole v2-quick as one
    /// stream, 8b: 6 of 14,750 replies differed and no commit moved.
    static let maxPartialDifferences = 2

    struct Verdict {
        var accepted: Bool
        /// Every field other than committed/partial (frames, done, incomplete) identical, reply for reply.
        var shape: Bool
        var wordEdits: Int
        /// Largest commit shift in packets; nil when the commits do not pair up one to one.
        var commitShift: Int?
        var partialDifferences: Int
        var summary: String {
            "word edits \(wordEdits), commit shift \(commitShift.map(String.init) ?? "unpaired"), partial differences \(partialDifferences), shape \(shape)"
        }
    }

    static func judge(stock: [[String: Any]], fast: [[String: Any]], rms: Float) -> Verdict {
        let edits = wordEdits(words(committedText(stock)), words(committedText(fast)))
        let shape =
            stock.count == fast.count
            && zip(stock, fast).allSatisfy { a, b in
                var a = a, b = b
                for key in ["committed", "partial"] { a[key] = nil; b[key] = nil }
                return NSDictionary(dictionary: a).isEqual(to: b)
            }
        let stockCommits = commits(stock), fastCommits = commits(fast)
        let shift = stockCommits.count == fastCommits.count ? zip(stockCommits, fastCommits).map { abs($0 - $1) }.max() ?? 0 : nil
        let partials = zip(stock, fast).filter { ($0["partial"] as? String ?? "") != ($1["partial"] as? String ?? "") }.count
        let accepted =
            !committedText(stock).isEmpty && shape && edits <= maxWordEdits && (shift.map { $0 <= maxCommitShift } ?? false)
            && partials <= maxPartialDifferences && rms <= maxFusedDeviation
        return Verdict(accepted: accepted, shape: shape, wordEdits: edits, commitShift: shift, partialDifferences: partials)
    }

    /// Reply indices (packets) that carry committed text.
    static func commits(_ replies: [[String: Any]]) -> [Int] {
        replies.indices.filter { !((replies[$0]["committed"] as? String) ?? "").isEmpty }
    }
    static func committedText(_ replies: [[String: Any]]) -> String {
        replies.compactMap { ($0["committed"] as? String).flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " ")
    }
    static func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }
    /// Word-level Levenshtein distance.
    static func wordEdits(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
