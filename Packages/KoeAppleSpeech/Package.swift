// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KoeAppleSpeech",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KoeAppleSpeech", type: .static, targets: ["KoeAppleSpeech"]),
    ],
    targets: [
        .target(name: "KoeAppleSpeech"),
    ]
)
