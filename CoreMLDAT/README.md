# CoreML (DAT)

**English** | [日本語](#日本語)

> The operator is named **CoreML** (family = DAT). The general-purpose Core ML TOP / CHOP / DAT
> all share the opType `Coreml` and are told apart by family (colour). Image → image is
> [CoreML TOP](../CoreML/); → vector is [CoreML CHOP](../CoreMLCHOP/). This DAT takes a detection
> model (`VNRecognizedObjectObservation`) and outputs label / confidence / bbox as a table.
>
> OP名は **CoreML**(family=DAT)。汎用CoreML推論の TOP/CHOP/DAT は同じ opType `Coreml` に統一され、
> family(色)で区別する。画像→画像は [CoreML TOP](../CoreML/)、→ベクトルは [CoreML CHOP](../CoreMLCHOP/)。
> この DAT は検出モデル(VNRecognizedObjectObservation)で label/confidence/bbox をテーブル出力する。

## English

A general-purpose operator that loads any **object-detection Core ML model** (YOLOv3 etc.) and
reports **what is where** in the incoming TOP image as a table.

Division of labour: [CoreML TOP](../CoreML/) handles models with image/array output (depth, style
transfer, …), [CoreML CHOP](../CoreMLCHOP/) handles vector output, and this DAT handles detection
models (the ones that return `VNRecognizedObjectObservation`).

### Measured (M2, YOLOv3Int8LUT, 416x416 input)

- Inference **about 38 ms ≈ 26 fps** when run alone. On a banana image, `banana` at confidence
  0.994
- **Running it alongside other ANE plugins (LLSR etc.) makes it several times slower** because
  they contend for the ANE (measured: 262 ms concurrently). Don't run too many heavy ML operators
  at once

### Getting a model

```
https://huggingface.co/apple/coreml-YOLOv3
→ put YOLOv3Int8LUT.mlmodel (62 MB, 80 COCO classes) in models/ and point Model File at it
```

YOLOv8/v11 converted to Core ML with Ultralytics (exported with NMS) also work as-is.

### Output table

| Column | Description |
|---|---|
| rank | By confidence, starting at 1 |
| label | Class name (model dependent — person/car/banana… for COCO) |
| confidence | Confidence 0–1 |
| u, v | bbox centre (uv, bottom-left origin — same convention as Vision Track) |
| w, h | bbox size (uv) |

### Parameters

| Name | Description |
|---|---|
| TOP | Input TOP |
| Model File | Path to `.mlmodel` / `.mlpackage` / `.mlmodelc` |
| Reload Model | Reload (pulse) |
| Compute Units | All / CPU+GPU / CPU Only / CPU+ANE |
| Input Scaling | Scale Fill (default) / Center Crop / Scale Fit |
| Max Detections | Maximum detections (1–100, default 20) |
| Min Confidence | Anything below this is not reported (default 0.25) |
| Flip Image Vertically | Flip the input (default On — required) |

### Info CHOP

`executes / submits / analyzes / analyze_ms / detections / loaded`

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
the bbox height (a v distance) is also 1/aspect; the width is unchanged
```

Because `u` stays in 0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly on the
source video **with the camera's Ortho Width left at 1** (no manual scaling). Leave it Off when
you want raw 0..1 image coordinates.

### Notes

- **Only models exported with NMS (duplicate removal) are supported.** Detection models that emit
  raw tensors (YOLO without NMS, …) do not produce `VNRecognizedObjectObservation` and raise a
  warning
- Loading a non-detection model also raises a warning (use CoreML TOP/CHOP for those)
- Compiled models are cached in the shared `~/Library/Caches/TDAppleML/`

### Build

```
cd CoreMLDAT && ./build.sh   # → build/CoreMLDAT.plugin
```

## 日本語

任意の**物体検出 Core ML モデル**(YOLOv3 等)をロードし、入力 TOP の映像から
「**何が・どこに**」を検出してテーブル出力する汎用オペレータ。

役割分担: [CoreML TOP](../CoreML/) は画像/配列出力モデル(深度・スタイル変換等)、
[CoreML CHOP](../CoreMLCHOP/) はベクトル出力モデル、本DATは検出モデル
(`VNRecognizedObjectObservation` を返すもの)を担当。

### 実測(M2・YOLOv3Int8LUT・416x416入力)

- 推論 **約38ms ≈ 26fps**(単独実行時)。バナナ画像で `banana` confidence 0.994
- **他のANE系プラグイン(LLSR等)と同時実行するとANE競合で数倍遅くなる**
  (実測: 同時実行で262ms)。重いML系は同時に走らせすぎない

### モデルの入手

```
https://huggingface.co/apple/coreml-YOLOv3
→ YOLOv3Int8LUT.mlmodel(62MB・COCO 80クラス)を models/ に置き、Model File に指定
```

Ultralytics 等で Core ML 変換した YOLOv8/v11(NMS込みエクスポート)もそのまま使える。

### 出力テーブル

| 列 | 内容 |
|---|---|
| rank | 信頼度順 1始まり |
| label | クラス名(モデル依存。COCO なら person/car/banana 等) |
| confidence | 信頼度 0〜1 |
| u, v | bbox 中心(uv・左下原点 = VisionTrack と同じ規約) |
| w, h | bbox サイズ(uv) |

### パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力 TOP |
| Model File | `.mlmodel` / `.mlpackage` / `.mlmodelc` のパス |
| Reload Model | 再読み込み(パルス) |
| Compute Units | All / CPU+GPU / CPU Only / CPU+ANE |
| Input Scaling | Scale Fill(既定)/ Center Crop / Scale Fit |
| Max Detections | 最大検出数(1〜100・既定20) |
| Min Confidence | これ未満は出力しない(既定0.25) |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

### Info CHOP

`executes / submits / analyzes / analyze_ms / detections / loaded`

### Aspect Correct UVs（アスペクト比補正）

`Aspect Correct UVs`（既定 **Off**）は uv の1単位が縦横で同じピクセル距離になるよう再スケールする。
TD標準 **Body Track CHOP** の同名パラメータと同じ役割・同じ既定値。

```
aspect = 入力幅 / 入力高さ
u' = u                             （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect      （中心を保って 1/aspect に縮小）
bbox の height（v方向の距離）も 1/aspect、width は不変
```

`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（手動スケール不要）。
生の 0〜1 画像座標が欲しいときは Off のままにする。

### 注意

- **NMS(重複除去)込みでエクスポートされたモデルが対象**。生テンソルを出す検出モデル
  (NMSなしのYOLO等)は `VNRecognizedObjectObservation` にならないため警告が出る
- 検出モデル以外を読ませた場合も警告で知らせる(その場合は CoreML TOP/CHOP を使う)
- モデルのコンパイル結果は `~/Library/Caches/TDAppleML/` に共有キャッシュされる

### ビルド

```
cd CoreMLDAT && ./build.sh   # → build/CoreMLDAT.plugin
```
