// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SDHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SDHelper", type: .dynamic, targets: ["SDHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "SDHelper",
            dependencies: [
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
            ]),
    ]
)
