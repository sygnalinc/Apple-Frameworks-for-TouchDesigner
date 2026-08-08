# ImageIO File In TOP

**汎用の画像ファイル読み込みTOP**(ImageIO)。TouchDesigner の Movie File In が表示できない
**HEIF / HEIC** も表示でき、画像に埋め込まれた各種データを取り出せる。旧 ImageIO Depth TOP の
上位版(Color 表示と EXIF 向き補正を追加)。

## 何ができる(Data Type)

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

## 実測(M2)

- iPhone ポートレートHEIC(`IMG_2540.HEIC`・raw 4032×3024・**Orientation=6**・disparity 内蔵):
  - **Color**: **3024×4032 の正立ポートレート**として表示(横倒しが解消)
  - **Disparity**: 同じく正立で深度マップを取得
  - Info CHOP: `has_disparity=1 / has_depth=0 / has_matte=0`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Image File | 画像ファイル(HEIF/HEIC/JPEG/PNG…) |
| Data Type | Color / Auto Depth / Disparity / Depth / Portrait Matte / セマンティック各種 |
| Apply EXIF Orientation | EXIFの向きを適用(既定On) |
| Normalize Depth | 深度を auto min-max で 0..1 に正規化(既定On。Colorには無関係) |

## 注意

- **TouchDesigner Non-Commercial では未検証**。無償版は解像度が 1280x1280 に制限されるため、実機写真（実測 3024x4032）が制限に掛かる。出力解像度を下げて回避する

- **HEIF をネットワークにドラッグ**しても、TD は標準の Movie File In を作る(カスタムOPへの
  ドラッグ割り当ては TD の仕様上できない)。HEIF を開くには本OPを手動で作成して File を指定する。
  自動化したい場合は DAT Execute で moviefilein の作成を監視して差し替える運用にする
- 深度/マットは iPhone 等が埋め込んだ画像でのみ得られる。無ければ警告を出す

## ビルド

```
cd ImageIOFileIn && ./build.sh   # → build/ImageIOFileInTOP.plugin
```
