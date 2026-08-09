# CoreML ImageGen TOP — text2img / img2img

**English** | [日本語](#日本語)

## English

A custom TOP that runs **text2img / img2img inside TD** using an **external Core ML image
generation model** (Stable Diffusion and friends). The current backend is Apple's
[ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) (SD 2.x / SDXL, detected
automatically from the model folder — by the presence of `TextEncoder2.mlmodelc`). Inference
lives in a helper dylib so **other Core ML generative models** can be added later on the helper
side.

> Consistent with the rule that **CoreML operators use external models**. Apple's built-in
> [Image Playground](../ImagePlayground/), which needs no external model, is a **separate TOP**
> (`ImagePlayground`).

Measured (M2 / SD 2.1 base split_einsum / 15 steps / CPU+ANE):
**text2img 7.6 s, img2img 4.5 s**. Loading the model (the first ANE compile) takes about 2
minutes.

### Backends

| Backend | Description | Measured (M2) |
|---|---|---|
| **Stable Diffusion (Core ML)** | ml-stable-diffusion. Point Model Folder at SD 2.x / SDXL / SD Turbo (auto-detected) | Turbo 1 step **0.8 s** / SD2.1 15 steps 7.6 s |

Strength only applies when Image to Image is on.

### Usage

1. Point `Model Folder` at a Core ML SD model folder (the level that directly contains
   `TextEncoder.mlmodelc`, `UnetChunk*.mlmodelc`, `VAEDecoder.mlmodelc`, …). Get models from
   `apple/coreml-stable-diffusion-*` on Hugging Face and put them in `models/` — **models are not
   part of this repository**
2. Wait for the Info DAT status to read `ready (SD)` / `ready (SDXL)`
3. Write a `Prompt` and pulse `Generate` — the output texture is replaced when it finishes
4. **img2img**: connect an input TOP and turn on `Image to Image`. `Strength` controls fidelity
   to the source (lower = closer to the original). The input is resized to the model's sample
   size (512/1024) automatically

### Real-time generation with SD Turbo

Combine [SD Turbo](https://huggingface.co/apple/coreml-sd-turbo) (a 1-to-few-step distilled
model) with **Continuous Generate** and continuous generation becomes real-time conversion:

1. Point `Model Folder` at the Core ML SD Turbo model (standard SD layout — auto-detected as the
   SD pipeline)
2. **`Steps` = 1–2, `Guidance Scale` = 1.0** — Turbo is meant to run with CFG disabled. This
   pipeline's CFG formula is `neg + g×(pos−neg)`, so **g = 1.0 means "prompt only"** (setting it
   to 0 makes the prompt be ignored)
3. Turn on `Continuous Generate` — as soon as one generation finishes it **regenerates with the
   latest input frame and parameters** (no Generate pulse needed)
4. For live video conversion turn on `Image to Image`. With Turbo, start tuning around
   `Steps = 2 × Strength = 0.5` (one effective step)

A fixed Seed keeps consecutive frames visually stable; -1 (random) changes them every frame.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| Model Folder | — | Folder of the (external) Core ML generative model |
| Compute Units | CPU + Neural Engine | ANE is recommended for split_einsum; use CPU+GPU for ORIGINAL conversions |
| Prompt / Negative Prompt | — | Prompts |
| Steps | 15 | Sampling steps (the scheduler is DPM-Solver++) |
| Guidance Scale | 7.5 | Prompt fidelity |
| Seed (-1 = Random) | -1 | Random seed. -1 randomises each run (the seed used appears in status) |
| Image to Image (Input 0) | Off | Use the input TOP as the initial image |
| Img2img Strength | 0.6 | Noise amount (1.0 is effectively text2img) |
| Generate | — | Run generation (pulses during busy are ignored) |
| Continuous Generate | Off | Always regenerate as soon as the previous run finishes (real-time mode) |
| Flip Output Vertically | On | Match TD's bottom-up textures |

Info CHOP: `busy / step / steps / gen_seconds / image_serial / executes` (usable for a progress
bar). Info DAT: `status` (loading model / ready / generating / done (7.6s, seed 4242) / error…).

### Notes

- Generation is asynchronous; TD's frames keep running. A Generate pulse during busy is ignored
- The first model load is especially slow (ANE compile). Parameters respond while loading but
  generation is unavailable
- The Swift helper (`helper/`, builds ml-stable-diffusion via SPM) ships as
  `libImageGenHelper.dylib`

### Build

```
./build.sh    # swift build of the helper → the plugin → the bundle (needs network the first time)
```

## 日本語

**外部の Core ML 画像生成モデル**（Stable Diffusion 等）で **TD 内から text2img / img2img**
する カスタム TOP。現行バックエンドは Apple 公式
[ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion)
（SD 2.x 系 / SDXL 系をモデルフォルダ内容で自動判定 — TextEncoder2.mlmodelc の有無）。
**Stable Diffusion 以外の Core ML 生成モデル**にも対応できるよう、推論はヘルパ dylib に
分離してある（バックエンド追加はヘルパ側の拡張で行う）。

> **CoreML 系は外部モデルを使う**、というルールに統一。外部モデルを使わない Apple 標準の
> [Image Playground](../ImagePlayground/) は**別の TOP**（`ImagePlayground`）に分離した。

実測（M2 / SD 2.1 base split_einsum / 15 steps / CPU+ANE）:
**text2img 7.6秒・img2img 4.5秒**。モデルロード（初回のANEコンパイル）は約2分。

### バックエンド

| Backend | 内容 | 実測(M2) |
|---|---|---|
| **Stable Diffusion (Core ML)** | ml-stable-diffusion。SD 2.x / SDXL / SD Turbo を Model Folder で指定(自動判定) | Turbo 1step **0.8秒** / SD2.1 15steps 7.6秒 |

Strength は Image to Image オン時のみ有効。

### 使い方

1. `Model Folder` に Core ML SD モデルのフォルダを指定
   （`TextEncoder.mlmodelc` `UnetChunk*.mlmodelc` `VAEDecoder.mlmodelc` 等が直下にある階層。
   モデルは Hugging Face の `apple/coreml-stable-diffusion-*` などから取得し
   `models/` に置く — **モデルはリポジトリに含まれない**）
2. Info DAT の status が `ready (SD)` / `ready (SDXL)` になるまで待つ
3. `Prompt` を書いて `Generate` をパルス → 完了すると出力テクスチャが差し替わる
4. **img2img**: 入力 TOP を接続し `Image to Image` をオン。`Strength` で元画像への忠実度
   （小さいほど元画像寄り）。入力はモデルのサンプルサイズ（512/1024）へ自動リサイズ

### SD Turbo でリアルタイム生成/変換

[SD Turbo](https://huggingface.co/apple/coreml-sd-turbo)（1〜数ステップの蒸留モデル）と
**Continuous Generate** を組み合わせると、連続生成＝リアルタイム変換になる:

1. `Model Folder` に SD Turbo の Core ML モデル（標準SD構成・自動判定で SD パイプライン）
2. **`Steps` = 1〜2、`Guidance Scale` = 1.0** ← Turbo は CFG 無効で使う。
   このパイプラインの CFG 式は `neg + g×(pos−neg)` なので **g=1.0 が「プロンプトのみ」**
   （0 にするとプロンプトが無視されるので注意）
3. `Continuous Generate` をオン → 前の生成が終わり次第、**最新の入力フレームと
   パラメータで自動再生成**し続ける（Generate パルス不要）
4. img2img でライブ映像変換する場合は `Image to Image` オン。Turbo では
   `Steps=2 × Strength=0.5`（実効1ステップ）あたりから調整

Seed は固定値にすると連続フレームの見た目が安定し、-1（ランダム）だと毎フレーム変化する。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Model Folder | — | Core ML 画像生成モデル(外部)のフォルダ |
| Compute Units | CPU + Neural Engine | split_einsum は ANE 推奨。ORIGINAL 変換版は CPU+GPU |
| Prompt / Negative Prompt | — | プロンプト |
| Steps | 15 | サンプリングステップ（スケジューラは DPM-Solver++） |
| Guidance Scale | 7.5 | プロンプトへの忠実度 |
| Seed (-1 = Random) | -1 | 乱数シード。-1 で毎回ランダム（status に使用シードが出る） |
| Image to Image (Input 0) | Off | 入力 TOP を初期画像にする |
| Img2img Strength | 0.6 | ノイズ量（1.0 で実質 text2img） |
| Generate | — | 生成実行（busy 中のパルスは無視） |
| Continuous Generate | Off | 完了し次第つねに再生成（リアルタイム変換モード） |
| Flip Output Vertically | On | TD の bottom-up に合わせる |

Info CHOP: `busy / step / steps / gen_seconds / image_serial / executes`（進捗バー等に使える）。
Info DAT: `status`（loading model / ready / generating / done (7.6s, seed 4242) / error...）。

### 注意

- 生成は非同期で TD のフレームは止まらない。busy 中の Generate は無視される
- モデルロードは初回が特に遅い（ANE コンパイル）。ロード完了までパラメータは効くが生成不可
- Swift ヘルパ（helper/ ・SPMで ml-stable-diffusion をビルド）を `libImageGenHelper.dylib` として同梱

### ビルド

```
./build.sh    # helper の swift build → plugin本体 → bundle（要ネットワーク初回のみ）
```
