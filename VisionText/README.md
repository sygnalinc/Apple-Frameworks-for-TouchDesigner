# Vision Text DAT — OCR / text recognition (macOS)

**English** | [日本語](#日本語)

## English

A TD-native custom DAT that recognises text (`VNRecognizeTextRequest`) in a TOP's image and
outputs one row per text region. Japanese, English and many other languages, fully on-device.

Measured: mixed Japanese/English text rendered in a Text TOP (AIR BAND 2026 / エアバンド採点中 /
SCORE 88421) was recognised correctly on every line.

### Output table

```
text            | confidence | u      | v      | width  | height
AIR BAND 2026   | 1.000      | 0.4984 | 0.6361 | 0.6000 | 0.1111
エアバンド採点中 | 0.500      | ...
```

- One row = one text region. u,v are the **centre** of the region's bounding box (0–1, bottom-left
  origin)
- Rows are in **reading order** (top to bottom; left to right at the same height)

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Recognition Level | Accurate | Accurate (high quality, ~100 ms per analysis) / Fast (lower quality, faster) |
| Languages | ja-JP en-US | Recognition languages (space separated, in priority order). Empty = Vision's default |
| Language Correction | On | Correction with the language model |
| Min Confidence | 0.3 | Regions below this confidence are not output |
| Flip Image Vertically | **On** | TD's TOP download is upside down, so this defaults to On |

Info CHOP: `executes / submits / analyzes / regions / analyze_ms`.

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
height (a v distance) is also 1/aspect; the width is unchanged
```

Because `u` stays in 0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly on the
source video **with the camera's Ortho Width left at 1** (handy for overlaying boxes or labels on
the text regions). Leave it Off when you want raw 0..1 image coordinates, such as for feeding a
Crop TOP.

### Notes

- `cookEveryFrameIfAsked` — unless the output is used (displayed) somewhere, analysis does not run
- For Japanese, putting `ja-JP` first in Languages improves accuracy

### Build

```
./build.sh    # → build/VisionTextDAT.plugin
```

## 日本語

TOP の映像から文字（`VNRecognizeTextRequest`）を認識し、テキスト領域ごとに
テーブル出力する TD ネイティブのカスタム DAT。日本語・英語ほか多言語・完全オンデバイス。

実測: Text TOP の日英混在テキスト（AIR BAND 2026 / エアバンド採点中 / SCORE 88421）を
全行正しく認識。

### 出力テーブル

```
text            | confidence | u      | v      | width  | height
AIR BAND 2026   | 1.000      | 0.4984 | 0.6361 | 0.6000 | 0.1111
エアバンド採点中 | 0.500      | ...
```

- 1行 = 1テキスト領域。u,v は領域バウンディングボックスの**中心**（0〜1・左下原点）
- 行は**読み順**（上→下、同じ高さは左→右）

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Recognition Level | Accurate | Accurate（高精度・1解析 100ms 級）/ Fast（低精度・高速） |
| Languages | ja-JP en-US | 認識言語（空白区切り・優先順）。空なら Vision の既定 |
| Language Correction | On | 言語モデルによる補正 |
| Min Confidence | 0.3 | これ未満の信頼度の領域は出力しない |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆のため既定 On |

Info CHOP: `executes / submits / analyzes / regions / analyze_ms`。

### Aspect Correct UVs（アスペクト比補正）

`Aspect Correct UVs`（既定 **Off**）は uv の1単位が縦横で同じピクセル距離になるよう再スケールする。
TD標準 **Body Track CHOP** の同名パラメータと同じ役割・同じ既定値。

```
aspect = 入力幅 / 入力高さ
u' = u                             （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect      （中心を保って 1/aspect に縮小）
height（v方向の距離）も 1/aspect、width は不変
```

`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（テキスト領域に枠やラベルを
重ねる用途で便利）。Crop TOP へ渡すなど生の 0〜1 画像座標が欲しいときは Off のままにする。

### 注意

- `cookEveryFrameIfAsked` — 出力をどこかで使って（表示して）いないと解析が回らない
- 日本語の認識言語指定は `ja-JP` を Languages の先頭に置くと精度が上がる

### ビルド

```
./build.sh    # → build/VisionTextDAT.plugin
```
