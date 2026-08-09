# CoreML SAM2 TOP

**English** | [日本語](#日本語)

## English

Uses Apple's conversion of **SAM 2.1 (Segment Anything Model 2)** to produce a **mask for
whatever object sits at a given point**. Unlike Vision Subject (which finds every subject
automatically), you choose *which* one with a Prompt Point. Feed it mouse or touch coordinates
and you get "cut out whatever the audience touches".

### Measured (M2, tiny, OilDrums 1280x720)

- Image encode **about 390 ms** (only when the frame changes), mask decode **about 40 ms** (only
  when the prompt changes) → on a still image, **moving the point alone gives interactive
  selection at around 25 fps**
- The first run takes seconds to tens of seconds for the ANE compile (cached afterwards)
- Moving the point from the leftmost drum to the red drum in the middle selected each one
  correctly (score 0.99 / 0.74)

### Getting the models

```
https://huggingface.co/apple/coreml-sam2.1-tiny   (a set of 3, 80 MB total)
→ put *ImageEncoder*.mlpackage / *PromptEncoder*.mlpackage / *MaskDecoder*.mlpackage in the same
  folder (e.g. models/) and point Model Folder at it (they are found by name pattern)
small / baseplus / large can be swapped in as long as the names follow the same pattern.
```

### Output

The soft mask of the highest-scoring candidate (sigmoid, **Mono32Float, 256x256**).
Use a Fit TOP to match the input resolution, or a Threshold TOP for a hard mask.

### Parameters

| Name | Description |
|---|---|
| Model Folder | Folder containing the three models |
| Prompt Point | Where to select (uv, bottom-left origin) |
| Use Background Point / Background Point | Where to exclude (suppresses mis-selection) |
| Compute Units | All / CPU+GPU |
| Flip Image Vertically | Default On (required) |

Info CHOP: `executes / submits / analyzes / encode_ms / decode_ms / score / loaded`

### Notes

- **Prompt coordinates live in a 1024x1024 pixel space inside the model** (not normalised 0–1 —
  measured). The plugin converts for you, so the parameter stays in uv
- The input is squash-resized to 1024x1024 (the aspect ratio distorts but coordinate mapping
  stays simple)
- Video input re-encodes every frame (about 2.5 fps). For real-time tracking, feed a point
  tracked by Vision Track into Prompt Point

### Build

```
cd CoreMLSAM2 && ./build.sh   # → build/CoreMLSAM2TOP.plugin
```

## 日本語

Apple公式変換の **SAM 2.1(Segment Anything Model 2)** で、**指定した点にある任意の
オブジェクトのマスク**を生成する。VisionSubject(全被写体自動)と違い「どれを抜くか」を
Prompt Point で指定できる。マウス/タッチ座標を流せば「観客が触れたものを切り抜く」演出に。

### 実測(M2・tiny・OilDrums 1280x720)

- 画像エンコード **約390ms**(フレーム変化時のみ)・マスクデコード **約40ms**(プロンプト
  変化時のみ)→ 静止画では**点を動かすだけで25fps級のインタラクティブ選択**
- 初回はANEコンパイルで数秒〜十数秒(2回目以降キャッシュ)
- 点を左端のドラム缶→中央の赤いドラム缶へ移動すると、それぞれ単体が正しく選択された
  (score 0.99 / 0.74)

### モデルの入手

```
https://huggingface.co/apple/coreml-sam2.1-tiny   (3点セット・計80MB)
→ *ImageEncoder*.mlpackage / *PromptEncoder*.mlpackage / *MaskDecoder*.mlpackage を
  同じフォルダ(例 models/)に置き、Model Folder に指定(名前パターンで自動発見)
small/baseplus/large も同名パターンなら差し替え可能。
```

### 出力

最高スコア候補のソフトマスク(sigmoid・**Mono32Float・256x256**)。
入力解像度に合わせるには Fit TOP、硬いマスクは Threshold TOP。

### パラメータ

| 名前 | 内容 |
|---|---|
| Model Folder | 3モデルが入ったフォルダ |
| Prompt Point | 選択したい位置(uv・左下原点) |
| Use Background Point / Background Point | 除外したい位置(誤選択の抑制) |
| Compute Units | All / CPU+GPU |
| Flip Image Vertically | 既定On(必須) |

Info CHOP: `executes / submits / analyzes / encode_ms / decode_ms / score / loaded`

### 注意

- **プロンプト座標はモデル内部で1024x1024ピクセル空間**(正規化0〜1ではない・実測)。
  プラグイン内で変換済みなのでパラメータはuvのままでよい
- 入力は1024x1024にsquashリサイズされる(アスペクト比は歪むが座標対応は単純)
- 動画入力では毎フレーム再エンコード(約2.5fps)。リアルタイム追従には
  VisionTrack で追った点を Prompt Point に食わせる合わせ技が有効

### ビルド

```
cd CoreMLSAM2 && ./build.sh   # → build/CoreMLSAM2TOP.plugin
```
