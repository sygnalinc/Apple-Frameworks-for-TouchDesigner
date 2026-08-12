# Vision Barcode DAT

**English** | [日本語](#日本語)

## English

Detects QR codes and assorted 1D/2D barcodes with Apple Vision. No extra model required.

The output columns are `index / symbology / payload / confidence / u / v / width / height /`
`tl_u / tl_v / tr_u / tr_v / br_u / br_v / bl_u / bl_v`. Coordinates are 0–1 with a bottom-left
origin, and multiple codes are ordered by centre u, left to right.

| Parameter | Description |
|---|---|
| TOP | Input TOP |
| Active | Detection On/Off |
| Max Codes | Output limit. Default 10, internal limit 100 |
| Minimum Confidence | Minimum confidence |
| Flip Image Vertically | Default On |

Info CHOP: `executes / submits / analyzes / analyze_ms / codes`. For binary codes whose payload
cannot be turned into a string, payload is empty. Inference is asynchronous, and a still image is
re-analysed when a parameter changes.

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
the bbox height (a v distance) is also 1/aspect; the width is unchanged
```

Because `u` stays in 0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly on the
source video **with the camera's Ortho Width left at 1** (no manual scaling). Leave it Off when
you want raw 0..1 image coordinates.

### Build

```sh
cd VisionBarcode && ./build.sh
```

## 日本語

Apple VisionでQRコードと各種1D/2Dバーコードを検出するDAT。追加モデル不要。

出力列は`index / symbology / payload / confidence / u / v / width / height /`
`tl_u / tl_v / tr_u / tr_v / br_u / br_v / bl_u / bl_v`。座標は0〜1・左下原点で、
複数コードは中心uの左→右順。

| パラメータ | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 検出On/Off |
| Max Codes | 出力上限。既定10、内部上限100 |
| Minimum Confidence | 最低信頼度 |
| Flip Image Vertically | 既定On |

Info CHOPは`executes / submits / analyzes / analyze_ms / codes`。payloadを文字列化できない
バイナリコードではpayloadが空になる。推論は非同期で、パラメータ変更時は静止画も再解析する。

### Aspect Correct UVs（アスペクト比補正）

`Aspect Correct UVs`（既定 **Off**）は uv の1単位が縦横で同じピクセル距離になるよう再スケールする。
TD標準 **Body Track CHOP** の同名パラメータと同じ役割・同じ既定値。

```
aspect = 入力幅 / 入力高さ
u' = u                             （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect      （中心を保って 1/aspect に縮小）
bbox の height（v方向の距離）も 1/aspect、width は不変
```

`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（手動スケール不要）。
生の 0〜1 画像座標が欲しいときは Off のままにする。

### ビルド

```sh
cd VisionBarcode && ./build.sh
```
