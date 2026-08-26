# Vision Subject TOP

**English** | [日本語](#日本語)

## English

Cuts the **subject (any foreground object, not just people)** out of the input TOP's image. This is
the same `VNGenerateForegroundInstanceMaskRequest` (macOS 14+) behind Photos' "Copy Subject".

### Measured (M2, 1280x720)

- Analysis about 45 ms (roughly 20 fps). It runs asynchronously so TD itself stays at 60 fps
- Soft Mask and Cutout are output **at the input resolution**

### Modes

| Mode | Output | Description |
|---|---|---|
| Soft Mask | Mono32Float (input resolution) | A single combined soft mask of every subject (0–1) |
| Cutout | BGRA (input resolution) | The subject cut out. **The background is transparent** (drop it straight into an Over COMP) |
| Instance Masks | RGBA8 (low resolution) | Per-subject masks split across R/G/B/A (up to 4) |
| Instance ID Map | Mono32Float (low resolution) | A label image: **0 = background, 1..N = the instance number**, stored as the raw number (not normalised). No 4-subject limit — pick a subject downstream with a comparison or a Threshold TOP |

### Parameters

| Name | Description |
|---|---|
| Active | Analysis On/Off |
| Mode | The four modes above |
| Instance (0 = All) | **0 = merge every subject** (the previous behaviour). **1..N = only the Nth subject.** Applies to Soft Mask and Cutout; the other two modes always show everything. Out of range produces an empty frame. The subject count is on the Info CHOP as `instances` |
| Flip Image Vertically | Flip the input (default On, required) |

### Picking one subject

Vision returns each subject separately, so `Instance` is a real selection, not a crop —
the parts add up to the whole. Measured on `Assets/sample_objects.mp4` (two subjects), as
the fraction of pixels above 0.5:

| | Coverage |
|---|---|
| Instance 0 (all) | 57.821 % |
| Instance 1 | 33.371 % |
| Instance 2 | 24.451 % |

`33.371 + 24.451 = 57.822`, so the two masks are disjoint and together reproduce the
combined mask exactly.

### Info CHOP

`executes / submits / analyzes / instances / analyze_ms`. `instances` is the number of subjects
detected.

### Notes

- **macOS 14+ required** (below that it only shows a warning)
- On frames with no subject it outputs a black (empty) mask
- Implementation note: `generateMaskedImageOfInstances` (Cutout) **fails on a CVPixelBuffer without
  IOSurface backing** (one wrapped with CreateWithBytes). The data is copied into an
  IOSurface-backed buffer first. This is easy to miss because the mask requests work fine with a
  raw buffer

### Build

```
cd VisionSubject && ./build.sh   # → build/VisionSubjectTOP.plugin
```

## 日本語

入力 TOP の映像から**被写体(人に限らない前景オブジェクト)**を切り抜く。写真アプリの
「被写体をコピー」と同じ `VNGenerateForegroundInstanceMaskRequest`(macOS 14+)。

### 実測(M2・1280x720)

- 解析 約45ms(≈20fps 相当)。非同期実行で TD 本体は 60fps を維持
- Soft Mask / Cutout は**入力と同解像度**で出力

### モード

| Mode | 出力 | 内容 |
|---|---|---|
| Soft Mask | Mono32Float(入力解像度) | 全被写体の統合ソフトマスク(0〜1) |
| Cutout | BGRA(入力解像度) | 被写体を切り抜いた画像。**背景は透過**(そのまま Over COMP に載せられる) |
| Instance Masks | RGBA8(低解像度) | 被写体ごとのマスクを R/G/B/A に分離(最大4個) |
| Instance ID Map | Mono32Float(低解像度) | ラベル画像。**0 = 背景 / 1..N = インスタンス番号**を、正規化せず生の数値で入れてある。4個の上限が無いので、TD 側で比較や Threshold TOP で好きな被写体を選り分けられる |

### パラメータ

| 名前 | 内容 |
|---|---|
| Active | 解析の実行 On/Off |
| Mode | 上記4モード |
| Instance (0 = All) | **0 = 検出した被写体を全部まとめる**(従来動作)。**1..N = N番目だけを出す。** Soft Mask と Cutout に効く(他の2モードは常に全部)。範囲外を指定すると空フレームになる。検出数は Info CHOP の `instances` で分かる |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

### 特定の被写体だけを抜く

Vision は被写体を1つずつ別々に返すので、`Instance` は**切り出しではなく本当の選択**になる。
`Assets/sample_objects.mp4`(被写体2個)で、0.5 を超える画素の割合を実測:

| | 被覆率 |
|---|---|
| Instance 0(全部) | 57.821 % |
| Instance 1 | 33.371 % |
| Instance 2 | 24.451 % |

`33.371 + 24.451 = 57.822` で、2つのマスクは重ならず、合わせると全部まとめたマスクに一致する。

### Info CHOP

`executes / submits / analyzes / instances / analyze_ms`。`instances` は検出された被写体数。

### 注意

- **macOS 14+ 必須**(それ未満では警告表示のみ)
- 被写体なしのフレームでは黒(空)マスクを出力する
- 実装メモ: `generateMaskedImageOfInstances`(Cutout)は **IOSurface 非対応の
  CVPixelBuffer(CreateWithBytes ラップ)だと失敗する**。IOSurface 対応バッファに
  コピーしてから渡している(マスク系は生バッファでも通るので気づきにくい)

### ビルド

```
cd VisionSubject && ./build.sh   # → build/VisionSubjectTOP.plugin
```
