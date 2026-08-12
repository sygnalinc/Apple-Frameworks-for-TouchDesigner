# CoreML TOP

**English** | [日本語](#日本語)

## English

A **general-purpose operator** that loads any Core ML model (`.mlpackage` / `.mlmodel` /
`.mlmodelc`) and runs inference on the incoming TOP image. Swap the model file and the same
operator does depth estimation, style transfer, segmentation, image classification and so on.

If you need an `MLMultiArray` as CHOP channels — vectors, embeddings, keypoints — use the sister
operator [CoreML CHOP](../CoreMLCHOP/).

Supported input/output shapes:

| Model output | TOP output |
|---|---|
| Image (grayscale f16/f32/8bit) | Mono32Float / Mono8 texture (depth maps etc.) |
| Image (BGRA colour) | BGRA8 texture (style transfer etc.) |
| MLMultiArray `[...,H,W]` | Mono32Float texture |
| MLMultiArray `[...,3,H,W]` (CHW) | RGBA32Float texture |
| Classifier | Top 10 classes in the Info DAT (identifier / confidence) |

The input is resized to the model's image input automatically (choose fill/crop/fit with Input
Scaling). **Models with a single image input are the target** (multi-input models only work if
the other inputs have defaults).

### Measured (M2, Depth Anything V2 Small F16, 518x392)

- Inference about 33 ms → **roughly 20 fps** on continuous video. TD itself stays at 60 fps
  (asynchronous, cook never blocks)
- First load: compiling the mlpackage plus the ANE load takes several seconds (the compiled
  result is cached in `~/Library/Caches/TDAppleML/`, so later loads are fast)
- The output resolution is the model's native one (518x392 for Depth Anything V2 Small). Use a
  Fit TOP to match the input resolution

### Getting the model (Depth Anything V2)

Model binaries are not in the repository (`models/` is gitignored). Grab Apple's official Core ML
conversion from Hugging Face:

```
https://huggingface.co/apple/coreml-depth-anything-v2-small
→ put DepthAnythingV2SmallF16.mlpackage (about 48 MB) in models/ and point Model File at it
```

Other Core ML models Apple publishes (FastViT, DETR segmentation, …) work as-is:
https://huggingface.co/apple / https://developer.apple.com/machine-learning/models/

### Parameters

| Name | Description |
|---|---|
| Active | Run inference On/Off |
| Model File | Path to `.mlpackage` / `.mlmodel` / `.mlmodelc` |
| Reload Model | Reload the model (pulse) |
| Compute Units | All (ANE+GPU+CPU) / CPU+GPU / CPU Only / CPU+Neural Engine |
| Input Scaling | Scale Fill (default) / Center Crop / Scale Fit |
| Output Range | **Auto Normalize** = normalise each frame's min-max to 0–1 (default) / Raw Values = leave as-is (32-bit float) / Manual Range = map Range Min–Max to 0–1 |
| Range Min / Max | Mapping range for Manual Range |
| Invert Output | Invert the output (1-x). **Depth Anything is a disparity model where nearer = larger**, so use this when you want far = white |
| Flip Image Vertically | Flip input and output (default On — required because TD textures are bottom-up) |

### Info channels / Info DAT

- Info CHOP: `executes / submits / analyzes / loaded / inference_ms / out_w / out_h`.
  The per-second increase in `analyzes` is the effective fps
- Info DAT: `status` (no model / compiling / loading / ready / error), `model`, `input`,
  `output` (the model's I/O spec), `inference_ms`; for a classifier the top 10 classes follow

### Notes

- **Auto Normalize uses each frame's min-max**, so overall brightness changes as the scene does
  (relative depth). For temporally stable values use Raw Values plus a downstream Math TOP, or
  Manual Range
- Raw depth values are on a model-dependent relative scale (not metres)
- The first ANE compile takes time proportional to model size (`status="loading"` is not a fault)
- Core ML input resizing is left to Vision (`VNCoreMLRequest`). Scale Fill distorts the aspect
  ratio but sees the whole frame; Center Crop keeps the aspect but cuts the edges
- Classifier models have no image output, so the texture is not updated (Info DAT only)

### Build

```
cd CoreML && ./build.sh   # → build/CoreMLTOP.plugin
```

## 日本語

任意の Core ML モデル(`.mlpackage` / `.mlmodel` / `.mlmodelc`)をロードして、入力 TOP の
映像に推論を実行する**汎用オペレータ**。モデルファイルを差し替えるだけで深度推定・
スタイル変換・セグメンテーション・画像分類などに使える。

ベクトル・埋め込み・キーポイントなど`MLMultiArray`をCHOPチャンネルとして使う場合は、
姉妹オペレータの[CoreML CHOP](../CoreMLCHOP/)を使用する。

対応する入出力の形:

| モデル出力 | TOP 出力 |
|---|---|
| Image(グレースケール f16/f32/8bit) | Mono32Float / Mono8 テクスチャ(深度マップ等) |
| Image(BGRA カラー) | BGRA8 テクスチャ(スタイル変換等) |
| MLMultiArray `[...,H,W]` | Mono32Float テクスチャ |
| MLMultiArray `[...,3,H,W]`(CHW) | RGBA32Float テクスチャ |
| 分類(Classifier モデル) | Info DAT に上位10クラス(identifier / confidence) |

入力はモデルの画像入力に自動リサイズされる(Input Scaling で fill/crop/fit を選択)。
**画像入力を1つ持つモデルが対象**(複数入力モデルは他入力にデフォルト値が無いと動かない)。

### 実測(M2・Depth Anything V2 Small F16・518x392)

- 推論 約33ms → **約20fps**(動画入力連続処理)。TD本体は60fpsを維持(非同期・cook非ブロック)
- 初回ロード: mlpackage のコンパイル+ANEロードで数秒(コンパイル結果は
  `~/Library/Caches/TDAppleML/` にキャッシュされ、2回目以降は速い)
- 出力解像度はモデルのネイティブ解像度(Depth Anything V2 Small は 518x392)。
  入力解像度に合わせるには Fit TOP を使う

### モデルの入手(Depth Anything V2)

モデルバイナリはリポジトリに含まれない(`models/` は gitignore)。Apple 公式の
Core ML 変換版を Hugging Face から取得する:

```
https://huggingface.co/apple/coreml-depth-anything-v2-small
→ DepthAnythingV2SmallF16.mlpackage(約48MB)を models/ に置き、Model File に指定
```

他にも Apple が公式配布する Core ML モデル(FastViT、DETR セグメンテーション等)が
そのまま使える: https://huggingface.co/apple / https://developer.apple.com/machine-learning/models/

### パラメータ

| 名前 | 内容 |
|---|---|
| Active | 推論の実行 On/Off |
| Model File | `.mlpackage` / `.mlmodel` / `.mlmodelc` のパス |
| Reload Model | モデルの再読み込み(パルス) |
| Compute Units | All (ANE+GPU+CPU) / CPU+GPU / CPU Only / CPU+Neural Engine |
| Input Scaling | Scale Fill(既定)/ Center Crop / Scale Fit |
| Output Range | **Auto Normalize**=フレーム毎 min-max を 0〜1 に正規化(既定)/ Raw Values=生値のまま(32bit float)/ Manual Range=Range Min〜Max を 0〜1 にマップ |
| Range Min / Max | Manual Range 時のマッピング範囲 |
| Invert Output | 出力を反転(1-x)。**Depth Anything は「近いほど大きい」disparity 系**なので、遠=白にしたいときに使う |
| Flip Image Vertically | 入出力の上下反転(既定On。TDのテクスチャは bottom-up のため必須) |

### Info チャンネル / Info DAT

- Info CHOP: `executes / submits / analyzes / loaded / inference_ms / out_w / out_h`。
  `analyzes` の増分/秒が実効fps
- Info DAT: `status`(no model/compiling/loading/ready/error)・`model`・`input`・
  `output`(モデルの入出力仕様)・`inference_ms`、分類モデルでは上位10クラスの行が続く

### 注意

- **Auto Normalize はフレーム毎の min-max** なので、シーン内容が変わると全体の明るさも
  変わる(相対深度)。時間的に安定した値が欲しい場合は Raw Values + 後段の Math TOP、
  または Manual Range を使う
- 深度の生値スケールはモデル依存の相対値(メートルではない)
- ANE 初回コンパイルはモデルサイズに応じて時間がかかる(status="loading" は故障ではない)
- Core ML の入力リサイズは Vision(VNCoreMLRequest)任せ。Scale Fill はアスペクト比が
  歪むが全域を見る。Center Crop は歪まないが端が切れる
- 分類モデルは画像出力が無いのでテクスチャは更新されない(Info DAT のみ)

### ビルド

```
cd CoreML && ./build.sh   # → build/CoreMLTOP.plugin
```
