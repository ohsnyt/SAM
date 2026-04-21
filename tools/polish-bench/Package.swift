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
        // Intentionally ahead of the main SAM app (0.30.x / 2.30.x) so the
        // bench can load the Qwen3.5 architecture (`model_type: "qwen3_5"`)
        // which mlx-swift-lm 3.31+ adds via Qwen35.swift. When the main app
        // catches up, realign these pins to match Package.resolved.
        //
        // mlx-swift-lm 3.x split hub access out: loadContainer now needs an
        // explicit Downloader (HubClient from swift-huggingface) and a
        // TokenizerLoader (from MLXHuggingFace's macros).
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "PolishBench",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                // Needed because MLXHuggingFaceMacros expands to code that
                // references swift-transformers' Tokenizers module.
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/PolishBench"
        ),
    ]
)
