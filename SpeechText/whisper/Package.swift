// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperHelper", type: .dynamic, targets: ["WhisperHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(name: "WhisperHelper",
                dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
                path: "Sources/WhisperHelper")
    ]
)
