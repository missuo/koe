// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KoeMLX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KoeMLX", type: .static, targets: ["KoeMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", from: "0.1.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.6"),
        // Transitive dependency of swift-transformers, constrained here because
        // Jinja 2.4.0 changed its Value.object key type and no released
        // swift-transformers version compiles against it yet.
        .package(url: "https://github.com/huggingface/swift-jinja.git", "2.0.0"..<"2.4.0"),
    ],
    targets: [
        .target(
            name: "KoeMLX",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
