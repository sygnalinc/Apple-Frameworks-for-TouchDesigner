# CoreImage HDR TOP

**English** | [日本語](#日本語)

## English

Works with the **HDR gain map** embedded in HEIC and similar files. Switch between the SDR base,
the gain map and the HDR expansion (EDR) and output it as an RGBA16Float TOP.

- Pull the gain map out of an iPhone HDR photo, or expand to HDR for wide-dynamic-range display
- A file-input source TOP. Loading happens on a worker thread and never blocks cook
- Output is **RGBA16Float** (extended linear sRGB), ready for TD's HDR/EDR workflow

### Measured (M2)

- Verified with a synthesised 256×256 HEIC carrying a gain map:
  - **Gain Map**: the embedded gain map (a left→right luminance ramp) is extracted exactly
  - **SDR base**: outputs the base image
  - **HDR**: the `expandToHDR` path works (valid=1). The synthetic asset has no headroom
    metadata so max = 1.0
- **Verified on a real iPhone HDR photo** (HEIC, gain map 2016x1512, `contentHeadroom` 2.616):
  all three modes develop at full size (HDR / SDR 4032x3024, Gain Map 2016x1512, RGBA16Float).
  Whether the HDR expansion is visible depends on the display's headroom — on an SDR display the
  HDR and SDR modes look alike even though the values differ

### Output

- TOP: **RGBA16Float** (extended linear sRGB)
- Info CHOP: `executes / submits / loads / valid / max_value` (max_value > 1 means the HDR
  expansion is taking effect)

### Parameters

| Parameter | Description |
|---|---|
| Image File | HEIC etc. containing an HDR gain map |
| Mode | SDR base / Gain Map / HDR (expand / EDR) |
| Flip Vertically | Flip the output vertically (default On) |

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- Gain maps come from HDR photos taken on an iPhone and similar devices. Ordinary SDR images have
  none (Gain Map mode raises a warning)
- How much the HDR expansion does depends on the image's gain map and metadata
- Uses `kCIImageExpandToHDR` / `kCIImageAuxiliaryHDRGainMap`

### Build

```
cd CoreImageHDR && ./build.sh   # → build/CoreImageHDRTOP.plugin
```

## 日本語

HEIC等に埋め込まれた **HDRゲインマップ** を扱う。SDRベース / ゲインマップ / HDR拡張(EDR)を
切り替えて RGBA16Float TOP として出力する。

- iPhoneのHDR写真からゲインマップを取り出したり、HDR拡張して広ダイナミックレンジ表示に使える
- ファイル入力のソースTOP。読み込みはワーカースレッドで cook をブロックしない
- 出力は **RGBA16Float**(拡張リニアsRGB)。TDのHDR/EDRワークフローに直結

### 実測(M2)

- 合成ゲインマップ付きHEIC(256×256)で検証:
  - **Gain Map**: 埋め込みゲインマップ(左→右の輝度勾配)を正確に抽出・表示
  - **SDR base**: ベース画像を出力
  - **HDR**: `expandToHDR` パスが動作(valid=1)。合成アセットはheadroomメタが無いため max=1.0。
    合成素材には headroom メタデータが無いので max=1.0
- **実iPhone HDR写真で確認**(HEIC・ゲインマップ 2016x1512・`contentHeadroom` 2.616):
  3モードとも実サイズで現像される(HDR/SDR 4032x3024、Gain Map 2016x1512、RGBA16Float)。
  HDR の伸びが見えるかは表示側の headroom 次第で、SDRディスプレイでは値が違っても
  HDR と SDR は同じに見える

### 出力仕様

- TOP: **RGBA16Float**(拡張リニアsRGB)
- Info CHOP: `executes / submits / loads / valid / max_value`(max_value>1でHDR拡張が効いている)

### パラメータ

| パラメータ | 説明 |
|---|---|
| Image File | HDRゲインマップを含む HEIC 等 |
| Mode | SDR base / Gain Map / HDR (expand / EDR) |
| Flip Vertically | 出力の上下反転(既定 On) |

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- ゲインマップは iPhone等のHDR写真に含まれる。通常のSDR画像には無い(Gain Mapモードで Warning)
- HDR拡張の効き(EDRのheadroom)は画像のゲインマップ・メタデータに依存する
- `kCIImageExpandToHDR` / `kCIImageAuxiliaryHDRGainMap` を使用

### ビルド

```
cd CoreImageHDR && ./build.sh   # → build/CoreImageHDRTOP.plugin
```
