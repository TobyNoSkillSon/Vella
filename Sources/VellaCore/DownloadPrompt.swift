import Foundation

// Every download asks first (Toby, 26 Sep 2026): a popup says what is downloaded, which precision, how big, and what
// happens when it finishes. Nothing is added to the Models table. The app shows `DownloadPrompt` in an NSAlert
// (Sources/Vella/DownloadConfirmation.swift) and downloads only on Download.

/// What happens when the confirmed download finishes.
public enum DownloadFollowUp: Equatable {
    /// Table Get/Load: it loads for its mode.
    case load
    /// Table Reload of a loaded model: it loads in place of the loaded precision.
    case reload(from: String)
    /// The first-dictation Get row: it loads and transcribes the saved recording.
    case transcribe
}

/// The confirmation popup's text and the download it approves.
public struct DownloadPrompt: Equatable {
    public var title: String
    public var body: String
    /// The catalog variant that downloads (a derived precision's published source).
    public var variantID: String
    public var downloadBytes: Int64
    public var family: String
    public var precision: String
    public init(title: String, body: String, variantID: String, downloadBytes: Int64, family: String, precision: String) {
        self.title = title; self.body = body; self.variantID = variantID; self.downloadBytes = downloadBytes
        self.family = family; self.precision = precision
    }
}

private let exactBytes: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US"); return f
}()
/// `2,509,016,021 bytes`.
public func formatExactBytes(_ bytes: Int64) -> String { (exactBytes.string(from: NSNumber(value: bytes)) ?? String(bytes)) + " bytes" }

/// `Parakeet v3 · 32 (FP32)`: the table's bare width plus the exact format in prose.
public func precisionTitle(_ family: ModelFamily, _ label: String) -> String {
    "\(family.name) \u{00b7} " + (precisionWidth(label).map { "\($0) (\(precisionInProse(label)))" } ?? precisionInProse(label))
}

/// The popup for downloading what `precision` of `family` needs: its own published weights, or for a precision made on
/// this Mac the published weights it is made from. Nil when the catalog has no downloadable source.
/// `freeBytes`: free space on the models volume now (nil = unknown).
public func downloadPrompt(family: ModelFamily, precision: String, followUp: DownloadFollowUp, freeBytes: Int64?) -> DownloadPrompt? {
    guard let source = family.downloadSource(of: precision), !source.variant.repository.isEmpty else { return nil }
    let derived = source.label != precision
    let variant = source.variant
    let revision = variant.revision.isEmpty ? "" : " at revision \(variant.revision.prefix(7))"
    let title = derived
        ? "Download \(precisionTitle(family, source.label)) to make \(precisionWidth(precision) ?? precision) (\(precisionInProse(precision)))?"
        : "Download \(precisionTitle(family, precision))?"
    var what: String
    if derived {
        what = "\(family.name) at \(precisionFormatName(precision)) is made on this Mac from its \(precisionFormatName(source.label)) weights. "
            + "This downloads those weights, published on Hugging Face as \(variant.repository)\(revision)."
    } else {
        what = "\(family.name) at \(precisionFormatName(precision))" + (precision == family.native ? ", the model's native precision" : "")
            + ", published on Hugging Face as \(variant.repository)\(revision)."
    }
    if let processor = variant.processorSource {
        what += " Tokenizer files come from \(processor.repository)."
    }
    var size = "Download: \(formatBytes(variant.downloadBytes)) (\(formatExactBytes(variant.downloadBytes))). Disk needed: \(formatBytes(variant.downloadBytes))"
    if let freeBytes { size += "; \(formatBytes(freeBytes)) free" }
    size += "."
    if derived { size += " The \(precisionInProse(precision)) weights are made at load and add nothing on disk." }
    if let freeBytes, freeBytes < variant.downloadBytes { size += " Not enough free disk space." }
    let mode = family.mode.title.lowercased()
    let then: String
    switch followUp {
    case .load: then = "When the download finishes, it loads for \(mode)."
    case .reload(let loaded): then = "When the download finishes, it loads for \(mode) in place of the loaded \(precisionInProse(loaded))."
    case .transcribe: then = "When the download finishes, it loads and transcribes the saved recording."
    }
    return DownloadPrompt(title: title, body: [what, size, then].joined(separator: "\n\n"), variantID: variant.id,
                          downloadBytes: variant.downloadBytes, family: family.id, precision: precision)
}

// MARK: Partial downloads

/// Standardized path with symlinks resolved, for comparing model locations.
private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

/// `modelsDirectory/<name>` when it is a real directory directly inside a real models directory (no symlinks).
private func ownedFolder(_ name: String, modelsDirectory: URL) -> URL? {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
    let root = modelsDirectory.standardizedFileURL
    let folder = root.appendingPathComponent(name)
    guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
          let values = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
          values.isSymbolicLink == false, values.isDirectory == true,
          folder.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path
    else { return nil }
    return folder
}

/// Removes a cancelled or failed download's files: the folder `modelsDirectory/<id>` unless `keep` (installed models,
/// the configured models) contains it. Only real directories directly inside the models directory. True when removed.
@discardableResult
public func removeUnfinishedDownload(id: String, modelsDirectory: URL, keep: Set<String>) -> Bool {
    guard let folder = ownedFolder(id, modelsDirectory: modelsDirectory) else { return false }
    let kept = Set(keep.filter { !$0.isEmpty }.map(canonical))
    guard !kept.contains(canonical(folder.path)) else { return false }
    return (try? FileManager.default.removeItem(at: folder)) != nil
}

/// Launch clean-up of partial downloads left by a quit, crash or earlier version, inside the models directory only.
/// A folder holding a `.incomplete` partial older than `olderThan` seconds is an unfinished download: removed whole
/// unless `keep` contains it, when only its stale partials go. A folder with a fresh partial (a download that may still
/// be running in another Vella process) is left alone. Returns the removed paths.
@discardableResult
public func sweepStalePartialDownloads(modelsDirectory: URL, keep: Set<String>, olderThan: TimeInterval = 600, now: Date = Date()) -> [String] {
    let manager = FileManager.default
    let kept = Set(keep.filter { !$0.isEmpty }.map(canonical))
    guard let names = try? manager.contentsOfDirectory(atPath: modelsDirectory.path) else { return [] }
    var removed: [String] = []
    for name in names.sorted() {
        guard let folder = ownedFolder(name, modelsDirectory: modelsDirectory) else { continue }
        let cache = folder.appendingPathComponent(".cache")
        guard (try? cache.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let walker = manager.enumerator(at: cache, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey],
                                              options: [], errorHandler: nil) else { continue }
        var partials: [URL] = []
        var fresh = false
        for case let file as URL in walker where file.lastPathComponent.hasSuffix(".incomplete") {
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]),
                  values.isSymbolicLink == false, values.isRegularFile == true else { continue }
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < olderThan { fresh = true }
            partials.append(file)
        }
        guard !partials.isEmpty, !fresh else { continue }
        if kept.contains(canonical(folder.path)) {
            for file in partials where (try? manager.removeItem(at: file)) != nil { removed.append(file.path) }
        } else if (try? manager.removeItem(at: folder)) != nil {
            removed.append(folder.path)
        }
    }
    return removed
}

/// Free space for new files on the volume holding `url` (its nearest existing ancestor); nil when unknown.
public func freeDiskBytes(at url: URL) -> Int64? {
    var cursor = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: cursor.path), cursor.path != "/" { cursor.deleteLastPathComponent() }
    return (try? cursor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
}
