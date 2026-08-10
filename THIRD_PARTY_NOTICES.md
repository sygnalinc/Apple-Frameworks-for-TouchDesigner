# Third-party notices / 第三者ソフトウェアとライセンス

TDAppleOps itself is released under the [MIT License](LICENSE). All of the plugin code is
original: no Apple source, no TouchDesigner SDK, and no model weights are redistributed
here. One third-party component **is** bundled — the development-time MCP server COMP
listed below. Everything else is used at build time or download time and remains under its
own license.

TDAppleOps 本体は [MIT ライセンス](LICENSE)です。プラグインのコードはすべて自作で、Apple の
ソース・TouchDesigner SDK・モデルの重みは同梱・再配布していません。第三者コンポーネントは
**1つだけ同梱**しています(下記の開発用 MCP サーバ COMP)。それ以外はビルド時／
ダウンロード時に利用されるもので、それぞれ独自のライセンスに従います。

## Bundled third-party component / 同梱している第三者コンポーネント

### TouchDesigner MCP server

| | |
|---|---|
| Where | Embedded in `demo.toe` as `/project1/td_mcp_server` |
| Source | https://github.com/johnsabath/touchdesigner-mcp (John Sabath) |
| License | MIT — stated in that project's README |

A development-time tool: it lets an AI agent drive TouchDesigner (inspect and edit the
network, run Python) while building and verifying these plugins. It is not required by any
plugin.

Note on the notice itself: that repository states MIT in its README but does not currently
ship a `LICENSE` file, so there is no published copyright line to reproduce verbatim. This
entry is the attribution; if the upstream project adds a `LICENSE`, its notice should be
copied here.

**Security:** the COMP starts a TouchDesigner Web Server DAT on port **9988**. The Web
Server DAT has no bind-address option, so it listens on **all interfaces**, not just
localhost, and the endpoint executes arbitrary Python inside TouchDesigner **without
authentication**. Anyone on the same network can therefore control TouchDesigner and, through
it, the machine. Delete `/project1/td_mcp_server` (or turn its `webserver` Active off) unless
you are actively using an MCP client.

開発用のツールです(AIエージェントが TouchDesigner を操作してプラグインの実装・検証を
行うために使用)。プラグインの動作には不要です。

**注意:** 上流リポジトリは README で MIT と明記していますが `LICENSE` ファイルが無いため、
そのまま複製すべき著作権表示が公開されていません。本項が出典表記にあたります。上流に
`LICENSE` が追加されたら、その通知文をここへ複製してください。

**セキュリティ:** この COMP は TouchDesigner の Web Server DAT をポート **9988** で起動します。
Web Server DAT には bind アドレスの指定が無いため **localhost ではなく全インターフェース**で
待ち受け、そのエンドポイントは**認証なしで** TouchDesigner 内の任意の Python を実行できます。
同じネットワーク上の誰でも TouchDesigner と、それを通じてマシンを操作できます。MCP クライアントを
実際に使うとき以外は `/project1/td_mcp_server` を削除するか、内部の `webserver` を Active Off に
してください。

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
| [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) | Speech Transcribe (Whisper backend) | MIT |

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
