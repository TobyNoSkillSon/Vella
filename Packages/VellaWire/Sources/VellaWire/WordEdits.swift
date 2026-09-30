/// Word-level Levenshtein distance: insertions, deletions and substitutions turning `a` into `b`.
public enum WordEdits {
    public static func distance<Word: Equatable>(_ a: [Word], _ b: [Word]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = Swift.min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
