import Foundation

/// The checkout's root directory (this file is Tests/Support/Repository.swift), for tests that read the repository's
/// resources, scripts, docs and sources wherever the test file itself lives.
public enum Repository {
    public static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
