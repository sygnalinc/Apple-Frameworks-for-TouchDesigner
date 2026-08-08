# CoreImage RAW TOP

DNG / Apple ProRAW / カメラRAW を `CIRAWFilter` で**リアルタイム現像**し、RGBA16Float TOP として
出力する。露出・ホワイトバランス・ノイズ除去・シャープネス・コントラストを調整できる。

- ファイル入力のソースTOP。現像はワーカースレッドで行い cook をブロックしない
- 出力は **RGBA16Float**(拡張リニアsRGB)。TDのHDR/リニアワークフローに直結
- パラメータ変更を検知して自動で再現像

## 実測(M2)

- プラグインのロード・パラメータ生成・現像パイプライン実行・パラメータ反映(Exposure等)・
  出力アップロードを確認
- **実RAW(DNG/ProRAW)での視覚検証はサンプルRAW未入手のため未実施**。CIRAWFilter は JPEG/TIFF も
  受け付けるが、非RAW入力はセンサーデータ前提の現像とずれる(白飛びする)ため視覚評価には使えない。
  実DNG/ProRAWを File に指定すれば正しく現像される

## 出力仕様

- TOP: **RGBA16Float**(拡張リニアsRGB)
- Info CHOP: `executes / submits / develops / valid`

## パラメータ

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

## 注意

- **TouchDesigner Non-Commercial では未検証**。無償版は解像度が 1280x1280 に制限されるため、RAW 写真は通常 4000px 級で制限に掛かる。出力解像度を下げて回避する

- 対応形式は macOS が解釈できる RAW(各社DNG・Apple ProRAW 等)。`filterWithImageURL` が nil を返す
  ファイルは `Not a supported RAW file` を表示
- ノイズ除去/シャープネスは RAW によって非対応の場合があり、その場合は該当パラメータを無視する
  (`*Supported` を確認してから適用)

## ビルド

```
cd CoreImageRAW && ./build.sh   # → build/CoreImageRAWTOP.plugin
```
