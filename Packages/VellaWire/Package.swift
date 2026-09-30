// swift-tools-version: 6.0
import PackageDescription

// The vocabulary the app and the recognition helpers share across the process boundary (Foundation only; the app
// never links MLX, the helpers never link VellaCore).
let package = Package(
    name: "VellaWire", platforms: [.macOS("26.0")],
    products: [
        .library(name: "VellaWire", targets: ["VellaWire"])
    ],
    targets: [
        .target(name: "VellaWire"),
        .testTarget(name: "VellaWireTests", dependencies: ["VellaWire"])
    ], swiftLanguageModes: [.v6])
