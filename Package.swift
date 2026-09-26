// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Vella", platforms: [.macOS(.v14)], products: [.executable(name: "Vella", targets: ["Vella"]), .executable(name: "VellaModelTool", targets: ["VellaModelTool"]), .executable(name: "VellaInstallTool", targets: ["VellaInstallTool"]),
    // The `vella` command (shipped as Contents/Helpers/vella; `vella` and `Vella` collide on a case-insensitive disk).
    .executable(name: "vella-cli", targets: ["VellaCLI"])], targets: [
    .target(name: "VellaCore"),
    .executableTarget(name: "Vella", dependencies: ["VellaCore"]),
    .executableTarget(name: "VellaModelTool", dependencies: ["VellaCore"]),
    .executableTarget(name: "VellaInstallTool", dependencies: ["VellaCore"]),
    .executableTarget(name: "VellaCLI", dependencies: ["VellaCore"]),
    .testTarget(name: "VellaCoreTests", dependencies: ["VellaCore"]),
    .testTarget(name: "VellaAppTests", dependencies: ["Vella", "VellaCore", "VellaCLI"])
])
