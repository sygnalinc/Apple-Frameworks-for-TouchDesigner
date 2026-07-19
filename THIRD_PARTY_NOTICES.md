# Third-party notices / 第三者ソフトウェアとライセンス

TDAppleOps itself is released under the [MIT License](LICENSE). The repository contains
**only original code**: no Apple source, no TouchDesigner SDK, no bundled third-party
libraries, and no model weights are redistributed here. The components below are used at
build time or download time and remain under their own licenses.

TDAppleOps 本体は [MIT ライセンス](LICENSE)です。このリポジトリには**自作コードのみ**が
含まれ、Apple のソース・TouchDesigner SDK・第三者ライブラリ・モデルの重みは同梱・再配布
していません。以下はビルド時／ダウンロード時に利用されるもので、それぞれ独自のライセンスに従います。

## Apple frameworks / Apple フレームワーク

The plugins link against Apple's system frameworks (Vision, Core ML, Core Image,
VideoToolbox, MetalFX, Metal Performance Shaders, SpeechAnalyzer / Speech, Sound Analysis,
Natural Language, FoundationModels, ScreenCaptureKit, RealityKit, MultipeerConnectivity,
GameController, ImageIO, AVFoundation, Accelerate, …) **through their public APIs only**.

- No Apple code is copied into or redistributed by this repository — these frameworks ship
  as part of macOS.
- Building against them is governed by Apple's developer agreements (the *Xcode and Apple
  SDKs Agreement* / *Apple Developer Program License Agreement*), which apply to you as the
  developer and do not restrict the license of your own code that merely calls the APIs.
- "Apple", "Core ML", "Vision", "Metal", etc. are trademarks of Apple Inc. Their use here is
  descriptive (naming the framework a plugin wraps) and does not imply endorsement.

プラグインは Apple のシステムフレームワークを**公開API経由でリンクするだけ**です。Apple 製
コードの複製・再配布は行っていません(フレームワークは macOS の一部として提供されます)。
ビルドは Apple の開発者契約(Xcode and Apple SDKs Agreement 等)に従います。これは開発者に
適用されるもので、API を呼び出すだけの自作コードのライセンスを制約しません。

## TouchDesigner C++ SDK

`build.sh` reuses the C++ operator headers from an installed **TouchDesigner.app**
(`.../Resources/tfs/Samples/CPlusPlus/`). Those headers are **not included** in this
repository — you supply them via your own TouchDesigner installation, under Derivative Inc.'s
license. TouchDesigner is a trademark of Derivative.

`build.sh` はインストール済みの **TouchDesigner.app** の C++ SDK ヘッダを参照します。これらの
ヘッダは**リポジトリに同梱していません**。各自の TouchDesigner インストールから供給され、
Derivative 社のライセンスに従います。

## Build-time dependencies (Swift Package Manager, fetched — not vendored)

| Package | Used by | License |
|---|---|---|
| [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) | CoreML ImageGen | MIT |
| [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) | Speech Text (Whisper backend) | MIT |

These are declared in each helper's `Package.swift` and downloaded by SPM at build time;
their source is **not** committed here. Their transitive dependencies carry their own
(permissive) licenses — see each package's repository.

これらは各 helper の `Package.swift` で宣言され、ビルド時に SPM が取得します。ソースは
リポジトリに含めていません。推移的依存も各自の(寛容な)ライセンスに従います。

## Models / モデル

Model weights are **downloaded separately by the user** into `models/` (gitignored) and are
**never redistributed** by this repository. Each model is governed by its own license —
check the source before use, especially for commercial projects. Examples referenced in the
per-plugin READMEs:

モデルの重みは**利用者が各自 `models/` にダウンロード**するもので、リポジトリでは**一切
再配布しません**。各モデルは固有のライセンスに従うため、特に商用利用では入手元のライセンスを
必ず確認してください。各プラグインの README が参照している例:

- Apple Core ML models (e.g. Depth Anything V2, SAM 2.1, YOLOv3) — published by Apple on
  Hugging Face under the license stated on each model page.
- Any custom Core ML / Sound / detection model you supply is under whatever license you
  obtained it.

Some generative model weights are non-commercial (e.g. certain MusicGen weights were
CC-BY-NC); this project does not ship or depend on them, but if you add such a model, its
license — not this repository's MIT license — governs that model.
