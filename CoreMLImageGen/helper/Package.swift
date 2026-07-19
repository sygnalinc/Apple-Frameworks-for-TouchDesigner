// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageGenHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageGenHelper", type: .dynamic, targets: ["ImageGenHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "ImageGenHelper",
            dependencies: [
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
            ]),
    ]
)
