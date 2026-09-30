// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Vella", platforms: [.macOS("26.0")], products: [.executable(name: "Vella", targets: ["Vella"]), .executable(name: "VellaModelTool", targets: ["VellaModelTool"]), .executable(name: "VellaInstallTool", targets: ["VellaInstallTool"]),
    // The `vella` command (shipped as Contents/Helpers/vella; `vella` and `Vella` collide on a case-insensitive disk).
    .executable(name: "vella-cli", targets: ["VellaCLI"])], targets: [
    .target(name: "VellaCore"),
    // In-app updates: release check, verified download, hand-off install with rollback.
    .target(name: "VellaUpdate", dependencies: ["VellaCore"]),
    .executableTarget(name: "Vella", dependencies: ["VellaCore", "VellaUpdate"]),
    // Retired stub (prints a notice, exits 2); kept in the bundle for the 1.0.x in-app updater's required list.
    .executableTarget(name: "VellaModelTool"),
    .executableTarget(name: "VellaInstallTool", dependencies: ["VellaCore", "VellaUpdate"]),
    .executableTarget(name: "VellaCLI", dependencies: ["VellaCore"]),
    // Shared by the test targets: the integration-test gate and the fake stdio worker.
    .target(name: "VellaTestSupport", path: "Tests/Support"),
    .testTarget(name: "VellaCoreTests", dependencies: ["VellaCore", "VellaTestSupport"]),
    .testTarget(name: "VellaUpdateTests", dependencies: ["VellaUpdate", "VellaCore"]),
    .testTarget(name: "VellaAppTests", dependencies: ["Vella", "VellaCore", "VellaCLI", "VellaUpdate", "VellaTestSupport"], exclude: ["ModelsTable/TierTooltips.txt"])
])
