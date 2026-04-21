// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PolishBench",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "polish-bench", targets: ["PolishBench"]),
    ],
    dependencies: [
        // Versions pinned to match the main SAM app's Package.resolved so the
        // bench runs identical MLX code paths. Update in lockstep when the main
        // app upgrades MLX.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.30.6"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.6"),
    ],
    targets: [
        .executableTarget(
            name: "PolishBench",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/PolishBench"
        ),
    ]
)
