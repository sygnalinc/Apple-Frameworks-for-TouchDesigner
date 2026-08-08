# CoreImage HDR TOP

HEIC等に埋め込まれた **HDRゲインマップ** を扱う。SDRベース / ゲインマップ / HDR拡張(EDR)を
切り替えて RGBA16Float TOP として出力する。

- iPhoneのHDR写真からゲインマップを取り出したり、HDR拡張して広ダイナミックレンジ表示に使える
- ファイル入力のソースTOP。読み込みはワーカースレッドで cook をブロックしない
- 出力は **RGBA16Float**(拡張リニアsRGB)。TDのHDR/EDRワークフローに直結

## 実測(M2)

- 合成ゲインマップ付きHEIC(256×256)で検証:
  - **Gain Map**: 埋め込みゲインマップ(左→右の輝度勾配)を正確に抽出・表示
  - **SDR base**: ベース画像を出力
  - **HDR**: `expandToHDR` パスが動作(valid=1)。合成アセットはheadroomメタが無いため max=1.0。
    **実HDR写真では 1.0超のEDR値**になる(実HDR写真での>1確認はサンプル未入手のため未実施)

## 出力仕様

- TOP: **RGBA16Float**(拡張リニアsRGB)
- Info CHOP: `executes / submits / loads / valid / max_value`(max_value>1でHDR拡張が効いている)

## パラメータ

| パラメータ | 説明 |
|---|---|
| Image File | HDRゲインマップを含む HEIC 等 |
| Mode | SDR base / Gain Map / HDR (expand / EDR) |
| Flip Vertically | 出力の上下反転(既定 On) |

## 注意

- **TouchDesigner Non-Commercial では未検証**。無償版は解像度が 1280x1280 に制限されるため、HEIC 写真は通常 4000px 級で制限に掛かる。出力解像度を下げて回避する

- ゲインマップは iPhone等のHDR写真に含まれる。通常のSDR画像には無い(Gain Mapモードで Warning)
- HDR拡張の効き(EDRのheadroom)は画像のゲインマップ・メタデータに依存する
- `kCIImageExpandToHDR` / `kCIImageAuxiliaryHDRGainMap` を使用

## ビルド

```
cd CoreImageHDR && ./build.sh   # → build/CoreImageHDRTOP.plugin
```
