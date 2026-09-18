// swift-tools-version: 6.0
import PackageDescription

// CoreAI LLM helper for TouchDesigner (CoreAI LLM DAT).
// Apple の coreai-models(Swift パッケージ・BSD-3)の CoreAILM を使い、.aimodel の
// LLM / VLM バンドル(exports/<name>/ = metadata.json + *.aimodel + tokenizer/)を
// JSON-lines プロトコルで回す常駐プロセス。DAT はこれを別プロセスとして spawn する
// (LLM MLX と同じ型・多GBモデルとGPU/ANEをTDから隔離する)。
//
// revision は動作確認した coreai-models のコミットに固定(API がまだ動くため)。
let package = Package(
    name: "CoreAILLMHelper",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "coreai-llm-cli", targets: ["coreai-llm-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/coreai-models.git",
                 revision: "5e00960a7eecb6dc56f377f9e585d641e86ec64a"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "coreai-llm-cli",
            dependencies: [
                .product(name: "CoreAILM", package: "coreai-models"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/coreai-llm-cli"
        ),
    ]
)
