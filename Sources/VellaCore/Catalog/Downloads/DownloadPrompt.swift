import Foundation

// Every download asks first (Toby, 26 Sep 2026): a popup names the model, the download size and what happens when it
// finishes. Nothing is added to the Models table. The app shows `DownloadPrompt` in an NSAlert (DownloadGate.swift)
// and downloads only on Download.

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

/// The popup for getting `precision` of `family` (Toby, 15 Oct 2026: "minimal amount of text to say the actual thing";
/// no full model identifiers): the short name in the title; the size and what happens next in one sentence; a second
/// sentence only when the disk is too full. The download is the 16-bit checkpoint (or an fp32-only model's fp32
/// source); an 8- or 4-bit precision is made from it at load. Nil when the precision is not offered or nothing in the
/// catalog is downloadable. `freeBytes`: free space on the models volume now (nil = unknown).
public func downloadPrompt(family: ModelFamily, precision: String, followUp: DownloadFollowUp, freeBytes: Int64?) -> DownloadPrompt? {
    guard precisionOptions(family).contains(precision), let root = family.downloadSource(of: precision),
        let acquisition = family.acquisition(of: precision), !acquisition.download.repository.isEmpty
    else { return nil }
    let download = acquisition.download
    let madeAtLoad = root.label != precision
    let rootBytes = acquisition.convert == nil ? download.downloadBytes : (estimatedWeightBytes(family, root.label).map { Int64($0) } ?? download.downloadBytes)
    let then: String
    switch followUp {
    case .load: then = madeAtLoad ? "then it loads as \(precisionInProse(precision))" : "then it loads"
    case .reload(let loaded): then = "then it replaces the loaded \(precisionInProse(loaded))"
    case .transcribe: then = "then it transcribes your saved recording"
    }
    var body = "\(formatBytes(download.downloadBytes)) download, \(then)."
    // A stored conversion writes each converted file beside its source before swapping it in.
    let needed = download.downloadBytes + (acquisition.convert == nil ? 0 : rootBytes)
    if let freeBytes, freeBytes < needed { body += " Not enough disk space: \(formatBytes(freeBytes)) free, \(formatBytes(needed)) needed." }
    return DownloadPrompt(
        title: "Download \(family.name)?", body: body, variantID: root.variant.id,
        downloadBytes: download.downloadBytes, family: family.id, precision: precision)
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
/// be running in another Vella process) is left alone. With `removeFolders` false (the caller could not read which
/// folders it owns, so `keep` may be incomplete) no folder goes whole: only stale partials are removed. Returns the
/// removed paths.
@discardableResult
public func sweepStalePartialDownloads(
    modelsDirectory: URL, keep: Set<String>, removeFolders: Bool = true,
    olderThan: TimeInterval = 600, now: Date = Date()
) -> [String] {
    let manager = FileManager.default
    let kept = Set(keep.filter { !$0.isEmpty }.map(canonical))
    guard let names = try? manager.contentsOfDirectory(atPath: modelsDirectory.path) else { return [] }
    var removed: [String] = []
    for name in names.sorted() {
        guard let folder = ownedFolder(name, modelsDirectory: modelsDirectory) else { continue }
        let cache = folder.appendingPathComponent(".cache")
        guard (try? cache.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
            let walker = manager.enumerator(
                at: cache, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey],
                options: [], errorHandler: nil)
        else { continue }
        var partials: [URL] = []
        var fresh = false
        for case let file as URL in walker where file.lastPathComponent.hasSuffix(".incomplete") {
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]),
                values.isSymbolicLink == false, values.isRegularFile == true
            else { continue }
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < olderThan { fresh = true }
            partials.append(file)
        }
        guard !partials.isEmpty, !fresh else { continue }
        if !removeFolders || kept.contains(canonical(folder.path)) {
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
