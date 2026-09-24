import XCTest
import Foundation
@testable import VellaCore

final class NativeInstallerTests: XCTestCase {
    private func fixture() throws -> (NativeInstaller, URL, URL, URL, ModelRecommendation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-native-install-\(UUID())")
        let prepared = root.appendingPathComponent("prepared/Vella.app")
        let app = root.appendingPathComponent("Applications/Vella.app")
        let support = root.appendingPathComponent("Library/Application Support/Vella")
        let catalog = root.appendingPathComponent("models.json")
        for name in ["Vella", "VellaWorker", "VellaModelTool"] {
            let path = prepared.appendingPathComponent("Contents/MacOS/\(name)")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.vella.dictation"], format: .xml, options: 0)
        try info.write(to: prepared.appendingPathComponent("Contents/Info.plist"))
        let model = ModelRecommendation(id: NativeInstaller.defaultModelID, name: "Parakeet v3", quantization: "4-bit",
            repository: "org/repo", revision: String(repeating: "a", count: 40), downloadBytes: 10,
            architecture: "parakeet", license: "test", recommendation: "test")
        try JSONEncoder().encode([model]).write(to: catalog)
        let installer = NativeInstaller(preparedApp: prepared, destination: app, support: support, catalog: catalog, downloader: prepared.appendingPathComponent("Contents/MacOS/VellaModelTool"))
        installer.verify = { _ in .init("adhoc") }
        installer.stop = { _ in false }; installer.launch = { _ in }
        installer.download = { model, models in
            let folder = models.appendingPathComponent(model.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"target":"nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel","quantization":{"bits":4}}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
            try Data("fixture".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
            return folder
        }
        return (installer, root, app, support, model)
    }
    func testFreshInstallRegistersVerifiedDefaultWithoutTouchingLegacyRuntime() throws {
        let (installer, root, app, support, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = support.appendingPathComponent("Runtimes/legacy/bin/python")
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retain".utf8).write(to: runtime)
        try installer.install()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("config.json"))) as! [String: Any]
        XCTAssertEqual(config["model"] as? String, support.appendingPathComponent("Models/\(model.id)").path)
        XCTAssertEqual(config["executable"] as? String, app.appendingPathComponent("Contents/MacOS/VellaWorker").path)
        let registry = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("models-installed.json"))) as! [String: [String: String]]
        XCTAssertEqual(registry[model.id]?["revision"], model.revision)
        XCTAssertEqual(try String(contentsOf: runtime), "retain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Vella").path))
    }
    func testBusyAndLinkedDestinationsRefuseBeforeMutation() throws {
        for cause in ["busy", "link"] {
            let (installer, root, app, support, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if cause == "busy" { try Data(#"{"phase":"recording"}"#.utf8).write(to: support.appendingPathComponent("dictation-status.json")) }
            else {
                let external = root.appendingPathComponent("external"); try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Models"), withDestinationURL: external)
            }
            XCTAssertThrowsError(try installer.install(), cause)
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path))
        }
    }
    func testFailedSwapRestoresOldAppAndSettings() throws {
        let (installer, root, app, support, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.vella.dictation"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("old".utf8).write(to: app.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = support.appendingPathComponent("config.json"), registry = support.appendingPathComponent("models-installed.json")
        let original = Data(#"{"model":"/old","streamingModel":"/stream","custom":42,"executable":"/old/python"}"#.utf8)
        try original.write(to: config)
        let previousRegistry = Data(#"{"other":{"path":"/shared"}}"#.utf8); try previousRegistry.write(to: registry)
        installer.afterSwap = { throw NativeInstallError.message("fixture swap failure") }
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertEqual(try Data(contentsOf: registry), previousRegistry)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("old")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Vella").path))
        XCTAssertEqual(model.id, NativeInstaller.defaultModelID)
    }
    func testFirstInstallFailureKeepsWeightsResumableWithoutSelection() throws {
        let (installer, root, app, support, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        installer.beforeSwap = { throw NativeInstallError.message("fixture interruption") }
        XCTAssertThrowsError(try installer.install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("models-installed.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("Models/\(model.id)/model.safetensors").path))
        installer.beforeSwap = {}
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("models-installed.json").path))
    }
    func testExistingSettingsArePreservedAndDownloadSkipped() throws {
        let (installer, root, app, support, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let saved: [String: Any] = ["model": "/external/model", "streamingModel": "/other/stream", "custom": 42, "preferredMicrophone": "Shure"]
        try JSONSerialization.data(withJSONObject: saved).write(to: support.appendingPathComponent("config.json"))
        installer.download = { _, _ in XCTFail("Existing settings must not trigger default download"); throw NativeInstallError.message("unexpected") }
        try installer.install()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("config.json"))) as! [String: Any]
        for key in ["model", "streamingModel", "custom", "preferredMicrophone"] { XCTAssertEqual(String(describing: config[key]!), String(describing: saved[key]!)) }
        XCTAssertEqual(config["executable"] as? String, app.appendingPathComponent("Contents/MacOS/VellaWorker").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("models-installed.json").path))
    }
    func testSigningMismatchAndMalformedConfigArePreserved() throws {
        for cause in ["signature", "config"] {
            let (installer, root, app, support, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if cause == "signature" {
                try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.vella.dictation"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                installer.verify = { path in .init(path == app ? "other-team" : "adhoc") }
            } else { try Data("{invalid".utf8).write(to: support.appendingPathComponent("config.json")) }
            XCTAssertThrowsError(try installer.install())
            if cause == "config" { XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("config.json")), "{invalid") }
        }
    }
}
