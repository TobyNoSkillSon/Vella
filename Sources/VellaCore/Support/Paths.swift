import Foundation

/// The two paths name the same file once standardized (`.`/`..` and a trailing slash removed).
public func sameFiles(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
}
