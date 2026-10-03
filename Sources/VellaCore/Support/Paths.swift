import Foundation

/// The two paths name the same file once standardized (`.`/`..` and a trailing slash removed).
public func sameFiles(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
}

/// Directory identity is a path comparison: URL's directory hint may add a trailing slash to its identity.
/// Callers resolve symlinks first where physical identity is required; this does not silently resolve ownership links.
public func sameDirectory(_ a: URL, _ b: URL) -> Bool { a.isFileURL && b.isFileURL && sameFiles(a.path, b.path) }

/// Component boundary, not a raw prefix (a sibling like Models-old is never inside Models).
public func isWithinDirectory(_ child: URL, root: URL, includingRoot: Bool = false) -> Bool {
    guard child.isFileURL, root.isFileURL else { return false }
    let parent = root.standardizedFileURL.path, path = child.standardizedFileURL.path
    if sameFiles(path, parent) { return includingRoot }
    return path.hasPrefix(parent == "/" ? "/" : parent + "/")
}
