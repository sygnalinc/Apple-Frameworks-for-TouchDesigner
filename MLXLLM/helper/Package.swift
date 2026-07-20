// swift-tools-version: 6.1
import PackageDescription

// MLX LLM helper for TouchDesigner.
// Stage 1 (this package): a standalone CLI (`mlxllm-cli`) to validate that
//   mlx-swift-lm builds + runs on this machine and Gemma 4 generates text.
// Stage 2 (later): swap the executable product for a dynamic library exposing
//   the mlx_* C ABI consumed by MLXLLMDAT.mm.
//
// mlx-swift-lm vendors its own tokenizer/hub code but the MLXHuggingFace macros
// expand to `HuggingFace.HubClient` / `Tokenizers.AutoTokenizer`, so the consumer
// must also depend on swift-huggingface + swift-transformers.
let package = Package(
    name: "MLXLLMHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mlxllm-cli", targets: ["mlxllm-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "mlxllm-cli",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/mlxllm-cli"
        ),
    ]
)
