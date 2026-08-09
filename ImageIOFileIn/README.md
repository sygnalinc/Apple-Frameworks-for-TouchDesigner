# ImageIO File In TOP

**English** | [日本語](#日本語)

## English

A **general-purpose image file loader TOP** (ImageIO). It displays **HEIF / HEIC**, which
TouchDesigner's Movie File In cannot, and extracts the various data embedded in an image. This is
the successor to the old ImageIO Depth TOP (with Color display and EXIF orientation added).

### What it can output (Data Type)

| Data Type | Output | Description |
|---|---|---|
| **Color (RGB)** | BGRA8 | The main image. **The way to display HEIF/HEIC** (images TD cannot open natively) |
| Auto Depth | Mono32Float | Tries disparity → depth → portrait matte in that order |
| Disparity / Depth | Mono32Float | Depth / disparity map (from AVDepthData) |
| Portrait Matte | Mono32Float | Portrait effects matte |
| Semantic: Skin / Hair / Sky / Teeth / Glasses | Mono32Float | Semantic mattes |

- **EXIF Orientation (1–8) is applied** so the image always comes out upright. An iPhone portrait
  photo is stored on a landscape sensor with `Orientation=6`, so without this it appears
  **sideways** (this operator rotates it automatically). Toggle with
  `Apply EXIF Orientation`
- The Info CHOP reports `has_disparity / has_depth / has_matte` so you can tell what a given image
  actually contains

### Measured (M2)

- iPhone portrait HEIC (`IMG_2540.HEIC`, raw 4032×3024, **Orientation=6**, disparity embedded):
  - **Color**: displayed as an upright **3024×4032 portrait** (no longer sideways)
  - **Disparity**: the depth map, upright as well
  - Info CHOP: `has_disparity=1 / has_depth=0 / has_matte=0`

### Parameters

| Parameter | Description |
|---|---|
| Image File | Image file (HEIF/HEIC/JPEG/PNG…) |
| Data Type | Color / Auto Depth / Disparity / Depth / Portrait Matte / the semantic mattes |
| Apply EXIF Orientation | Apply the EXIF orientation (default On) |
| Normalize Depth | Normalise depth to 0..1 by auto min-max (default On; irrelevant to Color) |

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- **Dragging a HEIF into the network** still creates a standard Movie File In (TD does not allow
  drag assignment to custom operators). To open HEIF, create this operator by hand and set File.
  To automate it, watch for moviefilein creation with a DAT Execute and swap the node
- Depth and mattes only exist in images where an iPhone (or similar) embedded them; otherwise a
  warning is raised

### Build

```
cd ImageIOFileIn && ./build.sh   # → build/ImageIOFileInTOP.plugin
```

## 日本語

**汎用の画像ファイル読み込みTOP**(ImageIO)。TouchDesigner の Movie File In が表示できない
**HEIF / HEIC** も表示でき、画像に埋め込まれた各種データを取り出せる。旧 ImageIO Depth TOP の
上位版(Color 表示と EXIF 向き補正を追加)。

### 何ができる(Data Type)

| Data Type | 出力 | 内容 |
|---|---|---|
| **Color (RGB)** | BGRA8 | 主画像。**HEIF/HEIC 表示の代替**(TD標準で開けない画像を表示) |
| Auto Depth | Mono32Float | disparity → depth → portrait matte の順に自動 |
| Disparity / Depth | Mono32Float | 深度/視差マップ(AVDepthData由来) |
| Portrait Matte | Mono32Float | ポートレートエフェクトマット |
| Semantic: Skin / Hair / Sky / Teeth / Glasses | Mono32Float | セマンティックマット |

- **EXIF Orientation(1〜8)を適用**して常に正立表示にする。iPhone の縦写真は横センサー+
  `Orientation=6` で保存されるため、未対応だと**横倒し**になる(本OPは自動で回転)。
  `Apply EXIF Orientation` で切替可
- Info CHOP に `has_disparity / has_depth / has_matte` を出し、その画像に何のデータが
  含まれるかが分かる

### 実測(M2)

- iPhone ポートレートHEIC(`IMG_2540.HEIC`・raw 4032×3024・**Orientation=6**・disparity 内蔵):
  - **Color**: **3024×4032 の正立ポートレート**として表示(横倒しが解消)
  - **Disparity**: 同じく正立で深度マップを取得
  - Info CHOP: `has_disparity=1 / has_depth=0 / has_matte=0`

### パラメータ

| パラメータ | 説明 |
|---|---|
| Image File | 画像ファイル(HEIF/HEIC/JPEG/PNG…) |
| Data Type | Color / Auto Depth / Disparity / Depth / Portrait Matte / セマンティック各種 |
| Apply EXIF Orientation | EXIFの向きを適用(既定On) |
| Normalize Depth | 深度を auto min-max で 0..1 に正規化(既定On。Colorには無関係) |

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- **HEIF をネットワークにドラッグ**しても、TD は標準の Movie File In を作る(カスタムOPへの
  ドラッグ割り当ては TD の仕様上できない)。HEIF を開くには本OPを手動で作成して File を指定する。
  自動化したい場合は DAT Execute で moviefilein の作成を監視して差し替える運用にする
- 深度/マットは iPhone 等が埋め込んだ画像でのみ得られる。無ければ警告を出す

### ビルド

```
cd ImageIOFileIn && ./build.sh   # → build/ImageIOFileInTOP.plugin
```
