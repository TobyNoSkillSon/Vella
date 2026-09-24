// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellaEnergy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "vella-energy", targets: ["VellaEnergy"])],
    targets: [.executableTarget(name: "VellaEnergy")]
)
