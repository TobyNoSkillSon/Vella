// swift-tools-version:6.2
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription
let package = Package(
    name: "VellaWorker", platforms: [.macOS("26.0")],
    products: [
        .executable(name: "VellaWorker", targets: ["VellaWorker"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", revision: "901941965d82e4a216d4d117231d847d194c563d"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", revision: "150169bfba0889c229a2ce7494cf8949f18e6906"),
        // The vocabulary shared with the app (Foundation only).
        .package(path: "../Packages/VellaWire")
    ],
    targets: [
        .target(name: "MLXAudioCore", dependencies: [.product(name: "MLX", package: "mlx-swift"), .product(name: "MLXFFT", package: "mlx-swift")]),
        .target(name: "SmallMGEMM", dependencies: [.product(name: "MLX", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift")]),
        .target(
            name: "MLXAudioSTT",
            dependencies: [
                "MLXAudioCore", "SmallMGEMM", .product(name: "VellaWire", package: "VellaWire"), .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ], exclude: ["PROVENANCE.md", "Parakeet/README.md", "Qwen3ASR/README.md", "Whisper/README.md", "NemotronASR/README.md"]),
        // MLX-free pieces both helpers share: sandbox, stdio transport, request validation, process memory, test hooks.
        .target(name: "VellaWorkerSupport"),
        .executableTarget(
            name: "VellaWorker", dependencies: ["MLXAudioSTT", "SmallMGEMM", "VellaWorkerSupport", .product(name: "VellaWire", package: "VellaWire")],
            path: "Sources",
            exclude: ["MLXAudioCore", "MLXAudioSTT", "SmallMGEMM", "VellaWorkerSupport"],
            // Enumerate Swift files, not directories: resource copies have separate rules and stray files stay out.
            sources: [
                "VellaStreamingWorker/FusedTolerance.swift",
                "VellaStreamingWorker/NativeAdapters.swift",
                "VellaStreamingWorker/ReplayBoundary.swift",
                "VellaStreamingWorker/SelfTest.swift",
                "VellaStreamingWorker/StreamingMain.swift",
                "VellaStreamingWorker/StreamingModelCache.swift",
                "VellaStreamingWorker/StreamingSession.swift",
                "VellaStreamingWorker/Watchdog.swift",
                "VellaWorker/Calibration.swift",
                "VellaWorker/DescribeModel.swift",
                "VellaWorker/DictationService.swift",
                "VellaWorker/FastPathSelfTest.swift",
                "VellaWorker/QualificationReference.swift",
                "VellaWorker/StubModel.swift",
                "VellaWorker/Validation.swift",
                "VellaWorker/Wire.swift",
                "VellaWorker/WorkerEntry.swift",
                "VellaWorker/WorkerMain.swift"
            ],
            resources: [
                .copy("VellaWorker/Resources/clip-a.wav"), .copy("VellaWorker/Resources/clip-b.wav"), .copy("VellaWorker/Resources/clip-c.wav"),
                .copy("VellaWorker/Resources/clip-d.wav"), .copy("VellaWorker/Resources/clip-e.wav"),
                .copy("VellaWorker/Resources/ATTRIBUTION.md"), .copy("VellaWorker/Resources/LICENSE-CC-BY-4.0.txt")
            ]),
        // CPU-only unit tests: gate keys and persistence, admission, wire helpers, streaming tolerance. No kernel runs.
        .testTarget(
            name: "VellaWorkerTests",
            dependencies: [
                "VellaWorker", "VellaWorkerSupport", "MLXAudioSTT", "SmallMGEMM",
                .product(name: "VellaWire", package: "VellaWire")
            ])
    ], swiftLanguageModes: [.v5])
