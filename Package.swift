// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Vella", platforms: [.macOS(.v14)], products: [.executable(name: "Vella", targets: ["Vella"])], targets: [
    .target(name: "VellaCore"),
    .executableTarget(name: "Vella", dependencies: ["VellaCore"]),
    .testTarget(name: "VellaCoreTests", dependencies: ["VellaCore"]),
    .testTarget(name: "VellaAppTests", dependencies: ["Vella", "VellaCore"])
])
