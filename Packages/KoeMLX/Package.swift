// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KoeMLX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KoeMLX", type: .static, targets: ["KoeMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.6"),
    ],
    targets: [
        .target(
            name: "KoeMLX",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
    ]
)
