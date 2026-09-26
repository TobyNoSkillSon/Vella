import XCTest
@testable import VellaCLI

/// The CLI finds the app it ships in even when it runs through the ~/.local/bin symlink, found via PATH
/// (argv[0] is then just "vella"): diagnose reports the app's version and the CLI can launch that app.
final class CLIAppLocationTests: XCTestCase {
    func testSymlinkOutsideTheAppResolvesToTheContainingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-cli-location-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Somewhere/Vella.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let binary = helpers.appendingPathComponent("vella")
        try Data().write(to: binary)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("vella")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        XCTAssertEqual(VellaClient.app(containing: link.path)?.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
        XCTAssertNil(VellaClient.app(containing: "vella"), "a bare command name has no location")
        XCTAssertNil(VellaClient.app(containing: bin.appendingPathComponent("other").path))
    }

    func testExecutablePathIsAbsolute() {
        XCTAssertTrue(VellaClient.executablePath().hasPrefix("/"))
    }
}
