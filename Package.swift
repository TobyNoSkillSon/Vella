// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

/// Swift 6 language mode (complete concurrency checking) for the targets that have been moved to it.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let package = Package(
    name: "Vella", platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Vella", targets: ["Vella"]), .executable(name: "VellaModelTool", targets: ["VellaModelTool"]),
        .executable(name: "VellaInstallTool", targets: ["VellaInstallTool"]),
        // The `vella` command (shipped as Contents/Helpers/vella; `vella` and `Vella` collide on a case-insensitive disk).
        .executable(name: "vella-cli", targets: ["VellaCLI"])
    ],
    // The vocabulary shared with the recognition helpers (Worker/ depends on it too).
    dependencies: [.package(path: "Packages/VellaWire")],
    targets: [
        .target(name: "VellaCore", dependencies: [.product(name: "VellaWire", package: "VellaWire")], swiftSettings: swift6),
        // In-app updates: release check, verified download, hand-off install with rollback.
        .target(name: "VellaUpdate", dependencies: ["VellaCore"], swiftSettings: swift6),
        .executableTarget(name: "Vella", dependencies: ["VellaCore", "VellaUpdate", .product(name: "VellaWire", package: "VellaWire")]),
        // Retired stub (prints a notice, exits 2); kept in the bundle for the 1.0.x in-app updater's required list.
        .executableTarget(name: "VellaModelTool", swiftSettings: swift6),
        .executableTarget(name: "VellaInstallTool", dependencies: ["VellaCore", "VellaUpdate"], swiftSettings: swift6),
        .executableTarget(name: "VellaCLI", dependencies: ["VellaCore", .product(name: "VellaWire", package: "VellaWire")], swiftSettings: swift6),
        // Shared by the test targets: the integration-test gate and the fake stdio worker.
        .target(name: "VellaTestSupport", path: "Tests/Support"),
        .testTarget(name: "VellaCoreTests", dependencies: ["VellaCore", "VellaTestSupport", .product(name: "VellaWire", package: "VellaWire")]),
        .testTarget(name: "VellaUpdateTests", dependencies: ["VellaUpdate", "VellaCore"]),
        .testTarget(
            name: "VellaAppTests",
            dependencies: [
                "Vella", "VellaCore", "VellaCLI", "VellaUpdate", "VellaTestSupport",
                .product(name: "VellaWire", package: "VellaWire")
            ], exclude: ["ModelsTable/TierTooltips.txt"])
    ], swiftLanguageModes: [.v5])
