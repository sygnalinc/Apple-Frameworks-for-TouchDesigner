# CoreImage RAW TOP

**English** | [日本語](#日本語)

## English

Develops DNG / Apple ProRAW / camera RAW **in real time** with `CIRAWFilter` and outputs an
RGBA16Float TOP. Exposure, white balance, noise reduction, sharpness and contrast are adjustable.

- A file-input source TOP. Development runs on a worker thread and never blocks cook
- Output is **RGBA16Float** (extended linear sRGB), ready for TD's HDR / linear workflow
- Parameter changes are detected and trigger an automatic re-develop

### Measured (M2)

- Plugin load, parameter creation, the development pipeline, parameter response (Exposure etc.)
  and the output upload were all confirmed
- **Not yet verified visually on real RAW (DNG/ProRAW) — no sample RAW on hand.** `CIRAWFilter`
  also accepts JPEG/TIFF, but a non-RAW input is developed as if it were sensor data (it blows
  out), so it cannot be used to judge the result. A real DNG/ProRAW in the File parameter
  develops correctly

### Output

- TOP: **RGBA16Float** (extended linear sRGB)
- Info CHOP: `executes / submits / develops / valid`

### Parameters

| Parameter | Description |
|---|---|
| RAW File | DNG / ProRAW / camera RAW file |
| Exposure (EV) | Exposure compensation |
| Boost | Shadow/tone boost (0 = linear, 1 = standard) |
| Neutral Temperature (K) | White balance colour temperature |
| Neutral Tint | White balance tint correction |
| Luminance Noise Reduction | Luminance noise reduction (supported RAW only) |
| Color Noise Reduction | Colour noise reduction (supported RAW only) |
| Sharpness | Sharpness (supported RAW only) |
| Contrast | Contrast |
| Scale Factor | Decode resolution scale (0.1–1.0, to reduce load) |
| Flip Vertically | Flip the output vertically (default On) |

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- Supported formats are whatever RAW macOS understands (vendor DNG, Apple ProRAW, …). A file for
  which `filterWithImageURL` returns nil shows `Not a supported RAW file`
- Some RAW files do not support noise reduction or sharpness; those parameters are then ignored
  (each `*Supported` flag is checked before applying)

### Build

```
cd CoreImageRAW && ./build.sh   # → build/CoreImageRAWTOP.plugin
```

## 日本語

DNG / Apple ProRAW / カメラRAW を `CIRAWFilter` で**リアルタイム現像**し、RGBA16Float TOP として
出力する。露出・ホワイトバランス・ノイズ除去・シャープネス・コントラストを調整できる。

- ファイル入力のソースTOP。現像はワーカースレッドで行い cook をブロックしない
- 出力は **RGBA16Float**(拡張リニアsRGB)。TDのHDR/リニアワークフローに直結
- パラメータ変更を検知して自動で再現像

### 実測(M2)

- **実 ProRAW(iPhone 17 Pro・8064x6048 DNG)で現像結果を視認確認**。Scale=1.0 のフル現像は
  初回に約10秒(48MP)。Scale=0.25 なら 2016x1512 で軽い
- **かつて出力が壊れていた(修正済み)**: `[CIContext render:...]` の format が
  `kCIFormatRGBA16`(**16bit符号なし整数**)なのに、TOP へは `RGBA16Float`(**半精度浮動小数**)として
  上げていた。ビット列が別物として解釈され、実RAWで NaN や -4696 のような値になっていた
  (画面は真っ白)。`kCIFormatRGBAh` に修正。**非RAWのJPEG等では気づきにくく、実RAWを入れて初めて
  露見した**
- CIRAWFilter は JPEG/TIFF も受け付けるが、非RAW入力はセンサーデータ前提の現像とずれる
  (白飛びする)ため視覚評価には使えない

### 出力仕様

- TOP: **RGBA16Float**(拡張リニアsRGB)
- Info CHOP: `executes / submits / develops / valid`

### パラメータ

| パラメータ | 説明 |
|---|---|
| RAW File | DNG / ProRAW / カメラRAW ファイル |
| Exposure (EV) | 露出補正 |
| Boost | シャドウ/トーンのブースト(0=リニア, 1=標準) |
| Neutral Temperature (K) | ホワイトバランス色温度 |
| Neutral Tint | ホワイトバランスの色かぶり補正 |
| Luminance Noise Reduction | 輝度ノイズ除去(対応RAWのみ) |
| Color Noise Reduction | 色ノイズ除去(対応RAWのみ) |
| Sharpness | シャープネス(対応RAWのみ) |
| Contrast | コントラスト |
| Scale Factor | デコード解像度スケール(0.1〜1.0。負荷軽減に) |
| Flip Vertically | 出力の上下反転(既定 On) |

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- 対応形式は macOS が解釈できる RAW(各社DNG・Apple ProRAW 等)。`filterWithImageURL` が nil を返す
  ファイルは `Not a supported RAW file` を表示
- ノイズ除去/シャープネスは RAW によって非対応の場合があり、その場合は該当パラメータを無視する
  (`*Supported` を確認してから適用)

### ビルド

```
cd CoreImageRAW && ./build.sh   # → build/CoreImageRAWTOP.plugin
```
