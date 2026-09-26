// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Vella", platforms: [.macOS(.v14)], products: [.executable(name: "Vella", targets: ["Vella"]), .executable(name: "VellaModelTool", targets: ["VellaModelTool"]), .executable(name: "VellaInstallTool", targets: ["VellaInstallTool"]),
    // The `vella` command (shipped as Contents/Helpers/vella; `vella` and `Vella` collide on a case-insensitive disk).
    .executable(name: "vella-cli", targets: ["VellaCLI"])], targets: [
    .target(name: "VellaCore"),
    // In-app updates: release check, verified download, hand-off install with rollback.
    .target(name: "VellaUpdate", dependencies: ["VellaCore"]),
    .executableTarget(name: "Vella", dependencies: ["VellaCore", "VellaUpdate"]),
    .executableTarget(name: "VellaModelTool", dependencies: ["VellaCore"]),
    .executableTarget(name: "VellaInstallTool", dependencies: ["VellaCore", "VellaUpdate"]),
    .executableTarget(name: "VellaCLI", dependencies: ["VellaCore"]),
    .testTarget(name: "VellaCoreTests", dependencies: ["VellaCore"]),
    .testTarget(name: "VellaUpdateTests", dependencies: ["VellaUpdate", "VellaCore"]),
    .testTarget(name: "VellaAppTests", dependencies: ["Vella", "VellaCore", "VellaCLI", "VellaUpdate"])
])
