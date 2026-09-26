// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "VellaWorker", platforms: [.macOS(.v14)], products: [
    .executable(name: "VellaWorker", targets: ["VellaWorker"]),
    .executable(name: "VellaStreamingWorker", targets: ["VellaStreamingWorker"])
], dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift.git", revision: "901941965d82e4a216d4d117231d847d194c563d"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", revision: "150169bfba0889c229a2ce7494cf8949f18e6906")
], targets: [
    .target(name: "MLXAudioCore", dependencies: [.product(name: "MLX", package: "mlx-swift"), .product(name: "MLXFFT", package: "mlx-swift")]),
    .target(name: "MLXAudioSTT", dependencies: ["MLXAudioCore", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "Tokenizers", package: "swift-transformers")], exclude: ["Parakeet/README.md", "Qwen3ASR/README.md", "Whisper/README.md", "GraniteSpeech/README.md", "SenseVoice/README.md", "NemotronASR/README.md", "VoxtralRealtime/README.md"]),
    .executableTarget(name: "VellaWorker", dependencies: ["MLXAudioSTT"], resources: [.copy("Resources/clip-a.wav"), .copy("Resources/clip-b.wav"), .copy("Resources/clip-c.wav"), .copy("Resources/clip-d.wav"), .copy("Resources/clip-e.wav"), .copy("Resources/ATTRIBUTION.md"), .copy("Resources/LICENSE-CC-BY-4.0.txt")]),
    .executableTarget(name: "VellaStreamingWorker", dependencies: ["MLXAudioSTT"])
], swiftLanguageModes: [.v5])
