# ImageIO Depth TOP

iPhone等の写真(HEIC/JPEG)に埋め込まれた**深度・視差・Portrait Matte・セマンティックマット**を、
ImageIO の補助データ(AVDepthData由来)から取り出して **Mono32Float TOP** として出力する。

- ポートレート写真の視差/深度、肌・髪・空・歯・眼鏡のセマンティックマットを取り出せる
- ファイル入力のソースTOP。抽出はワーカースレッドで行い cook をブロックしない
- 深度/マットが無いファイルは Warning を出して valid=0(クラッシュしない)

## 実測(M2)

- 合成視差HEIC(256×256・DisparityFloat16)から視差マップを抽出、range 0.02〜0.5 を round-trip 一致
- Auto モードで disparity→depth→portrait matte の順に自動選択
- 深度なしJPEGは `No depth/matte data in this file` を表示

## 出力仕様

- TOP: **Mono32Float**(単一チャンネルの深度/視差/マット値)。`Normalize` On で min-max を 0..1 に正規化
- Info CHOP: `executes / submits / extracts / valid / range_min / range_max`(生値のレンジを確認できる)

## パラメータ

| パラメータ | 説明 |
|---|---|
| Image File | 深度/マットを含む HEIC / JPEG |
| Data Type | Auto(disparity→depth→matte)/ Disparity / Depth / Portrait Matte / Semantic(Skin/Hair/Sky/Teeth/Glasses) |
| Normalize | 自動 min-max 正規化(表示用)。Off で生の深度/視差値 |

## 注意

- 深度/視差はポートレートモード等で撮影した写真にのみ含まれる(通常写真には無い)
- 視差(Disparity)は 1/距離、深度(Depth)は距離。値の意味が異なる点に注意
- float16/float32/8bit の各補助データ形式を自動判別(Accelerate の vImage で float16→float32 変換)

## ビルド

```
cd ImageIODepth && ./build.sh   # → build/ImageIODepthTOP.plugin
```
